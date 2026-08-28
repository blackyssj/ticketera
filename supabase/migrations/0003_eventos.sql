-- 0003 — eventos. El slug es único POR ORGANIZADOR, no global.
create table eventos (
  id             uuid primary key default gen_random_uuid(),
  organizador_id uuid not null references organizadores on delete restrict,
  slug           text not null check (slug ~ '^[a-z0-9-]{2,60}$'),
  nombre         text not null,
  descripcion    text,
  lugar          text,
  flyer_url      text,
  fecha          date not null,
  hora_inicio    time not null default '21:00',
  hora_fin       time not null default '06:00',
  edad_min       int  not null default 18,
  estado         text not null default 'borrador' check (estado in ('borrador','publicado','cerrado')),
  tope_entradas_orden int not null default 10 check (tope_entradas_orden between 1 and 50),
  created_at     timestamptz not null default now(),
  unique (organizador_id, slug)
);
create index eventos_org_fecha_idx on eventos (organizador_id, fecha desc);
comment on column eventos.tope_entradas_orden is 'Máximo de entradas por orden pública. Freno de abuso.';
alter table eventos enable row level security;
create policy "eventos: los de mi organizador" on eventos for select to authenticated
  using (organizador_id = mi_organizador());
create policy "eventos: el admin los administra" on eventos for all to authenticated
  using  (organizador_id = mi_organizador() and mi_rol() = 'admin')
  with check (organizador_id = mi_organizador() and mi_rol() = 'admin');
revoke all on eventos from anon;
grant select, insert, update, delete on eventos to authenticated;
