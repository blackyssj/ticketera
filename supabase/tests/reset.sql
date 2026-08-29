-- Deja el evento como recién sembrado. Borra órdenes y entradas.
--
-- Las mesas vuelven todas a 'disponible' y sin orden: los estados
-- 'pagada'/'reservada' que tenía este script eran de la planimetría de la
-- demo vieja, sin ninguna orden detrás. Con la mesa asignada por el admin
-- (0029), arrancar con mesas falsamente ocupadas deja fuera del selector a
-- mesas que están libres.
delete from puerta_bitacora;
delete from entradas;
delete from orden_items;
update ordenes set mesa_asignada_id = null;
update mesas set orden_id = null, estado = 'disponible';
delete from ordenes;
