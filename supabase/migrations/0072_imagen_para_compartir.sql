-- ============================================================
-- 0072 — una imagen hecha para el link, no para la pared
--
-- El flyer es vertical: 9:16, pensado para la historia de Instagram y el
-- estado de WhatsApp. La tarjeta de WhatsApp es otra cosa: cuadrada o
-- apaisada, y chica. Un 9:16 ahí sale recortado por el medio —se pierde
-- la fecha de arriba y el nombre de abajo, que es justo lo que la tarjeta
-- tenia que decir— o como un thumbnail de dos centimetros.
--
-- Por eso una columna aparte: la imagen que viaja en la vista previa,
-- compuesta a 1200×1200 sobre el fondo de la marca con el flyer entero
-- adentro. La genera scripts/subir-og.py a partir del flyer; la funcion
-- `og` la prefiere y, si no hay, cae al flyer como hasta hoy.
--
-- No se intenta generar en el servidor: Storage tiene transformacion de
-- imagenes pero esta apagada en el plan (FeatureNotEnabled), y una Edge
-- Function sin librerias no recorta nada. Se hace una vez, al subir.
-- ============================================================
alter table eventos add column if not exists og_url text;
comment on column eventos.og_url is
  'La imagen para la vista previa del link (WhatsApp, Facebook), cuadrada. Distinta del flyer, que es vertical. Null = se usa el flyer.';
