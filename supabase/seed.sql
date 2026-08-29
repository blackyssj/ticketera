-- Semilla del evento real: RED CIRCLE · FEXPO '26, de Amstel.
--
-- Solo entradas. El cliente confirmó que los combos y las reservas de mesa
-- los vende por afuera, no por acá, así que salieron del catálogo: estaban
-- cargados desde su flyer y quedan en el historial de git si algún día
-- vuelven. La maquinaria de mesas (categoría, manillas por producto, plano,
-- asignación) sigue en la base sin usarse — es de otro cliente, no de este.
--
-- Es idempotente: correrla dos veces converge al mismo estado. Y no borra
-- nada que ya tenga ventas colgando.
--
-- comercio_id 1518 = BeePlay Stage, el de pruebas de la pasarela.

-- El fee es el negocio: 8% del subtotal, sin componente fijo y sin piso.
-- Ojo con eso último, porque no es un olvido y tiene consecuencias: la
-- pasarela cobra POR TRANSACCIÓN, no por entrada. En una orden de Bs 40 el
-- 8% son Bs 3,20 y ahí el margen se lo come el costo de cobrar. La orden
-- chica pierde plata; la mediana la compensa. Si eso deja de cerrar, la
-- palanca es fee_fijo_transaccion, que existe justo para esto.
insert into organizadores (id, slug, nombre, comercio_id,
                           fee_pct, fee_fijo_transaccion, fee_piso) values
  ('a0000000-0000-4000-8000-000000000001', 'amstel', 'Amstel', 1518,
   0.0800, 0, 0)
on conflict (slug) do update set nombre      = excluded.nombre,
                                 comercio_id = excluded.comercio_id,
                                 fee_pct     = excluded.fee_pct,
                                 fee_fijo_transaccion = excluded.fee_fijo_transaccion,
                                 fee_piso    = excluded.fee_piso;

insert into eventos (id, organizador_id, slug, nombre, descripcion, lugar, fecha, hora_inicio, estado)
values ('e0000000-0000-4000-8000-000000000001','a0000000-0000-4000-8000-000000000001',
        'red-circle','RED CIRCLE',
        'La noche de Amstel en la Fexpo. Elegí tu entrada, pagá con QR y te la llevás al toque.',
        'Fexpo ''26 · Santa Cruz de la Sierra',
        '2026-09-12','21:00','publicado')
on conflict (id) do update set slug        = excluded.slug,
                               nombre      = excluded.nombre,
                               descripcion = excluded.descripcion,
                               lugar       = excluded.lugar,
                               fecha       = excluded.fecha,
                               hora_inicio = excluded.hora_inicio,
                               estado      = excluded.estado;

-- ── una sola fase ────────────────────────────────────────────────────────
-- Las reservas no tienen preventa escalonada: hay un precio y se vende hasta
-- que arranca. Las dos fases de la demo se van, pero solo si nadie compró
-- con ellas — un `delete` a secas acá borraría el historial de un evento en
-- curso la próxima vez que alguien corra la semilla.
delete from evento_fase f
 where f.evento_id = 'e0000000-0000-4000-8000-000000000001'
   and f.id <> '22000000-0000-4000-8000-000000000010'
   -- va ANTES del insert: las fases viejas ocupan el orden 1, que es el que
   -- la fase nueva necesita, y (evento_id, orden) es único.
   and not exists (select 1 from orden_items oi where oi.fase_id = f.id)
   and not exists (select 1 from entradas   e  where e.fase_id  = f.id);

insert into evento_fase (id, organizador_id, evento_id, nombre, desde, hasta, orden)
values ('22000000-0000-4000-8000-000000000010','a0000000-0000-4000-8000-000000000001',
        'e0000000-0000-4000-8000-000000000001',
        'Preventa', now() - interval '1 day', '2026-09-12 23:00-04', 1)
on conflict (id) do update set nombre = excluded.nombre,
                               desde  = excluded.desde,
                               hasta  = excluded.hasta;

-- ── las entradas: lo único que se vende ──────────────────────────────────
-- El flyer del cliente es solo de reservas, así que estos dos precios son
-- PROVISORIOS hasta que confirme los suyos.
insert into tipo_entrada (id, organizador_id, evento_id, nombre, descripcion, incluye,
                          categoria, manillas, orden, activo) values
 ('11000000-0000-4000-8000-000000000001','a0000000-0000-4000-8000-000000000001',
  'e0000000-0000-4000-8000-000000000001','General',
  'Acceso al predio durante la noche.', null,'entrada',1,1,true),
 ('11000000-0000-4000-8000-000000000002','a0000000-0000-4000-8000-000000000001',
  'e0000000-0000-4000-8000-000000000001','VIP',
  'Sector elevado, con barra propia.',
  'Dos Amstel de bienvenida.','entrada',1,2,true)
on conflict (id) do update set nombre      = excluded.nombre,
                               descripcion = excluded.descripcion,
                               incluye     = excluded.incluye,
                               categoria   = excluded.categoria,
                               manillas    = excluded.manillas,
                               orden       = excluded.orden,
                               activo      = excluded.activo;

-- ── precio y cupo ────────────────────────────────────────────────────────
-- Los cupos son PROVISORIOS hasta que el cliente confirme los suyos.
insert into fase_precio (organizador_id, fase_id, tipo_id, precio, cupo) values
 ('a0000000-0000-4000-8000-000000000001','22000000-0000-4000-8000-000000000010','11000000-0000-4000-8000-000000000001',120,400),
 ('a0000000-0000-4000-8000-000000000001','22000000-0000-4000-8000-000000000010','11000000-0000-4000-8000-000000000002',250,60)
on conflict (fase_id, tipo_id) do update set precio = excluded.precio,
                                             cupo   = excluded.cupo;
