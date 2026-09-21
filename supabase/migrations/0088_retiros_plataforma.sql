-- ============================================================
-- 0088 — los retiros de TICKETAZO, anotados
--
-- La pestaña Plataforma sabía cuánto habíamos facturado de comisión y
-- cuánto se llevaba la pasarela, pero no cuánto de eso ya nos habíamos
-- sacado del monedero. El 21/09 se hizo el primer retiro (Bs 622, la
-- comisión del primer evento) y no había dónde anotarlo: el "nos queda"
-- seguía diciendo 622 aunque la plata ya estaba en nuestra cuenta, y el
-- cuadre contra la wallet de BeePay quedaba corrido por ese monto.
--
-- `retiro_plataforma` es el libro de esos retiros. Una fila por giro,
-- con quién lo anotó. Sin policies: se lee y escribe desde funciones
-- que exigen es_plataforma(), como plataforma_config (0070).
--
-- panel_plataforma() ahora devuelve `retirado` y `disponible` (margen −
-- retirado) y descuenta los retiros de `en_pasarela`, que es lo que tiene
-- que haber en la wallet.
-- ============================================================

create table if not exists retiro_plataforma (
  id         uuid primary key default gen_random_uuid(),
  monto      numeric(12,2) not null check (monto > 0),
  referencia text,
  nota       text,
  hecho_por  uuid references perfiles(id),
  hecho_at   timestamptz not null default clock_timestamp()
);
alter table retiro_plataforma enable row level security;
revoke all on retiro_plataforma from anon, authenticated;

comment on table retiro_plataforma is
  'Plata que TICKETAZO se saco del monedero de la pasarela: nuestra comision, no la de un cliente. Sin policies; se llega por registrar_retiro_plataforma() y retiros_plataforma(), que exigen es_plataforma().';

-- ── anotar un retiro ────────────────────────────────────────
-- No mueve plata: el giro se hace en BeePay a mano. Acá queda el registro
-- para que el panel y el cuadre digan la verdad. Se rechaza un monto
-- mayor al disponible con un margen de un peso, porque anotar de más es
-- el error típico de teclear el número equivocado, y después nadie sabe
-- cuál de las dos filas está mal.
drop function if exists registrar_retiro_plataforma(numeric, text, text);
create function registrar_retiro_plataforma(p_monto numeric, p_nota text default null,
                                            p_referencia text default null)
  returns jsonb language plpgsql volatile security definer set search_path = public as $function$
declare v_disp numeric(12,2); v_id uuid; v_monto numeric(12,2) := round(p_monto, 2);
begin
  if not es_plataforma() then raise exception 'Sin permiso'; end if;
  if v_monto is null or v_monto <= 0 then
    return jsonb_build_object('ok', false, 'motivo', 'El monto tiene que ser mayor a cero.');
  end if;
  select (panel_plataforma()->'total'->>'disponible')::numeric into v_disp;
  if v_monto > v_disp + 1 then
    return jsonb_build_object('ok', false,
      'motivo', format('Hay %s disponibles; no se puede anotar un retiro de %s.', v_disp, v_monto));
  end if;
  insert into retiro_plataforma (monto, referencia, nota, hecho_por)
  values (v_monto, nullif(btrim(coalesce(p_referencia,'')),''),
          nullif(btrim(coalesce(p_nota,'')),''), auth.uid())
  returning id into v_id;
  return jsonb_build_object('ok', true, 'id', v_id, 'monto', v_monto,
    'motivo', format('Anotado el retiro de Bs %s.', v_monto));
end $function$;
revoke execute on function registrar_retiro_plataforma(numeric, text, text) from anon, public;
grant execute on function registrar_retiro_plataforma(numeric, text, text) to authenticated;

-- ── la lista ────────────────────────────────────────────────
drop function if exists retiros_plataforma(int);
create function retiros_plataforma(p_limite int default 25) returns jsonb
  language plpgsql stable security definer set search_path = public as $function$
begin
  if not es_plataforma() then raise exception 'Sin permiso'; end if;
  return (select coalesce(jsonb_agg(jsonb_build_object(
            'id', r.id, 'monto', r.monto, 'referencia', r.referencia, 'nota', r.nota,
            'quien', p.nombre, 'cuando', r.hecho_at) order by r.hecho_at desc), '[]'::jsonb)
    from (select * from retiro_plataforma order by hecho_at desc
           limit greatest(coalesce(p_limite, 25), 1)) r
    left join perfiles p on p.id = r.hecho_por);
end $function$;
revoke execute on function retiros_plataforma(int) from anon, public;
grant execute on function retiros_plataforma(int) to authenticated;

-- ── el tablero, con lo retirado ─────────────────────────────
-- Cuerpo de 0070 más `retirado`, `disponible` y el descuento en `en_pasarela`.
create or replace function panel_plataforma() returns jsonb
  language plpgsql stable security definer set search_path = public as $function$
declare
  v_res jsonb := '[]'::jsonb; r record; v_tot jsonb; v_pct numeric := costo_pasarela_pct();
  v_cobrado numeric(12,2); v_fee numeric(12,2); v_sub numeric(12,2); v_costo numeric(12,2);
  v_retirado numeric(12,2);
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

  select coalesce(sum(monto), 0) into v_retirado from retiro_plataforma;

  select jsonb_build_object(
    'cobrado',     coalesce(sum((x->>'cobrado')::numeric), 0),
    'nuestro',     coalesce(sum((x->>'nuestro')::numeric), 0),
    'del_cliente', coalesce(sum((x->>'del_cliente')::numeric), 0),
    'costo_pasarela', coalesce(sum((x->>'costo_pasarela')::numeric), 0),
    'margen',      coalesce(sum((x->>'margen')::numeric), 0),
    'retirado',    v_retirado,
    'disponible',  coalesce(sum((x->>'margen')::numeric), 0) - v_retirado,
    'girado',      coalesce(sum((x->>'girado')::numeric), 0),
    'en_camino',   coalesce(sum((x->>'en_camino')::numeric), 0),
    'en_pasarela', coalesce(sum((x->>'cobrado')::numeric), 0)
                 - coalesce(sum((x->>'girado')::numeric), 0)
                 - v_retirado,
    'por_girar',   coalesce(sum((x->>'del_cliente')::numeric), 0)
                 - coalesce(sum((x->>'girado')::numeric), 0))
    into v_tot
    from jsonb_array_elements(v_res) x;

  return jsonb_build_object('ok', true, 'clientes', v_res, 'total', v_tot,
                            'costo_pct', v_pct, 'al', now());
end $function$;

-- ── el primer retiro, anotado a mano ────────────────────────
-- 21/09/2026: José retiró la comisión del primer evento desde BeePay.
-- Va por insert y no por la función porque acá no hay auth.uid().
insert into retiro_plataforma (monto, nota, hecho_por, hecho_at)
select 622.00,
       'Primer retiro: comisión del evento del viernes 18 y ventas hasta el 21/09. Giro hecho a mano desde BeePay.',
       (select po.perfil_id from plataforma_operador po join perfiles p on p.id = po.perfil_id
         where p.nombre = 'Jose Menacho' limit 1),
       '2026-09-21 10:00:00-04'
where not exists (select 1 from retiro_plataforma);

select * from chequeo_funciones_sin_guardia();
