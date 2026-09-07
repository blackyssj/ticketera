-- ============================================================
-- 0070 — lo que nos cobra la pasarela, que hasta hoy no existía
--
-- El tablero de 0069 mostraba "nuestra comisión" como si fuera lo que
-- ganamos. No lo es: la pasarela nos cobra el 1,5% de todo lo procesado,
-- y ese costo sale de nuestra parte — no de la del cliente, que tiene
-- derecho a su precio entero.
--
-- Con la tarifa del 7% y una entrada de 100 la cuenta real es:
--
--     cobrado al comprador     107,00
--     del cliente             −100,00
--     ─────────────────────────────────
--     nuestra comisión           7,00
--     costo de la pasarela      −1,61   (1,5% de 107)
--     ─────────────────────────────────
--     nos queda                  5,39
--
-- O sea que de cada 7 que facturamos nos quedan 5,39: casi un cuarto de
-- nuestra comisión se va en procesar. Un tablero que no lo muestra hace
-- creer que el margen es un cuarto más grande de lo que es, y esa es
-- exactamente la cifra con la que se decide si una tarifa alcanza.
--
-- ── por qué se cobra sobre lo COBRADO y no sobre lo nuestro ─
--
-- La pasarela procesa la transacción entera, no nuestra parte. En una
-- entrada de 100 mueve 107 y cobra sobre esos 107. Calcularlo sobre
-- nuestra comisión daría 0,10 en vez de 1,61: dieciséis veces menos, y
-- todas las decisiones de precio tomadas contra un número inventado.
--
-- ── por qué es una tabla y no una constante ─────────────────
--
-- Es una tarifa negociada y va a cambiar. Con una constante en el código
-- cambiarla es un despliegue; con una fila es un update.
--
-- Una sola fila, garantizada por la primary key en un boolean con check:
-- no hay forma de insertar la segunda.
--
-- ── lo que este archivo NO hace ─────────────────────────────
--
-- No descuenta nada de ningún lado. Hoy la pasarela acredita el monto
-- entero al monedero —verificado: las capturas son iguales a los cobros,
-- sin retención— así que el 1,5% se paga por fuera, después. Acá se
-- calcula para saber cuánto es; cuando BeePay lo cobre de verdad, el
-- número del cuadre va a moverse y hay que saber por qué.
-- ============================================================

create table if not exists plataforma_config (
  id                 boolean primary key default true check (id),
  costo_pasarela_pct numeric(6,4) not null default 0.0150
    check (costo_pasarela_pct >= 0 and costo_pasarela_pct < 1),
  actualizado_at     timestamptz not null default clock_timestamp()
);
alter table plataforma_config enable row level security;
revoke all on plataforma_config from anon, authenticated;

insert into plataforma_config (id) values (true) on conflict (id) do nothing;

comment on table plataforma_config is
  'Los numeros de TICKETAZO, no de un cliente. Una sola fila: la primary key es un boolean con check, asi que la segunda no entra. Sin policies — se lee y escribe desde funciones que exigen es_plataforma().';

drop function if exists costo_pasarela_pct();
create function costo_pasarela_pct() returns numeric
  language sql stable security definer set search_path = public as $$
  select coalesce((select costo_pasarela_pct from plataforma_config where id), 0.0150)
$$;
revoke execute on function costo_pasarela_pct() from anon, public, authenticated;

drop function if exists guardar_costo_pasarela(numeric);
create function guardar_costo_pasarela(p_pct numeric) returns jsonb
  language plpgsql volatile security definer set search_path = public as $function$
declare v numeric(6,4);
begin
  if not es_plataforma() then raise exception 'Sin permiso'; end if;
  v := round(p_pct, 4);
  if v is null or v < 0 or v >= 1 then
    return jsonb_build_object('ok', false,
      'motivo', 'La tarifa va como fracción: 0.015 es 1,5%.');
  end if;
  update plataforma_config set costo_pasarela_pct = v, actualizado_at = clock_timestamp()
   where id;
  return jsonb_build_object('ok', true, 'pct', v,
    'motivo', format('La pasarela nos cobra %s%% de lo procesado.', round(v * 100, 2)));
end $function$;
revoke execute on function guardar_costo_pasarela(numeric) from anon, public;
grant execute on function guardar_costo_pasarela(numeric) to authenticated;

-- ── el tablero, ahora con el margen de verdad ───────────────
create or replace function panel_plataforma() returns jsonb
  language plpgsql stable security definer set search_path = public as $function$
declare
  v_res jsonb := '[]'::jsonb; r record; v_tot jsonb; v_pct numeric := costo_pasarela_pct();
  v_cobrado numeric(12,2); v_fee numeric(12,2); v_sub numeric(12,2); v_costo numeric(12,2);
begin
  if not es_plataforma() then raise exception 'Sin permiso'; end if;

  for r in
    select g.id, g.slug, g.nombre, g.fee_pct, g.comision_modo,
           g.pago_automatico, g.pago_auto_minimo
      from organizadores g where g.activo order by g.nombre
  loop
    select coalesce(sum(o.total),0), coalesce(sum(o.fee),0), coalesce(sum(o.subtotal),0)
      into v_cobrado, v_fee, v_sub
      from ordenes o
     where o.organizador_id = r.id and o.estado = 'pagada'
       and coalesce(o.pago_ref,'') not like 'SIM-%';
    -- Sobre lo cobrado, que es lo que la pasarela procesa de verdad.
    v_costo := round(v_cobrado * v_pct, 2);

    v_res := v_res || jsonb_build_object(
      'organizador', r.nombre, 'slug', r.slug,
      'fee_pct', r.fee_pct, 'modo', r.comision_modo,
      'automatico', r.pago_automatico, 'minimo', r.pago_auto_minimo,
      'eventos', (select count(*) from eventos e
                   where e.organizador_id = r.id and e.estado = 'publicado'),
      'entradas', (select count(*) from entradas x
                    where x.organizador_id = r.id and x.estado <> 'anulada'),
      'cobrado', v_cobrado, 'nuestro', v_fee, 'del_cliente', v_sub,
      'costo_pasarela', v_costo,
      -- Lo que de verdad nos queda de este cliente.
      'margen', round(v_fee - v_costo, 2),
      'girado',   (select coalesce(sum(p.monto),0) from pago_organizador p
                    where p.organizador_id = r.id and p.estado <> 'rechazado'),
      'en_camino',(select coalesce(sum(p.monto),0) from pago_organizador p
                    where p.organizador_id = r.id
                      and p.estado in ('pedido','enviado','aprobacion_manual')),
      'rechazados',(select count(*) from pago_organizador p
                    where p.organizador_id = r.id and p.estado = 'rechazado'),
      'simuladas', (select coalesce(sum(o.total),0) from ordenes o
                    where o.organizador_id = r.id and o.estado = 'pagada'
                      and coalesce(o.pago_ref,'') like 'SIM-%'));
  end loop;

  select jsonb_build_object(
    'cobrado',     coalesce(sum((x->>'cobrado')::numeric), 0),
    'nuestro',     coalesce(sum((x->>'nuestro')::numeric), 0),
    'del_cliente', coalesce(sum((x->>'del_cliente')::numeric), 0),
    'costo_pasarela', coalesce(sum((x->>'costo_pasarela')::numeric), 0),
    'margen',      coalesce(sum((x->>'margen')::numeric), 0),
    'girado',      coalesce(sum((x->>'girado')::numeric), 0),
    'en_camino',   coalesce(sum((x->>'en_camino')::numeric), 0),
    'en_pasarela', coalesce(sum((x->>'cobrado')::numeric), 0)
                 - coalesce(sum((x->>'girado')::numeric), 0),
    'por_girar',   coalesce(sum((x->>'del_cliente')::numeric), 0)
                 - coalesce(sum((x->>'girado')::numeric), 0))
    into v_tot
    from jsonb_array_elements(v_res) x;

  return jsonb_build_object('ok', true, 'clientes', v_res, 'total', v_tot,
                            'costo_pct', v_pct, 'al', now());
end $function$;
revoke execute on function panel_plataforma() from anon, public;
grant execute on function panel_plataforma() to authenticated;
