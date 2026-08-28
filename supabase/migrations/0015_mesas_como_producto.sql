-- ============================================================
-- 0015 — la mesa se vende como producto, no como lugar en un plano
--
-- El comprador no elige M7: compra "Branca Lounge" o "Mesa", y el
-- relacionador le asigna la mesa física después. Así es como venden de
-- verdad, y encima saca de la venta pública el problema más caro que
-- tenía: dos personas peleando por la misma chapa mientras pagan.
--
-- No hace falta tabla nueva. Una mesa es un `tipo_entrada` con otra
-- categoría: hereda cupo por fase, fee, idempotencia y emisión sin
-- escribir una línea de eso otra vez. `mesas` sigue existiendo para la
-- asignación interna, que llega con la vista del relacionador.
-- ============================================================

alter table tipo_entrada
  add column if not exists categoria text not null default 'entrada';

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'tipo_entrada_categoria_ck') then
    alter table tipo_entrada add constraint tipo_entrada_categoria_ck
      check (categoria in ('entrada','mesa'));
  end if;
end $$;

alter table tipo_entrada add column if not exists incluye text;

comment on column tipo_entrada.categoria is
  'entrada = una persona. mesa = un espacio para un grupo; el relacionador
   asigna cuál después, desde `mesas`.';
comment on column tipo_entrada.incluye is
  'Qué se lleva quien lo compra. Se muestra tal cual al comprador, así que
   se escribe para él y no para el sistema.';

-- Ata la orden con la mesa física que el staff le asignó. Nulo hasta que
-- alguien la asigne: la venta no espera a que haya plano cargado.
alter table ordenes add column if not exists mesa_asignada_id uuid references mesas on delete set null;
create index if not exists ordenes_mesa_asignada_idx
  on ordenes (mesa_asignada_id) where mesa_asignada_id is not null;
comment on column ordenes.mesa_asignada_id is
  'La mesa física que el relacionador le dio a esta compra. Se asigna después
   de vender, no durante: el comprador compró el producto, no el lugar.';
