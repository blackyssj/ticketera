-- ============================================================
-- 0112 — la plata del cliente, sólo para su admin
--
-- Hasta hoy la cuenta para cobrar y el retiro colgaban de puede_editar(),
-- que es admin O staff. O sea: el encargado de barra con rol Staff podía
-- cambiar la cuenta bancaria del cliente por la suya y pedir el pago,
-- todo desde el panel y sin que el dueño se enterara hasta ver el
-- extracto. guardar_pago_automatico ya era sólo admin (0057); esto deja
-- igual a las otras dos puertas de la plata.
--
-- Lo que cambia para un staff:
--   · guardar_cuenta_bancaria y pedir_pago_organizador: «Sin permiso».
--     La Edge Function `liquidar` no cambia: le pasa el token de quien
--     pide a la base, y la base decide (liquidar/index.ts).
--   · disponible_organizador y pagos_organizador siguen andando (las
--     cifras de su evento las puede ver), pero la cuenta sale tapada:
--     banco y los últimos cuatro números, sin titular ni documento.
--   · cuenta_bancaria y pago_organizador ya no se leen directo por
--     PostgREST: la policy pide admin.
--
-- Por qué mi_rol() = 'admin' y no un rol nuevo: es la misma regla que ya
-- usa el pago automático, y los operadores de TICKETAZO que entran como
-- cliente (0090) son admin, así que siguen pudiendo girarle a un cliente
-- desde su panel. Hoy no hay ningún perfil staff activo: no le cambia
-- nada a nadie que esté trabajando.
--
-- Los pagos nuevos dejan en la bitácora la cuenta tapada: la bitácora la
-- lee el staff (admin_bitacora, puede_editar()).
-- ============================================================

-- La cuenta tapada: el banco y los últimos 4. Alcanza para que un staff
-- le diga al dueño «sale a tu Unión ···2344» y no para copiarla.
create or replace function cuenta_tapada(p_cuenta text) returns text
  language sql immutable set search_path = public as $$
  select case when p_cuenta is null then null
              else '···' || right(regexp_replace(p_cuenta, '\D', '', 'g'), 4) end
$$;
revoke execute on function cuenta_tapada(text) from anon, public, authenticated;

-- ── guardar la cuenta: sólo admin ───────────────────────────
-- Cuerpo de 0059 tal cual; cambia sólo la guardia.
create or replace function guardar_cuenta_bancaria(p_datos jsonb) returns jsonb
  language plpgsql volatile security definer set search_path = public as $function$
declare
  v_org uuid := mi_organizador();
  v_yo  uuid := auth.uid();
  v_banco text := btrim(coalesce(p_datos->>'banco_codigo',''));
  v_tipo  text := coalesce(nullif(btrim(coalesce(p_datos->>'documento_tipo','')),''), 'CI');
  v_ext   text := nullif(btrim(coalesce(p_datos->>'documento_extension','')), '');
  c cuenta_bancaria;
begin
  if coalesce(mi_rol(), '') <> 'admin' then
    raise exception 'Sin permiso: la cuenta para cobrar la cambia el administrador.';
  end if;

  -- 1005 es el BCP. Con carnet exige la extensión y el liquidador ni
  -- siquiera llama al banco sin ella: mejor enterarse acá.
  if v_banco = '1005' and upper(v_tipo) = 'CI' and v_ext is null then
    return jsonb_build_object('ok', false, 'falta', 'extension',
      'motivo', 'Para una cuenta del BCP con carnet hace falta la extensión (SC, LP, CB…). Sin ella el pago se rechaza.');
  end if;

  update cuenta_bancaria set vigente = false
   where organizador_id = v_org and vigente;

  insert into cuenta_bancaria (organizador_id, banco_codigo, banco_nombre, cuenta,
                               titular_nombres, titular_apellido, titular_apellido2,
                               documento_tipo, documento_numero, documento_extension,
                               ciudad_codigo, creada_por, nota)
  values (v_org, v_banco, btrim(p_datos->>'banco_nombre'), btrim(p_datos->>'cuenta'),
          btrim(p_datos->>'titular_nombres'), btrim(p_datos->>'titular_apellido'),
          nullif(btrim(coalesce(p_datos->>'titular_apellido2','')), ''),
          v_tipo, btrim(p_datos->>'documento_numero'), v_ext,
          coalesce(nullif(btrim(coalesce(p_datos->>'ciudad_codigo','')),''), '701'),
          v_yo, nullif(btrim(coalesce(p_datos->>'nota','')), ''))
  returning * into c;

  return jsonb_build_object('ok', true, 'cuenta', c.id,
    'motivo', format('Guardada la cuenta %s de %s.', c.cuenta, c.banco_nombre));
end $function$;
revoke execute on function guardar_cuenta_bancaria(jsonb) from anon, public;
grant execute on function guardar_cuenta_bancaria(jsonb) to authenticated;

-- ── pedir el pago: sólo admin ───────────────────────────────
-- Cuerpo de 0059; cambian la guardia y la cuenta que queda en la
-- bitácora (tapada).
create or replace function pedir_pago_organizador(p_evento uuid, p_monto numeric default null)
  returns jsonb
  language plpgsql volatile security definer set search_path = public as $function$
declare
  v_org uuid := mi_organizador();
  v_yo  uuid := auth.uid();
  d jsonb; c cuenta_bancaria; v_monto numeric(12,2); p pago_organizador;
begin
  if coalesce(mi_rol(), '') <> 'admin' then
    raise exception 'Sin permiso: el retiro lo pide el administrador.';
  end if;

  perform pg_advisory_xact_lock(hashtext('pago_organizador:' || p_evento::text));

  d := disponible_organizador(p_evento);

  select * into c from cuenta_bancaria
   where organizador_id = v_org and vigente;
  if not found then
    return jsonb_build_object('ok', false, 'falta', 'cuenta',
      'motivo', 'Todavía no cargaste tu cuenta para cobrar.');
  end if;

  v_monto := round(coalesce(p_monto, (d->>'disponible')::numeric), 2);

  if v_monto < 0.01 then
    return jsonb_build_object('ok', false, 'falta', 'saldo', 'disponible', d->>'disponible',
      'motivo', 'No hay nada para retirar todavía.');
  end if;
  if v_monto > (d->>'disponible')::numeric then
    return jsonb_build_object('ok', false, 'falta', 'saldo', 'disponible', d->>'disponible',
      'motivo', format('Sólo hay %s Bs disponibles.', d->>'disponible'));
  end if;

  insert into pago_organizador (organizador_id, evento_id, cuenta_id, monto,
                                banco_nombre, cuenta, titular, pedido_por)
  values (v_org, p_evento, c.id, v_monto, c.banco_nombre, c.cuenta,
          btrim(c.titular_nombres || ' ' || c.titular_apellido || ' ' ||
                coalesce(c.titular_apellido2, '')), v_yo)
  returning * into p;

  insert into admin_bitacora (organizador_id, evento_id, accion, motivo, actor_id, detalle)
  values (v_org, p_evento, 'organizador_pagado',
          format('Pago de %s Bs a %s, cuenta %s', p.monto, p.titular, cuenta_tapada(p.cuenta)), v_yo,
          jsonb_build_object('pago', p.id, 'monto', p.monto, 'banco', p.banco_nombre));

  return jsonb_build_object('ok', true, 'pago', p.id, 'monto', p.monto,
    'beneficiario', jsonb_build_object(
      'banco_codigo', c.banco_codigo, 'cuenta', c.cuenta,
      'nombres', c.titular_nombres, 'apellido', c.titular_apellido,
      'apellido2', c.titular_apellido2,
      'documento_tipo', c.documento_tipo, 'documento_numero', c.documento_numero,
      'documento_extension', c.documento_extension, 'ciudad_codigo', c.ciudad_codigo),
    'motivo', format('Pedido el pago de %s Bs a %s.', p.monto, p.titular));
end $function$;
revoke execute on function pedir_pago_organizador(uuid, numeric) from anon, public;
grant execute on function pedir_pago_organizador(uuid, numeric) to authenticated;

-- ── lo que ve el staff: las cifras sí, la cuenta tapada ─────
-- `cuenta` sigue viniendo (no null) para que un panel viejo no le ofrezca
-- «Cargar la cuenta» a un staff que no la puede guardar; `oculta` le dice
-- al panel nuevo que no la muestre como completa.
create or replace function disponible_organizador(p_evento uuid) returns jsonb
  language plpgsql stable security definer set search_path = public as $function$
declare d jsonb;
begin
  if not puede_editar() then raise exception 'Sin permiso'; end if;
  d := disponible_de(mi_organizador(), p_evento);
  if coalesce(mi_rol(), '') <> 'admin' and jsonb_typeof(d->'cuenta') = 'object' then
    d := jsonb_set(d, '{cuenta}', jsonb_build_object(
           'banco', d->'cuenta'->'banco',
           'cuenta', cuenta_tapada(d->'cuenta'->>'cuenta'),
           'oculta', true));
  end if;
  return d;
end $function$;
revoke execute on function disponible_organizador(uuid) from anon, public;
grant execute on function disponible_organizador(uuid) to authenticated;

create or replace function pagos_organizador(p_evento uuid) returns jsonb
  language plpgsql stable security definer set search_path = public as $function$
declare v_org uuid := mi_organizador(); v_admin boolean := coalesce(mi_rol(), '') = 'admin';
begin
  if not puede_editar() then raise exception 'Sin permiso'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', p.id, 'monto', p.monto, 'estado', p.estado,
             'banco', p.banco_nombre,
             'cuenta', case when v_admin then p.cuenta else cuenta_tapada(p.cuenta) end,
             'titular', p.titular,
             'referencia', p.referencia, 'motivo', p.motivo,
             'pedido_at', p.pedido_at, 'pedido_por', q.nombre)
           order by p.pedido_at desc)
      from pago_organizador p
      left join perfiles q on q.id = p.pedido_por
     where p.evento_id = p_evento and p.organizador_id = v_org), '[]'::jsonb);
end $function$;
revoke execute on function pagos_organizador(uuid) from anon, public;
grant execute on function pagos_organizador(uuid) to authenticated;

-- ── y por PostgREST directo, tampoco ────────────────────────
drop policy if exists "cuenta bancaria: la de mi organizador" on cuenta_bancaria;
create policy "cuenta bancaria: la de mi organizador" on cuenta_bancaria for select to authenticated
  using (organizador_id = mi_organizador() and mi_rol() = 'admin');

drop policy if exists "pago organizador: el de mi organizador" on pago_organizador;
create policy "pago organizador: el de mi organizador" on pago_organizador for select to authenticated
  using (organizador_id = mi_organizador() and mi_rol() = 'admin');

-- ── control ─────────────────────────────────────────────────
select * from chequeo_funciones_sin_guardia();
