-- ============================================================
-- 0115 — dónde va el QR sobre el arte de la entrada, por evento
--
-- ticket.js dibuja el QR encima del arte del evento en un lugar fijo: una
-- caja blanca del 52% del ancho, centrada, desde el 29% de la altura. Son
-- las medidas de Plataforma Puerta, y sirven para los artes hechos para
-- Puerta. Los artes de los clientes no: uno tiene el logo arriba, otro el
-- line-up abajo, y el QR cae encima de lo que el cliente pagó para que se
-- vea. Hasta acá la salida era pedirle al cliente que rehaga la imagen.
--
-- Dos números por evento, los dos como fracción del arte:
--
--   arte_qr_y    dónde arranca la caja, desde arriba (0,29 = 29% de la altura)
--   arte_qr_tam  qué ancho tiene la caja (0,52 = 52% del ancho)
--
-- La caja sigue centrada a lo ancho: correrla de costado no lo pidió nadie y
-- un QR torcido hacia un borde se escanea peor. Null en los dos es la medida
-- de siempre, así que ningún evento que ya vende cambia hasta que alguien
-- toque los controles del panel.
--
-- Valen sólo para el arte del EVENTO. El arte de una fase (el que manda
-- Puerta para Bowie y BurTown) sigue con la medida de Puerta, que es para la
-- que se diseñó.
--
-- Sin funciones nuevas: el panel escribe por la policy «eventos escribir»
-- (puede_editar() y el tenant), igual que con arte_url. Las Edge Functions
-- `evento` y `orden` los leen aparte y con red: si fallan, la entrada sale
-- con la medida de siempre.
--
-- Los topes son los que la caja admite sin romperse: por debajo del 25% el
-- QR no se escanea de lejos; por encima del 75% no queda lugar para el
-- código y el nombre que van debajo. La altura no puede pasar del 70%:
-- ticket.js la sube igual si la caja no entra, pero el dato no puede pedir
-- lo imposible.
-- ============================================================

alter table eventos
  add column if not exists arte_qr_y   numeric(4,3),
  add column if not exists arte_qr_tam numeric(4,3);

do $$ begin
  alter table eventos add constraint eventos_arte_qr_y_check
    check (arte_qr_y is null or arte_qr_y between 0 and 0.70);
exception when duplicate_object then null; end $$;

do $$ begin
  alter table eventos add constraint eventos_arte_qr_tam_check
    check (arte_qr_tam is null or arte_qr_tam between 0.25 and 0.75);
exception when duplicate_object then null; end $$;

comment on column eventos.arte_qr_y is
  'Dónde arranca la caja del QR sobre el arte del evento, como fracción de la altura (0,29 = 29%). Null = 0,29, la medida de Puerta. Solo para el arte del evento, no el de una fase.';
comment on column eventos.arte_qr_tam is
  'Ancho de la caja del QR sobre el arte del evento, como fracción del ancho (0,52 = 52%). Null = 0,52. La caja va siempre centrada a lo ancho.';

-- ── control ─────────────────────────────────────────────────
select * from chequeo_funciones_sin_guardia();
