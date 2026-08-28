-- 0004 — dos ejes de precio. `evento_fase` es la ventana temporal,
-- `tipo_entrada` la categoría; precio y cupo viven en el CRUCE.
create table tipo_entrada (
  id             uuid primary key default gen_random_uuid(),
  organizador_id uuid not null references organizadores on delete restrict,
  evento_id      uuid not null references eventos on delete cascade,
  nombre         text not null,
  descripcion    text,
  manillas       int  not null default 1 check (manillas >= 1),
  orden          int  not null default 0,
  activo         boolean not null default true,
  unique (evento_id, nombre)
);
create index tipo_entrada_ev_idx on tipo_entrada (evento_id, orden);
comment on column tipo_entrada.manillas is 'Cuántas entradas emite una unidad de este tipo.';

create table evento_fase (
  id             uuid primary key default gen_random_uuid(),
  organizador_id uuid not null references organizadores on delete restrict,
  evento_id      uuid not null references eventos on delete cascade,
  nombre         text not null,
  desde          timestamptz,
  hasta          timestamptz,
  arte_url       text,
  orden          int not null default 0,
  activo         boolean not null default true,
  check (desde is null or hasta is null or desde < hasta)
);
create index evento_fase_ev_idx on evento_fase (evento_id, orden);

create table fase_precio (
  organizador_id uuid not null references organizadores on delete restrict,
  fase_id        uuid not null references evento_fase on delete cascade,
  tipo_id        uuid not null references tipo_entrada on delete cascade,
  precio         numeric(12,2) not null check (precio >= 0),
  cupo           int check (cupo is null or cupo > 0),
  primary key (fase_id, tipo_id)
);
create index fase_precio_tipo_idx on fase_precio (tipo_id);
comment on column fase_precio.cupo is 'null = sin tope, corta por fecha. Un número = stock de ese tipo en esa fase.';

create function fase_vigente(p_evento uuid) returns uuid
  language sql stable security definer set search_path = public as $$
  select f.id from evento_fase f
   where f.evento_id = p_evento and f.activo
     and (f.desde is null or f.desde <= now())
     and (f.hasta is null or f.hasta >  now())
   order by f.orden limit 1 $$;
revoke execute on function fase_vigente(uuid) from anon, public;
grant execute on function fase_vigente(uuid) to authenticated;

alter table tipo_entrada enable row level security;
alter table evento_fase  enable row level security;
alter table fase_precio  enable row level security;
create policy "tipos: los míos" on tipo_entrada for all to authenticated
  using (organizador_id = mi_organizador()) with check (organizador_id = mi_organizador());
create policy "fases: las mías" on evento_fase for all to authenticated
  using (organizador_id = mi_organizador()) with check (organizador_id = mi_organizador());
create policy "precios: los míos" on fase_precio for all to authenticated
  using (organizador_id = mi_organizador()) with check (organizador_id = mi_organizador());
revoke all on tipo_entrada, evento_fase, fase_precio from anon;
grant select, insert, update, delete on tipo_entrada, evento_fase, fase_precio to authenticated;
