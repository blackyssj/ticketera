-- 0006 — la orden: la columna vertebral que Puerta no tiene. Sin ella no hay
-- dónde colgar el hold, la client_key ni el reintento del callback.
-- Los montos se CONGELAN al crear: si cambia el precio mientras alguien paga,
-- esa persona paga lo que vio.
create table ordenes (
  id                 uuid primary key default gen_random_uuid(),
  organizador_id     uuid not null references organizadores on delete restrict,
  evento_id          uuid not null references eventos on delete restrict,
  estado             text not null default 'pendiente'
                       check (estado in ('pendiente','pagada','vencida','anulada','revision_manual')),
  client_key         uuid,
  expira_at          timestamptz not null,
  comprador_nombre   text,
  comprador_email    text,
  comprador_telefono text,
  subtotal numeric(12,2) not null check (subtotal >= 0),
  fee      numeric(12,2) not null check (fee >= 0),
  total    numeric(12,2) not null check (total >= 0),
  pago_ref text,
  rrpp_id  uuid references perfiles(id),
  ip_hash  text,
  created_at timestamptz not null default now(),
  pagada_at  timestamptz,
  check (total = subtotal + fee)
);
create unique index ordenes_client_key_uq on ordenes (client_key) where client_key is not null;
create index ordenes_evento_idx     on ordenes (evento_id, estado);
create index ordenes_pendientes_idx on ordenes (evento_id, expira_at) where estado = 'pendiente';
create index ordenes_pago_ref_idx   on ordenes (pago_ref) where pago_ref is not null;
comment on column ordenes.expira_at is
  'Fin del hold. La disponibilidad filtra por expira_at > now(), así que una orden vencida deja de retener stock aunque el barrido no haya corrido.';
comment on column ordenes.client_key is
  'Idempotencia del checkout. Reintentar con la misma clave devuelve la orden original.';

create table orden_items (
  id             uuid primary key default gen_random_uuid(),
  organizador_id uuid not null references organizadores on delete restrict,
  orden_id       uuid not null references ordenes on delete cascade,
  tipo_id        uuid references tipo_entrada on delete restrict,
  fase_id        uuid references evento_fase  on delete restrict,
  mesa_id        uuid references mesas        on delete restrict,
  cantidad       int  not null check (cantidad > 0),
  precio_unitario numeric(12,2) not null check (precio_unitario >= 0),
  constraint orden_items_exclusivo check ((tipo_id is not null) <> (mesa_id is not null)),
  constraint orden_items_fase_si_entrada check (tipo_id is null or fase_id is not null),
  constraint orden_items_mesa_unitaria  check (mesa_id is null or cantidad = 1)
);
create index orden_items_orden_idx on orden_items (orden_id);
create index orden_items_tipo_idx  on orden_items (tipo_id, fase_id) where tipo_id is not null;
create unique index orden_items_mesa_uq on orden_items (mesa_id) where mesa_id is not null;

alter table mesas add constraint mesas_orden_fk
  foreign key (orden_id) references ordenes on delete set null;

alter table ordenes     enable row level security;
alter table orden_items enable row level security;
create policy "ordenes: las de mi organizador" on ordenes for all to authenticated
  using (organizador_id = mi_organizador()) with check (organizador_id = mi_organizador());
create policy "items: los de mi organizador" on orden_items for all to authenticated
  using (organizador_id = mi_organizador()) with check (organizador_id = mi_organizador());
-- El público NO toca esto ni por vista: /orden/<uuid> la sirve una Edge
-- Function. Una vista puede perder security_invoker en un create or replace
-- y exponer todas las compras; una función no tiene esa forma de fallar.
revoke all on ordenes, orden_items from anon;
grant select, insert, update on ordenes, orden_items to authenticated;
