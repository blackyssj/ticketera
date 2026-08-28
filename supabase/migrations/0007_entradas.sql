-- 0007 — entradas emitidas. Tres diferencias con Puerta: rrpp_id nullable,
-- orden_id nuevo, y `canal` como dato propio — deducir "es pública porque
-- rrpp_id is null" es el NULL = NULL esperando a morder.
create table entradas (
  id             uuid primary key default gen_random_uuid(),
  organizador_id uuid not null references organizadores on delete restrict,
  evento_id      uuid not null references eventos on delete cascade,
  orden_id       uuid references ordenes on delete restrict,
  code           text not null,
  canal          text not null check (canal in ('publico','rrpp','puerta','cortesia')),
  tipo_id  uuid references tipo_entrada on delete set null,
  fase_id  uuid references evento_fase  on delete set null,
  mesa_id  uuid references mesas        on delete set null,
  rrpp_id  uuid references perfiles(id),
  cliente  text,
  precio   numeric(12,2) not null check (precio >= 0),
  estado   text not null default 'valida' check (estado in ('valida','usada','anulada')),
  created_at timestamptz not null default now(),
  used_at    timestamptz,
  portero_id uuid references perfiles(id),
  unique (evento_id, code)
);
create index entradas_orden_idx  on entradas (orden_id) where orden_id is not null;
create index entradas_evento_idx on entradas (evento_id, canal);
create index entradas_fase_idx   on entradas (fase_id) where fase_id is not null;
comment on column entradas.canal is 'De dónde vino la venta. Dato propio, nunca deducido de rrpp_id is null.';

-- Base32 sin vocales (no se forman palabras) y sin 0/O ni 1/I.
create function nuevo_code() returns text
  language sql volatile set search_path = public as $$
  select string_agg(substr('23456789BCDFGHJKLMNPQRSTVWXZ',
                           1 + floor(random() * 28)::int, 1), '')
    from generate_series(1, 12) $$;
revoke execute on function nuevo_code() from anon, public;
grant execute on function nuevo_code() to authenticated;

alter table entradas enable row level security;
create policy "entradas: las de mi organizador" on entradas for all to authenticated
  using (organizador_id = mi_organizador()) with check (organizador_id = mi_organizador());
revoke all on entradas from anon;
grant select, insert, update on entradas to authenticated;
