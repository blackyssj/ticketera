-- ============================================================
-- 0080 — TICKETAZO puede girarle a un cliente sin entrar como el cliente
--
-- La regla de negocio del cliente es un giro por día al cerrar el día
-- (0076/0077). Pero un cliente llama y pide su plata antes, o hay que
-- adelantarle para pagar al sonidista, y hoy la única forma de girar a
-- mano es entrar al panel CON LAS CREDENCIALES DEL CLIENTE: la función
-- que pide el pago está atada a `mi_organizador()`.
--
-- Eso es malo por dos motivos. El obvio: para mover plata de nuestro
-- negocio hay que tener la clave del cliente guardada en algún lado. Y el
-- que importa más: en la bitácora del cliente ese giro figura como si lo
-- hubiera pedido él, y el día que reclame no hay forma de mostrar quién
-- apretó.
--
-- Esta función es la misma de siempre —mismo candado por evento, mismo
-- tope de anticipo, misma cuenta bancaria vigente— con dos diferencias:
-- el organizador sale DEL EVENTO y no de la sesión, y la guardia es
-- `es_plataforma()` en vez de `puede_editar()`.
--
-- ── por qué queda como pago "a mano" y no automático ──
--
-- `pedido_por` guarda el operador de plataforma que lo pidió. Además de
-- dejar el rastro, eso lo saca de la cuenta del giro diario: la guardia
-- de 0076 sólo mira los pagos con `pedido_por is null`. Así, adelantarle
-- plata a un cliente a las tres de la tarde no le cancela el cierre de
-- esa medianoche — le baja el monto, que es lo correcto, porque el
-- disponible ya descuenta lo pedido.
--
-- ── por qué la bitácora va al organizador y no a nosotros ──
--
-- Porque es SU plata y es su registro. La entrada dice quién de
-- TICKETAZO la pidió, así que el cliente puede ver en su propio panel que
-- el giro no lo hizo él. Esconderlo en un log nuestro sería exactamente
-- lo que hace falta evitar.
-- ============================================================

drop function if exists pedir_pago_plataforma(uuid, numeric);
create function pedir_pago_plataforma(p_evento uuid, p_monto numeric default null)
  returns jsonb
  language plpgsql volatile security definer set search_path = public as $function$
declare
  v_org uuid; v_yo uuid := auth.uid();
  d jsonb; c cuenta_bancaria; v_monto numeric(12,2); p pago_organizador;
begin
  if not es_plataforma() then raise exception 'Sin permiso'; end if;

  select e.organizador_id into v_org from eventos e where e.id = p_evento;
  if v_org is null then
    return jsonb_build_object('ok', false, 'motivo', 'Ese evento no existe.');
  end if;

  -- El mismo candado que el pago del cliente y que el automático: los tres
  -- compiten por el mismo disponible y no pueden leerlo a la vez.
  perform pg_advisory_xact_lock(hashtext('pago_organizador:' || p_evento::text));

  d := disponible_de(v_org, p_evento);

  select * into c from cuenta_bancaria where organizador_id = v_org and vigente;
  if not found then
    return jsonb_build_object('ok', false, 'falta', 'cuenta',
      'motivo', 'Ese cliente todavía no tiene cargada su cuenta bancaria.');
  end if;

  v_monto := round(coalesce(p_monto, (d->>'disponible')::numeric), 2);

  if v_monto < 0.01 then
    return jsonb_build_object('ok', false, 'falta', 'saldo', 'disponible', d->>'disponible',
      'motivo', 'No hay nada para girarle todavía.');
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

  -- En la bitácora DEL CLIENTE, diciendo que lo pidió TICKETAZO.
  insert into admin_bitacora (organizador_id, evento_id, accion, motivo, actor_id, detalle)
  values (v_org, p_evento, 'organizador_pagado',
          format('Pago de %s Bs a %s, cuenta %s — pedido por TICKETAZO',
                 p.monto, p.titular, p.cuenta), v_yo,
          jsonb_build_object('pago', p.id, 'monto', p.monto,
                             'banco', p.banco_nombre, 'via', 'plataforma'));

  return jsonb_build_object('ok', true, 'pago', p.id, 'monto', p.monto,
    'beneficiario', jsonb_build_object(
      'banco_codigo', c.banco_codigo, 'cuenta', c.cuenta,
      'nombres', c.titular_nombres, 'apellido', c.titular_apellido,
      'apellido2', c.titular_apellido2,
      'documento_tipo', c.documento_tipo, 'documento_numero', c.documento_numero,
      'documento_extension', c.documento_extension, 'ciudad_codigo', c.ciudad_codigo),
    'motivo', format('Pedido el pago de %s Bs a %s.', p.monto, p.titular));
end $function$;
revoke execute on function pedir_pago_plataforma(uuid, numeric) from anon, public;
grant execute on function pedir_pago_plataforma(uuid, numeric) to authenticated;

comment on function pedir_pago_plataforma(uuid, numeric) is
  'Gira a un cliente desde una cuenta de TICKETAZO, sin entrar con las credenciales del cliente. Guardada por es_plataforma(). Mismo candado, mismo tope de anticipo y misma cuenta vigente que el pago del propio organizador; queda registrado como pago a mano (pedido_por = el operador), asi que no consume el giro diario automatico.';

-- ── control ─────────────────────────────────────────────────
select * from chequeo_funciones_sin_guardia();
