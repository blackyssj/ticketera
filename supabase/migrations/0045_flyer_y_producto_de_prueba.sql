-- ============================================================
-- 0045 — el flyer de la cartelera, y qué producto la hace hablar
--
-- Dos cosas que la portada necesita y que hasta hoy no existían en ningún
-- lado más que en la cabeza de quien cargó los datos.
--
-- 1. `eventos.flyer_url` existe desde 0003 y no lo usaba nadie. La portada
--    venía mostrando `arte_url`, que es OTRA cosa: el modelo sobre el que se
--    dibuja la entrada, con la marca arriba y un hueco al medio para el QR.
--    Recortado en una tarjeta de 4:5 lo que se ve de ese modelo es el hueco.
--    El flyer es la imagen que el organizador ya publicó en Instagram y que
--    la gente reconoce; son dos imágenes distintas con dos trabajos
--    distintos y merecen dos columnas. Acá solo se documenta cuál es cuál,
--    porque la confusión ya costó una portada.
--
-- 2. `tipo_entrada.en_cartelera`. La tarjeta de RED CIRCLE anunciaba
--    "DESDE 1 BS" porque el producto más barato del evento es «Prueba de
--    cobro», que existe para verificar la pasarela y no para entrar a la
--    fiesta — su propia descripción lo dice. El modelo no tenía forma de
--    decirlo: `activo` apaga la venta (y apagarlo rompe la prueba), y
--    `categoria` solo distingue entrada de mesa, así que meter ahí un
--    tercer valor haría desaparecer el producto de la página del evento —
--    app.js arma dos grupos y descarta lo que no cae en ninguno.
--
--    Lo que faltaba es más chico que todo eso: si el producto cuenta o no
--    para lo que la cartelera dice del evento. La columna se llama por lo
--    único que hace, y no algo más ancho tipo `publico`, que prometería un
--    ocultamiento que este código no implementa: el producto se sigue
--    vendiendo y se sigue viendo en la página del evento, que es lo que
--    mantiene viva la prueba de cobro por el camino real del comprador.
--
-- Sin funciones: no hay nada que revocar ni ningún search_path que fijar.
-- El corte por organizador tampoco cambia — la columna vive en una tabla
-- que ya tiene RLS por `mi_organizador()` desde 0012 y hereda sus policies.
-- Idempotente y corrida dos veces.
-- ============================================================

comment on column eventos.flyer_url is
  'El afiche del evento: la imagen que el organizador publicó en redes. Es la
   cara del evento en la cartelera (/) y NO se dibuja nada encima. Distinta de
   arte_url, que es el modelo de la entrada y lleva el QR.';

alter table tipo_entrada
  add column if not exists en_cartelera boolean not null default true;

comment on column tipo_entrada.en_cartelera is
  'Si este producto cuenta para lo que la portada dice del evento: el "desde"
   y el estado de venta (agotado / últimas). En false para instrumentos que no
   son una oferta al público — la «Prueba de cobro» de Bs 1 con la que se
   verifica la pasarela. NO oculta nada: el producto se sigue vendiendo y se
   sigue viendo en la página del evento.';
