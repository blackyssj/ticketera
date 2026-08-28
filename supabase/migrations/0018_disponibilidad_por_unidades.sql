-- ============================================================
-- 0018 — el cupo se mide en unidades vendidas, no en QR emitidos
--
-- disponibilidad_tipo() contaba `count(*) from entradas` como "emitidas".
-- Desde 0016 una unidad de un tipo con manillas > 1 inserta
-- cantidad × manillas filas en `entradas` (una por persona que entra con
-- ella), pero lo retenido sigue contando `orden_items.cantidad`. Las dos
-- mitades de la resta dejaron de hablar la misma unidad: Branca Lounge con
-- cupo 9 y manillas 10 quedaba en 0 con una sola unidad vendida.
--
-- El arreglo cuenta lo emitido con la misma vara que lo retenido:
-- `orden_items.cantidad` de las órdenes ya `pagada`. Es la unidad que
-- compró el cliente, no la fila que emite la puerta, así que no se rompe
-- si mañana una orden compra dos unidades del mismo tipo (contar
-- `distinct orden_id` sí se rompería: colapsa a 1 aunque cantidad sea 2).
-- Además deja de depender de `manillas`, que puede cambiar después de
-- emitida la entrada.
-- ============================================================

create or replace function disponibilidad_tipo(p_fase uuid, p_tipo uuid) returns int
  language plpgsql stable security definer set search_path = public as $function$
declare v_cupo int; v_emitidas int; v_retenidas int;
begin
  select cupo into v_cupo from fase_precio where fase_id = p_fase and tipo_id = p_tipo;
  if not found then return 0; end if;
  if v_cupo is null then return null; end if;

  select coalesce(sum(i.cantidad), 0) into v_emitidas
    from orden_items i join ordenes o on o.id = i.orden_id
   where i.fase_id = p_fase and i.tipo_id = p_tipo and o.estado = 'pagada';

  select coalesce(sum(i.cantidad), 0) into v_retenidas
    from orden_items i join ordenes o on o.id = i.orden_id
   where i.fase_id = p_fase and i.tipo_id = p_tipo
     and o.estado = 'pendiente' and o.expira_at > now();

  return greatest(v_cupo - v_emitidas - v_retenidas, 0);
end $function$;
revoke execute on function disponibilidad_tipo(uuid, uuid) from anon, public;
grant execute on function disponibilidad_tipo(uuid, uuid) to authenticated;
