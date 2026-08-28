-- Semilla del evento real: RED CIRCLE · FEXPO '26, de Amstel.
--
-- Los cinco combos salen del flyer de reservas que mandó el cliente. Lo que
-- se vende acá son RESERVAS, no entradas sueltas: por eso los cinco son
-- categoria='mesa' y cada uno emite tantas entradas como manillas incluye.
-- Las manillas son las del flyer tal cual — "10 MANILLAS X 2 DÍAS" son diez
-- manillas que valen dos días, no veinte manillas.
--
-- Es idempotente: correrla dos veces converge al mismo estado. Y no borra
-- nada que ya tenga ventas colgando.
--
-- comercio_id 1518 = BeePlay Stage, el de pruebas de la pasarela.

insert into organizadores (id, slug, nombre, comercio_id) values
  ('a0000000-0000-4000-8000-000000000001', 'amstel', 'Amstel', 1518)
on conflict (slug) do update set nombre = excluded.nombre,
                                 comercio_id = excluded.comercio_id;

insert into eventos (id, organizador_id, slug, nombre, descripcion, lugar, fecha, hora_inicio, estado)
values ('e0000000-0000-4000-8000-000000000001','a0000000-0000-4000-8000-000000000001',
        'red-circle','RED CIRCLE',
        'Reservá tu mesa para las noches de Amstel en la Fexpo. Elegí el combo, pagá con QR y las manillas te llegan al correo.',
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
        'Reservas', now() - interval '1 day', '2026-09-12 23:00-04', 1)
on conflict (id) do update set nombre = excluded.nombre,
                               desde  = excluded.desde,
                               hasta  = excluded.hasta;

-- ── los cinco combos del flyer ───────────────────────────────────────────
insert into tipo_entrada (id, organizador_id, evento_id, nombre, descripcion, incluye,
                          categoria, manillas, orden, activo) values
 ('11000000-0000-4000-8000-000000000011','a0000000-0000-4000-8000-000000000001',
  'e0000000-0000-4000-8000-000000000001','Combo Sábados + Serenata',
  'Tu mesa para los sábados y la noche de serenata.',
  'Bs 6.000 en consumo + 10 manillas, válidas los 3 días.','mesa',10,1,true),
 ('11000000-0000-4000-8000-000000000012','a0000000-0000-4000-8000-000000000001',
  'e0000000-0000-4000-8000-000000000001','Combo Sábados',
  'Tu mesa para los sábados de la Fexpo.',
  'Bs 4.000 en consumo + 10 manillas, válidas los 2 días.','mesa',10,2,true),
 ('11000000-0000-4000-8000-000000000013','a0000000-0000-4000-8000-000000000001',
  'e0000000-0000-4000-8000-000000000001','Jueves de Frater · 20 manillas',
  'Tu mesa para el jueves de frater, para el grupo grande.',
  'Bs 3.000 en consumo + 20 manillas + 2 baldes Amstel.','mesa',20,3,true),
 ('11000000-0000-4000-8000-000000000014','a0000000-0000-4000-8000-000000000001',
  'e0000000-0000-4000-8000-000000000001','Jueves de Frater · 10 manillas',
  'Tu mesa para el jueves de frater.',
  'Bs 2.000 en consumo + 10 manillas + 2 baldes Amstel.','mesa',10,4,true),
 ('11000000-0000-4000-8000-000000000015','a0000000-0000-4000-8000-000000000001',
  'e0000000-0000-4000-8000-000000000001','Combo Viernes',
  'Tu mesa para el viernes.',
  'Bs 1.500 en consumo + 5 manillas por 1 día.','mesa',5,5,true)
on conflict (id) do update set nombre      = excluded.nombre,
                               descripcion = excluded.descripcion,
                               incluye     = excluded.incluye,
                               categoria   = excluded.categoria,
                               manillas    = excluded.manillas,
                               orden       = excluded.orden,
                               activo      = excluded.activo;

-- Lo de la demo (General, VIP, Amstel Club, Branca Lounge, Mesas) se apaga,
-- no se borra: apagado deja de venderse (0020) y el historial queda.
update tipo_entrada set activo = false
 where evento_id = 'e0000000-0000-4000-8000-000000000001'
   and id not in ('11000000-0000-4000-8000-000000000011',
                  '11000000-0000-4000-8000-000000000012',
                  '11000000-0000-4000-8000-000000000013',
                  '11000000-0000-4000-8000-000000000014',
                  '11000000-0000-4000-8000-000000000015');

-- ── precio y cupo ────────────────────────────────────────────────────────
-- El cupo es cuántas reservas de cada combo hay para vender. El flyer no lo
-- dice: estos números son PROVISORIOS hasta que el cliente los confirme.
insert into fase_precio (organizador_id, fase_id, tipo_id, precio, cupo) values
 ('a0000000-0000-4000-8000-000000000001','22000000-0000-4000-8000-000000000010','11000000-0000-4000-8000-000000000011',8000,10),
 ('a0000000-0000-4000-8000-000000000001','22000000-0000-4000-8000-000000000010','11000000-0000-4000-8000-000000000012',5500,14),
 ('a0000000-0000-4000-8000-000000000001','22000000-0000-4000-8000-000000000010','11000000-0000-4000-8000-000000000013',3000,12),
 ('a0000000-0000-4000-8000-000000000001','22000000-0000-4000-8000-000000000010','11000000-0000-4000-8000-000000000014',2000,18),
 ('a0000000-0000-4000-8000-000000000001','22000000-0000-4000-8000-000000000010','11000000-0000-4000-8000-000000000015',1500,20)
on conflict (fase_id, tipo_id) do update set precio = excluded.precio,
                                             cupo   = excluded.cupo;
