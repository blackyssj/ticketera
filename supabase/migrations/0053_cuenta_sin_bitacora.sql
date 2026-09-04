-- ============================================================
-- 0053 — la cuenta bancaria no va a la bitácora
--
-- 0052 anotaba el cambio de cuenta en `admin_bitacora`, y ahí `evento_id`
-- es not null: un cambio de cuenta no pertenece a ningún evento, así que
-- guardar la cuenta reventaba con un error de constraint. Se descubrió
-- probando la función como un admin de verdad, antes de que la usara nadie.
--
-- El arreglo no es aflojar el not null de una tabla compartida para que
-- entre una fila que no tiene evento: es no escribir esa fila. La
-- auditoría del cambio de cuenta ya existe y es mejor — `cuenta_bancaria`
-- nunca actualiza, agrega: cada cuenta queda con quién la cargó y cuándo,
-- y la anterior sigue ahí con vigente=false. La bitácora sería una copia
-- peor de eso.
--
-- El pago SÍ sigue yendo a la bitácora: ese tiene evento.
-- ============================================================

-- 'cuenta_bancaria_cambiada' se va: ya no lo escribe nadie, y un valor
-- permitido que nada usa es una pista falsa para el que venga después.
alter table admin_bitacora drop constraint if exists admin_bitacora_accion_check;
alter table admin_bitacora add constraint admin_bitacora_accion_check
  check (accion in ('orden_anulada','entrada_anulada','cortesias_emitidas',
                    'revision_confirmada','evento_cerrado','evento_reabierto',
                    'comision_pagada','organizador_pagado'));

drop function if exists guardar_cuenta_bancaria(jsonb);
create function guardar_cuenta_bancaria(p_datos jsonb) returns jsonb
  language plpgsql volatile security definer set search_path = public as $function$
declare
  v_org uuid := mi_organizador();
  v_yo  uuid := auth.uid();
  c cuenta_bancaria;
begin
  if not puede_editar() then raise exception 'Sin permiso'; end if;

  -- Cambiar la cuenta baja la anterior en vez de pisarla: el pago del mes
  -- pasado tiene que poder seguir diciendo a qué cuenta fue.
  update cuenta_bancaria set vigente = false
   where organizador_id = v_org and vigente;

  insert into cuenta_bancaria (organizador_id, banco_codigo, banco_nombre, cuenta,
                               titular_nombres, titular_apellido, documento_tipo,
                               documento_numero, documento_extension, ciudad_codigo,
                               creada_por, nota)
  values (v_org,
          btrim(p_datos->>'banco_codigo'), btrim(p_datos->>'banco_nombre'),
          btrim(p_datos->>'cuenta'),
          btrim(p_datos->>'titular_nombres'), btrim(p_datos->>'titular_apellido'),
          coalesce(nullif(btrim(p_datos->>'documento_tipo'),''), 'CI'),
          btrim(p_datos->>'documento_numero'),
          nullif(btrim(coalesce(p_datos->>'documento_extension','')), ''),
          coalesce(nullif(btrim(coalesce(p_datos->>'ciudad_codigo','')),''), '701'),
          v_yo, nullif(btrim(coalesce(p_datos->>'nota','')), ''))
  returning * into c;

  return jsonb_build_object('ok', true, 'cuenta', c.id,
    'motivo', format('Guardada la cuenta %s de %s.', c.cuenta, c.banco_nombre));
end $function$;
revoke execute on function guardar_cuenta_bancaria(jsonb) from anon, public;
grant execute on function guardar_cuenta_bancaria(jsonb) to authenticated;
