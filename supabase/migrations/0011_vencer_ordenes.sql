-- 0011 — el barrido. Anular una orden vencida sin preguntarle a la pasarela
-- es cobrarle a alguien y no darle la entrada: las que ya iniciaron pago se
-- devuelven en `a_confirmar` y las consulta la Edge Function.
-- A diferencia de Puerta, no exige auth.uid(): la llama un job, no una pantalla.
create function vencer_ordenes(p_evento uuid default null) returns jsonb
  language plpgsql volatile security definer set search_path = public as $function$
declare v_ids uuid[]; v_conf uuid[]; v_mesas int;
begin
  select coalesce(array_agg(id), '{}') into v_conf from ordenes
   where estado = 'pendiente' and expira_at <= now() and pago_ref is not null
     and (p_evento is null or evento_id = p_evento);

  select coalesce(array_agg(id), '{}') into v_ids from ordenes
   where estado = 'pendiente' and expira_at <= now() and pago_ref is null
     and (p_evento is null or evento_id = p_evento);

  if array_length(v_ids, 1) is null then
    return jsonb_build_object('ok', true, 'vencidas', 0, 'mesas_liberadas', 0,
                              'a_confirmar', to_jsonb(v_conf));
  end if;

  update mesas set estado = 'disponible', orden_id = null, updated_at = now()
   where orden_id = any(v_ids) and estado = 'bloqueada';
  get diagnostics v_mesas = row_count;
  update ordenes set estado = 'vencida' where id = any(v_ids);

  return jsonb_build_object('ok', true, 'vencidas', array_length(v_ids, 1),
                            'mesas_liberadas', v_mesas, 'a_confirmar', to_jsonb(v_conf));
end $function$;
revoke execute on function vencer_ordenes(uuid) from anon, public;
