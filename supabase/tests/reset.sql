-- Deja el evento de prueba como recién sembrado. Borra órdenes y entradas.
delete from entradas;
delete from orden_items;
update mesas set orden_id = null,
  estado = case when etiqueta in ('M2','M8','M12','L3','A3') then 'pagada'
                when etiqueta in ('M5','A6') then 'reservada'
                else 'disponible' end;
delete from ordenes;
