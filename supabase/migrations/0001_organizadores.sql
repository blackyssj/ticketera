-- 0001 — la raíz del tenant. Los tres parámetros de fee viven en la fila del
-- organizador porque se negocian por cliente.
create table organizadores (
  id          uuid primary key default gen_random_uuid(),
  slug        text not null unique check (slug ~ '^[a-z0-9-]{2,40}$'),
  nombre      text not null,
  activo      boolean not null default true,
  fee_pct              numeric(5,4)  not null default 0.0700 check (fee_pct >= 0 and fee_pct < 1),
  fee_fijo_transaccion numeric(12,2) not null default 3.00   check (fee_fijo_transaccion >= 0),
  fee_piso             numeric(12,2) not null default 5.00   check (fee_piso >= 0),
  comercio_id integer,
  created_at  timestamptz not null default now()
);
comment on table organizadores is 'Raíz del tenant. El slug va en la URL pública: /<slug>/<evento>.';
comment on column organizadores.comercio_id is 'comercios.id en v2pro. 1518 = BeePlay Stage.';
alter table organizadores enable row level security;
revoke all on organizadores from anon, authenticated;
