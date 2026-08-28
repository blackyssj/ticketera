-- 0005 — planimetría. `bloqueada` es un estado NUEVO, separado de `reservada`:
-- "un desconocido está pagando ahora" no es lo mismo que "el relacionador la
-- comprometió". x/y/w son porcentajes del lienzo, no píxeles.
create table mesas (
  id             uuid primary key default gen_random_uuid(),
  organizador_id uuid not null references organizadores on delete restrict,
  evento_id      uuid not null references eventos on delete cascade,
  planta         text not null default 'baja',
  etiqueta       text not null,
  categoria      text not null default 'mesa' check (categoria in ('mesa','lounge','palco')),
  x numeric(6,3) not null check (x between 0 and 100),
  y numeric(6,3) not null check (y between 0 and 100),
  w numeric(6,3) not null check (w > 0 and w <= 100),
  precio    numeric(12,2) not null check (precio >= 0),
  manillas  int not null default 1 check (manillas >= 1),
  estado    text not null default 'disponible'
              check (estado in ('disponible','bloqueada','reservada','pagada','ocupada')),
  orden_id  uuid,
  updated_at timestamptz not null default now(),
  unique (evento_id, etiqueta)
);
create index mesas_evento_idx on mesas (evento_id, planta);
create index mesas_orden_idx  on mesas (orden_id) where orden_id is not null;
comment on column mesas.manillas is 'Cuántas entradas emite esta mesa. La puerta escanea personas, no muebles.';
comment on column mesas.estado is 'bloqueada = orden pública pendiente. reservada = la comprometió el staff.';
alter table mesas enable row level security;
create policy "mesas: las mías" on mesas for all to authenticated
  using (organizador_id = mi_organizador()) with check (organizador_id = mi_organizador());
revoke all on mesas from anon;
grant select, insert, update, delete on mesas to authenticated;
