-- 0002 — staff y resolución del tenant. El organizador sale de acá y NUNCA
-- de un parámetro del cliente.
create table perfiles (
  id             uuid primary key references auth.users on delete cascade,
  organizador_id uuid not null references organizadores on delete restrict,
  nombre         text not null,
  rol            text not null default 'staff' check (rol in ('admin','staff','rrpp')),
  activo         boolean not null default true,
  created_at     timestamptz not null default now()
);
create index perfiles_org_idx on perfiles (organizador_id);

create function mi_organizador() returns uuid
  language sql stable security definer set search_path = public, auth as $$
  select organizador_id from perfiles where id = auth.uid() and activo $$;
revoke execute on function mi_organizador() from anon, public;
grant execute on function mi_organizador() to authenticated;

create function mi_rol() returns text
  language sql stable security definer set search_path = public, auth as $$
  select rol from perfiles where id = auth.uid() and activo $$;
revoke execute on function mi_rol() from anon, public;
grant execute on function mi_rol() to authenticated;

alter table perfiles enable row level security;
create policy "perfiles: ver los de mi organizador" on perfiles for select to authenticated
  using (organizador_id = mi_organizador());
create policy "perfiles: el admin administra los suyos" on perfiles for all to authenticated
  using  (organizador_id = mi_organizador() and mi_rol() = 'admin')
  with check (organizador_id = mi_organizador() and mi_rol() = 'admin');
revoke all on perfiles from anon;
grant select, insert, update, delete on perfiles to authenticated;

create policy "organizadores: el mío" on organizadores for select to authenticated
  using (id = mi_organizador());
grant select on organizadores to authenticated;
