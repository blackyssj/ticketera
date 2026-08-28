-- ============================================================
-- 0012 — la escritura pide rol, no solo tenant
--
-- Las policies del bloque 1 decían `for all to authenticated using
-- (organizador_id = mi_organizador())`. Eso alcanzaba mientras no había
-- usuarios: el tenant era el único filtro porque no había con quién
-- distinguir. Este bloque crea las primeras cuentas, y entre ellas hay
-- relacionadores y porteros que no tienen por qué editar precios.
--
-- Leer sigue siendo por tenant. Escribir pide rol.
-- ============================================================

create function puede_editar() returns boolean
  language sql stable security definer set search_path = public as $$
  select coalesce(mi_rol() in ('admin','staff'), false)
$$;
revoke execute on function puede_editar() from anon, public;
grant execute on function puede_editar() to authenticated;

comment on function puede_editar() is
  'Quién puede tocar el catálogo. rrpp y portero leen lo suyo y nada más.';

-- ── catálogo: leer todo el tenant, escribir solo admin/staff ──
drop policy if exists "tipos: los míos"   on tipo_entrada;
drop policy if exists "fases: las mías"   on evento_fase;
drop policy if exists "precios: los míos" on fase_precio;
drop policy if exists "mesas: las mías"   on mesas;

create policy "tipos leer" on tipo_entrada for select to authenticated
  using (organizador_id = mi_organizador());
create policy "tipos escribir" on tipo_entrada for all to authenticated
  using  (organizador_id = mi_organizador() and puede_editar())
  with check (organizador_id = mi_organizador() and puede_editar());

create policy "fases leer" on evento_fase for select to authenticated
  using (organizador_id = mi_organizador());
create policy "fases escribir" on evento_fase for all to authenticated
  using  (organizador_id = mi_organizador() and puede_editar())
  with check (organizador_id = mi_organizador() and puede_editar());

create policy "precios leer" on fase_precio for select to authenticated
  using (organizador_id = mi_organizador());
create policy "precios escribir" on fase_precio for all to authenticated
  using  (organizador_id = mi_organizador() and puede_editar())
  with check (organizador_id = mi_organizador() and puede_editar());

create policy "mesas leer" on mesas for select to authenticated
  using (organizador_id = mi_organizador());
create policy "mesas escribir" on mesas for all to authenticated
  using  (organizador_id = mi_organizador() and puede_editar())
  with check (organizador_id = mi_organizador() and puede_editar());

-- ── órdenes y entradas: el rrpp ve LO SUYO, nadie las edita a mano ──
drop policy if exists "ordenes: las de mi organizador" on ordenes;
drop policy if exists "items: los de mi organizador"   on orden_items;
drop policy if exists "entradas: las de mi organizador" on entradas;

create policy "ordenes leer" on ordenes for select to authenticated
  using (organizador_id = mi_organizador()
         and (puede_editar() or rrpp_id = auth.uid()));
create policy "ordenes escribir" on ordenes for update to authenticated
  using  (organizador_id = mi_organizador() and puede_editar())
  with check (organizador_id = mi_organizador() and puede_editar());

create policy "items leer" on orden_items for select to authenticated
  using (organizador_id = mi_organizador()
         and (puede_editar() or exists (
           select 1 from ordenes o where o.id = orden_items.orden_id
             and o.rrpp_id = auth.uid())));

create policy "entradas leer" on entradas for select to authenticated
  using (organizador_id = mi_organizador()
         and (puede_editar() or rrpp_id = auth.uid()));
-- La puerta escribe por función, no por policy: `validar_entrada` llega en
-- el bloque 6 y es la única que marca una entrada como usada.

-- Los `insert` de órdenes y entradas los hace service_role desde las Edge
-- Functions, que no pasan por RLS. Nadie autenticado las crea a mano.
revoke insert on ordenes, orden_items, entradas from authenticated;
revoke update on orden_items, entradas from authenticated;
revoke delete on ordenes, orden_items, entradas from authenticated;

-- ── eventos: leer todo el tenant, escribir admin/staff ──
drop policy if exists "eventos: el admin los administra" on eventos;
create policy "eventos escribir" on eventos for all to authenticated
  using  (organizador_id = mi_organizador() and puede_editar())
  with check (organizador_id = mi_organizador() and puede_editar());
