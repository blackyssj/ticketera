-- ============================================================
-- 0109 — lo que se le paga a la pasarela, anotado
--
-- La pasarela acredita al monedero el monto entero de cada cobro y cobra
-- su parte (el 1,5% de costo_pasarela_pct) por fuera. Hasta hoy eso era una
-- cuenta y nada más: el panel restaba ese costo de la ganancia, pero nunca
-- supo cuándo se le pagaba. El 20/10 José le pagó lo de LÜMEN, Nocturne y
-- Latina (3.596,19) desde el monedero, y el cuadre "lo que tiene que haber
-- en la wallet" iba a quedar corrido en ese monto.
--
-- Por qué no es un retiro: el retiro es ganancia que sale para los socios
-- y se resta de `disponible`. El costo de la pasarela ya está restado de
-- la ganancia (margen = comisión − pasarela); anotarlo como retiro lo
-- restaría dos veces y les bajaría la parte a los socios por algo que no
-- cobraron. Acá baja sólo `en_pasarela` (lo que tiene que haber en el
-- monedero) y aparece cuánto se le sigue debiendo.
-- ============================================================

create table if not exists pago_pasarela (
  id         uuid primary key default gen_random_uuid(),
  monto      numeric(12,2) not null check (monto > 0),
  referencia text,
  nota       text,
  hecho_por  uuid references perfiles(id),
  hecho_at   timestamptz not null default clock_timestamp()
);
alter table pago_pasarela enable row level security;
revoke all on pago_pasarela from anon, authenticated;

comment on table pago_pasarela is
  'Lo que TICKETAZO le pagó a la pasarela por su costo (0109). Baja lo que tiene que haber en el monedero; no toca la ganancia, que ya descuenta ese costo. Sin policies: se llega por registrar_pago_pasarela() y pagos_pasarela(), que exigen es_plataforma().';

-- ── el tablero, con lo pagado a la pasarela ─────────────────
-- Cuerpo de 0088 más `pagado_pasarela`, `debemos_pasarela` y el descuento
-- en `en_pasarela`.
create or replace function panel_plataforma() returns jsonb
  language plpgsql stable security definer set search_path = public as $function$
declare
  v_res jsonb := '[]'::jsonb; r record; v_tot jsonb; v_pct numeric := costo_pasarela_pct();
  v_cobrado numeric(12,2); v_fee numeric(12,2); v_sub numeric(12,2); v_costo numeric(12,2);
  v_retirado numeric(12,2); v_pagado_pas numeric(12,2);
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
  select coalesce(sum(monto), 0) into v_pagado_pas from pago_pasarela;

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
                 - v_retirado - v_pagado_pas,
    'pagado_pasarela', v_pagado_pas,
    'debemos_pasarela', coalesce(sum((x->>'costo_pasarela')::numeric), 0) - v_pagado_pas,
    'por_girar',   coalesce(sum((x->>'del_cliente')::numeric), 0)
                 - coalesce(sum((x->>'girado')::numeric), 0))
    into v_tot
    from jsonb_array_elements(v_res) x;

  return jsonb_build_object('ok', true, 'clientes', v_res, 'total', v_tot,
                            'costo_pct', v_pct, 'al', now());
end $function$;

-- ── anotar un pago ──────────────────────────────────────────
-- No mueve plata: el pago se hace en el portal. Se rechaza un monto mayor
-- a lo que se debe con un margen de un peso, por lo mismo que el retiro:
-- teclear el número equivocado es el error típico.
create or replace function registrar_pago_pasarela(p_monto numeric, p_referencia text default null,
                                                   p_nota text default null)
  returns jsonb language plpgsql volatile security definer set search_path = public as $function$
declare v_debe numeric(12,2); v_id uuid; v_monto numeric(12,2) := round(p_monto, 2);
begin
  if not es_plataforma() then raise exception 'Sin permiso'; end if;
  if v_monto is null or v_monto <= 0 then
    return jsonb_build_object('ok', false, 'motivo', 'El monto tiene que ser mayor a cero.');
  end if;
  select (panel_plataforma()->'total'->>'debemos_pasarela')::numeric into v_debe;
  if v_monto > v_debe + 1 then
    return jsonb_build_object('ok', false,
      'motivo', format('A la pasarela se le deben %s; no se puede anotar un pago de %s.', v_debe, v_monto));
  end if;
  insert into pago_pasarela (monto, referencia, nota, hecho_por)
  values (v_monto, nullif(btrim(coalesce(p_referencia, '')), ''),
          nullif(btrim(coalesce(p_nota, '')), ''), auth.uid())
  returning id into v_id;
  return jsonb_build_object('ok', true, 'id', v_id, 'monto', v_monto,
    'motivo', format('Anotado el pago de Bs %s a la pasarela.', v_monto));
end $function$;
revoke execute on function registrar_pago_pasarela(numeric, text, text) from anon, public;
grant execute on function registrar_pago_pasarela(numeric, text, text) to authenticated;

create or replace function pagos_pasarela(p_limite int default 25) returns jsonb
  language plpgsql stable security definer set search_path = public as $function$
begin
  if not es_plataforma() then raise exception 'Sin permiso'; end if;
  return (select coalesce(jsonb_agg(jsonb_build_object(
            'id', r.id, 'monto', r.monto, 'referencia', r.referencia, 'nota', r.nota,
            'quien', p.nombre, 'cuando', r.hecho_at) order by r.hecho_at desc), '[]'::jsonb)
    from (select * from pago_pasarela order by hecho_at desc
           limit greatest(coalesce(p_limite, 25), 1)) r
    left join perfiles p on p.id = r.hecho_por);
end $function$;
revoke execute on function pagos_pasarela(int) from anon, public;
grant execute on function pagos_pasarela(int) to authenticated;

-- ── control ─────────────────────────────────────────────────
select * from chequeo_funciones_sin_guardia();
