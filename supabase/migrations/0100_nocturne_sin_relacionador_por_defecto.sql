-- ============================================================
-- 0100 — Nocturne vuelve a dejar sin dueño las ventas sin link
--
-- 0098 mandaba a José Menacho toda compra de Nocturne que entrara sin
-- link de relacionador. El 05/10 se pidió lo contrario: que esas queden
-- sin asignar ("público"), como en los demás eventos. Se apaga sólo el
-- dato; la columna y el trigger quedan, sin efecto mientras ningún
-- evento tenga `rrpp_por_defecto`.
--
-- Las órdenes que ya se le acreditaron no se tocan acá: la última
-- (Andrés Retamoso, 05/10 12:11) se pasó a mano a Daniel Balcázar.
-- ============================================================

update eventos e set rrpp_por_defecto = null
  from organizadores g
 where g.id = e.organizador_id and g.slug = 'nocturne' and e.slug = 'halloween-party';
