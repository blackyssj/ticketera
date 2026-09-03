-- La aceptación de los términos queda en la orden, no en el comprador: lo
-- que se acepta es la versión vigente en el momento de ESA compra. Si los
-- términos cambian mañana, la compra de hoy sigue atada a los de hoy.
-- Nullable a propósito: las órdenes anteriores a esta migración no tienen
-- aceptación registrada y eso es un dato, no un error.
alter table ordenes
  add column if not exists tc_aceptado_at timestamptz,
  add column if not exists tc_version text;
