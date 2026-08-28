-- 0008 — cuántas quedan. El filtro `expira_at > now()` hace que una orden
-- vencida deje de retener en el instante en que vence, la haya barrido
-- alguien o no. Importa porque acá no hay ningún usuario garantizado que
-- dispare el barrido, como sí pasa en Puerta.
create function disponibilidad_tipo(p_fase uuid, p_tipo uuid) returns int
  language plpgsql stable security definer set search_path = public as $function$
declare v_cupo int; v_emitidas int; v_retenidas int;
begin
  select cupo into v_cupo from fase_precio where fase_id = p_fase and tipo_id = p_tipo;
  if not found then return 0; end if;
  if v_cupo is null then return null; end if;

  select count(*) into v_emitidas from entradas
   where fase_id = p_fase and tipo_id = p_tipo and estado <> 'anulada';

  select coalesce(sum(i.cantidad), 0) into v_retenidas
    from orden_items i join ordenes o on o.id = i.orden_id
   where i.fase_id = p_fase and i.tipo_id = p_tipo
     and o.estado = 'pendiente' and o.expira_at > now();

  return greatest(v_cupo - v_emitidas - v_retenidas, 0);
end $function$;
revoke execute on function disponibilidad_tipo(uuid, uuid) from anon, public;
grant execute on function disponibilidad_tipo(uuid, uuid) to authenticated;
