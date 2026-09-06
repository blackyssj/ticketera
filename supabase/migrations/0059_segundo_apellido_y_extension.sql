-- ============================================================
-- 0059 — el segundo apellido, y la extensión que no es opcional
--
-- Al cargar la primera cuenta real aparecieron dos cosas que el esquema
-- de 0052 no contemplaba, y las dos terminan en el mismo lugar: una
-- transferencia rebotada por el banco.
--
-- ── 1. el segundo apellido ───────────────────────────────────
--
-- `cuenta_bancaria` guarda UN apellido. El titular real se llama
-- "Francisco Aguilera Velarde", y la API del liquidador tiene
-- `firstLastName` y `secondLastName` separados — igual que la tabla del
-- camino batch (`comercio_cuenta_destino`, con apellido1 y apellido2).
-- Que estén separados no es capricho: el banco compara el nombre contra
-- el suyo, campo por campo, y devuelve la transferencia si no coincide.
--
-- Meter "Aguilera Velarde" entero en el primer apellido es apostar a que
-- del otro lado lo comparen concatenado. Es una apuesta que se pierde
-- una semana después, cuando alguien pregunta por qué no le llegó.
--
-- La columna es opcional: hay titulares de un solo apellido, y una
-- empresa con NIT no tiene ninguno.
--
-- ── 2. la extensión del carnet ───────────────────────────────
--
-- El formulario la pedía como "sólo BCP con carnet" y la trataba como
-- opcional. No lo es. El liquidador la valida antes de hablar con el
-- banco:
--
--     documentExtension es requerido para bankCode=1005 y documentType=CI
--
-- O sea: una cuenta del BCP con CI y sin extensión se guarda bien, se ve
-- bien en pantalla, muestra un disponible bien, y falla RECIÉN cuando
-- alguien aprieta "Pagar". Peor todavía con el giro automático: falla
-- sola cada quince minutos y nadie la está mirando.
--
-- Se valida al GUARDAR. Una cuenta que no puede recibir plata no es una
-- cuenta a medio cargar: es un error, y el momento de decirlo es cuando
-- la persona todavía tiene el carnet en la mano.
--
-- Idempotente: `add column if not exists` y `drop function if exists`
-- con la firma completa delante de cada create (invariante 4).
-- ============================================================

alter table cuenta_bancaria
  add column if not exists titular_apellido2 text;

comment on column cuenta_bancaria.titular_apellido2 is
  'Segundo apellido, si tiene. Va separado porque el banco compara campo por campo y devuelve la transferencia si no coincide.';

-- ── guardar la cuenta, ahora con las dos cosas ──────────────
drop function if exists guardar_cuenta_bancaria(jsonb);
create function guardar_cuenta_bancaria(p_datos jsonb) returns jsonb
  language plpgsql volatile security definer set search_path = public as $function$
declare
  v_org uuid := mi_organizador();
  v_yo  uuid := auth.uid();
  v_banco text := btrim(coalesce(p_datos->>'banco_codigo',''));
  v_tipo  text := coalesce(nullif(btrim(coalesce(p_datos->>'documento_tipo','')),''), 'CI');
  v_ext   text := nullif(btrim(coalesce(p_datos->>'documento_extension','')), '');
  c cuenta_bancaria;
begin
  if not puede_editar() then raise exception 'Sin permiso'; end if;

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

-- ── el beneficiario que viaja al liquidador ─────────────────
-- Las dos funciones que arman el pedido tienen que mandar el mismo
-- beneficiario. Se recrean juntas por eso: si una sumara el segundo
-- apellido y la otra no, el pago a mano y el automático irían a nombres
-- distintos y uno de los dos rebotaría.
drop function if exists pedir_pago_organizador(uuid, numeric);
create function pedir_pago_organizador(p_evento uuid, p_monto numeric default null)
  returns jsonb
  language plpgsql volatile security definer set search_path = public as $function$
declare
  v_org uuid := mi_organizador();
  v_yo  uuid := auth.uid();
  d jsonb; c cuenta_bancaria; v_monto numeric(12,2); p pago_organizador;
begin
  if not puede_editar() then raise exception 'Sin permiso'; end if;

  perform pg_advisory_xact_lock(hashtext('pago_organizador:' || p_evento::text));

  d := disponible_organizador(p_evento);

  select * into c from cuenta_bancaria
   where organizador_id = v_org and vigente;
  if not found then
    return jsonb_build_object('ok', false, 'falta', 'cuenta',
      'motivo', 'Todavía no cargaste la cuenta bancaria del organizador.');
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
          format('Pago de %s Bs a %s, cuenta %s', p.monto, p.titular, p.cuenta), v_yo,
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

drop function if exists pedir_pago_auto(uuid);
create function pedir_pago_auto(p_evento uuid) returns jsonb
  language plpgsql volatile security definer set search_path = public as $function$
declare
  v_org uuid; v_min numeric(12,2); v_auto boolean;
  d jsonb; c cuenta_bancaria; v_monto numeric(12,2); p pago_organizador;
begin
  select e.organizador_id, o.pago_auto_minimo, o.pago_automatico
    into v_org, v_min, v_auto
    from eventos e join organizadores o on o.id = e.organizador_id
   where e.id = p_evento;
  if v_org is null then
    return jsonb_build_object('ok', false, 'motivo', 'Ese evento no existe.');
  end if;
  if not v_auto then
    return jsonb_build_object('ok', false, 'motivo', 'Ese organizador no tiene el pago automático puesto.');
  end if;

  perform pg_advisory_xact_lock(hashtext('pago_organizador:' || p_evento::text));

  select * into c from cuenta_bancaria where organizador_id = v_org and vigente;
  if not found then
    return jsonb_build_object('ok', false, 'falta', 'cuenta',
      'motivo', 'El organizador no tiene cuenta bancaria cargada.');
  end if;

  d := disponible_de(v_org, p_evento);
  v_monto := round((d->>'disponible')::numeric, 2);

  if v_monto < v_min then
    return jsonb_build_object('ok', false, 'falta', 'minimo',
      'disponible', v_monto, 'minimo', v_min,
      'motivo', format('Hay %s Bs y el mínimo es %s.', v_monto, v_min));
  end if;

  insert into pago_organizador (organizador_id, evento_id, cuenta_id, monto,
                                banco_nombre, cuenta, titular, pedido_por)
  values (v_org, p_evento, c.id, v_monto, c.banco_nombre, c.cuenta,
          btrim(c.titular_nombres || ' ' || c.titular_apellido || ' ' ||
                coalesce(c.titular_apellido2, '')), null)
  returning * into p;

  return jsonb_build_object('ok', true, 'pago', p.id, 'monto', p.monto,
    'automatico', true,
    'beneficiario', jsonb_build_object(
      'banco_codigo', c.banco_codigo, 'cuenta', c.cuenta,
      'nombres', c.titular_nombres, 'apellido', c.titular_apellido,
      'apellido2', c.titular_apellido2,
      'documento_tipo', c.documento_tipo, 'documento_numero', c.documento_numero,
      'documento_extension', c.documento_extension, 'ciudad_codigo', c.ciudad_codigo),
    'motivo', format('Pago automático de %s Bs a %s.', p.monto, p.titular));
end $function$;
revoke execute on function pedir_pago_auto(uuid) from anon, public, authenticated;

-- ── el titular que muestra la tarjeta ───────────────────────
-- `create or replace` y NO drop: `disponible_organizador` la llama, y un
-- drop con cascade se lo llevaría puesto sin decir nada. Misma firma,
-- mismo tipo de retorno, así que reemplazar alcanza.
create or replace function disponible_de(p_org uuid, p_evento uuid) returns jsonb
  language plpgsql stable security definer set search_path = public as $function$
declare
  e eventos; o organizadores;
  v_bruto numeric(12,2); v_fee numeric(12,2); v_com numeric(12,2);
  v_real numeric(12,2); v_sim_n int; v_sim_bs numeric(12,2);
  v_pagado numeric(12,2); v_tope numeric(12,2); v_techo numeric(12,2);
  v_pasado boolean;
begin
  select * into e from eventos where id = p_evento and organizador_id = p_org;
  if not found then raise exception 'EVENTO_INEXISTENTE: ese evento no es tuyo.'; end if;
  select * into o from organizadores where id = p_org;

  select coalesce(sum(subtotal),0), coalesce(sum(fee),0)
    into v_bruto, v_fee
    from ordenes where evento_id = p_evento and estado = 'pagada';

  select coalesce(sum(subtotal) filter (where coalesce(pago_ref,'') not like 'SIM-%'), 0),
         count(*)                filter (where coalesce(pago_ref,'') like 'SIM-%'),
         coalesce(sum(subtotal)  filter (where coalesce(pago_ref,'') like 'SIM-%'), 0)
    into v_real, v_sim_n, v_sim_bs
    from ordenes where evento_id = p_evento and estado = 'pagada';

  select coalesce(sum(comision),0) into v_com
    from ventas_rrpp_base(p_evento, null);

  select coalesce(sum(monto),0) into v_pagado
    from pago_organizador
   where evento_id = p_evento and estado <> 'rechazado';

  v_pasado := e.estado = 'cerrado' or e.fecha < (now() at time zone 'America/La_Paz')::date;
  v_tope  := round((v_bruto - v_com) * (case when v_pasado then 1 else o.anticipo_pct end), 2);
  v_techo := round(v_real - v_com, 2);

  return jsonb_build_object(
    'ok', true, 'evento', p_evento,
    'bruto', v_bruto, 'fee', v_fee, 'comisiones', v_com,
    'neto', v_bruto - v_com,
    'cobrado_real', v_real,
    'simuladas', v_sim_n, 'simuladas_bs', v_sim_bs,
    'anticipo_pct', case when v_pasado then 1 else o.anticipo_pct end,
    'evento_pasado', v_pasado,
    'tope', v_tope, 'techo_real', v_techo, 'pagado', v_pagado,
    'disponible', greatest(least(v_tope, v_techo) - v_pagado, 0),
    'automatico', o.pago_automatico,
    'minimo', o.pago_auto_minimo,
    'cuenta', (select jsonb_build_object('id', c.id, 'banco', c.banco_nombre,
                                         'cuenta', c.cuenta,
                                         'titular', btrim(c.titular_nombres || ' ' ||
                                                          c.titular_apellido || ' ' ||
                                                          coalesce(c.titular_apellido2, '')),
                                         'apellido2', c.titular_apellido2,
                                         'extension', c.documento_extension,
                                         'documento_tipo', c.documento_tipo,
                                         'banco_codigo', c.banco_codigo)
                 from cuenta_bancaria c
                where c.organizador_id = p_org and c.vigente));
end $function$;
revoke execute on function disponible_de(uuid, uuid) from anon, public, authenticated;
