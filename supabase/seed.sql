-- Semilla: el evento de la demo, con los mismos datos que datos-demo.js.
-- comercio_id 1518 = BeePlay Stage, el de pruebas de la pasarela.
insert into organizadores (id, slug, nombre, comercio_id) values
  ('a0000000-0000-4000-8000-000000000001', 'amstel', 'Amstel', 1518)
on conflict (slug) do nothing;

insert into eventos (id, organizador_id, slug, nombre, lugar, fecha, hora_inicio, estado)
values ('e0000000-0000-4000-8000-000000000001','a0000000-0000-4000-8000-000000000001',
        'ferial','Amstel Ferial','Feria Exposición · Santa Cruz de la Sierra',
        '2026-09-12','21:00','publicado')
on conflict (organizador_id, slug) do nothing;

insert into tipo_entrada (id, organizador_id, evento_id, nombre, descripcion, orden) values
 ('11000000-0000-4000-8000-000000000001','a0000000-0000-4000-8000-000000000001','e0000000-0000-4000-8000-000000000001','General','Acceso general a los tres escenarios.',1),
 ('11000000-0000-4000-8000-000000000002','a0000000-0000-4000-8000-000000000001','e0000000-0000-4000-8000-000000000001','VIP','Sector elevado, barra propia y dos Amstel de bienvenida.',2),
 ('11000000-0000-4000-8000-000000000003','a0000000-0000-4000-8000-000000000001','e0000000-0000-4000-8000-000000000001','Amstel Club','Terraza cerrada, atención en el lugar y acceso al backstage.',3)
on conflict (evento_id, nombre) do nothing;

insert into evento_fase (id, organizador_id, evento_id, nombre, desde, hasta, orden) values
 ('22000000-0000-4000-8000-000000000001','a0000000-0000-4000-8000-000000000001','e0000000-0000-4000-8000-000000000001',
  'Preventa 2', now() - interval '10 days', '2026-09-05 23:59-04', 1),
 ('22000000-0000-4000-8000-000000000002','a0000000-0000-4000-8000-000000000001','e0000000-0000-4000-8000-000000000001',
  'General', '2026-09-06 00:00-04', '2026-09-12 23:00-04', 2)
on conflict do nothing;

insert into fase_precio (organizador_id, fase_id, tipo_id, precio, cupo) values
 ('a0000000-0000-4000-8000-000000000001','22000000-0000-4000-8000-000000000001','11000000-0000-4000-8000-000000000001',120,340),
 ('a0000000-0000-4000-8000-000000000001','22000000-0000-4000-8000-000000000001','11000000-0000-4000-8000-000000000002',250,18),
 ('a0000000-0000-4000-8000-000000000001','22000000-0000-4000-8000-000000000001','11000000-0000-4000-8000-000000000003',420,6),
 ('a0000000-0000-4000-8000-000000000001','22000000-0000-4000-8000-000000000002','11000000-0000-4000-8000-000000000001',150,400),
 ('a0000000-0000-4000-8000-000000000001','22000000-0000-4000-8000-000000000002','11000000-0000-4000-8000-000000000002',290,20)
on conflict (fase_id, tipo_id) do nothing;

insert into mesas (organizador_id, evento_id, planta, etiqueta, categoria, x, y, w, precio, manillas, estado)
select 'a0000000-0000-4000-8000-000000000001','e0000000-0000-4000-8000-000000000001',
       v.planta, v.et, v.cat, v.x, v.y, v.w, v.precio, v.manillas, v.estado
from (values
 ('baja','M1','mesa',16,26,7.4,1200,8,'disponible'),
 ('baja','M2','mesa',28,22,7.4,1200,8,'pagada'),
 ('baja','M3','mesa',40,20,7.4,1200,8,'disponible'),
 ('baja','M4','mesa',52,20,7.4,1200,8,'disponible'),
 ('baja','M5','mesa',64,22,7.4,1200,8,'reservada'),
 ('baja','M6','mesa',76,26,7.4,1200,8,'disponible'),
 ('baja','M7','mesa',18,44,7.4,1000,8,'disponible'),
 ('baja','M8','mesa',31,42,7.4,1000,8,'pagada'),
 ('baja','M9','mesa',44,41,7.4,1000,8,'disponible'),
 ('baja','M10','mesa',57,41,7.4,1000,8,'disponible'),
 ('baja','M11','mesa',70,42,7.4,1000,8,'disponible'),
 ('baja','M12','mesa',83,44,7.4,1000,8,'pagada'),
 ('baja','L1','lounge',24,66,10,2500,12,'disponible'),
 ('baja','L2','lounge',50,68,10,2800,12,'disponible'),
 ('baja','L3','lounge',76,66,10,2500,12,'pagada'),
 ('alta','A1','mesa',20,24,8,1500,8,'disponible'),
 ('alta','A2','mesa',36,20,8,1500,8,'disponible'),
 ('alta','A3','mesa',56,20,8,1500,8,'pagada'),
 ('alta','A4','mesa',72,24,8,1500,8,'disponible'),
 ('alta','A5','mesa',24,46,8,1300,8,'disponible'),
 ('alta','A6','mesa',44,44,8,1300,8,'reservada'),
 ('alta','A7','mesa',64,46,8,1300,8,'disponible'),
 ('alta','P1','lounge',32,70,12,3600,14,'disponible'),
 ('alta','P2','lounge',66,70,12,3600,14,'disponible')
) as v(planta,et,cat,x,y,w,precio,manillas,estado)
on conflict (evento_id, etiqueta) do nothing;
