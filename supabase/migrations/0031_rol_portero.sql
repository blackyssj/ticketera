-- ============================================================
-- 0031 — el rol portero
--
-- Ve nombres de compradores toda la noche, desde un teléfono prestado, en
-- la puerta de un boliche. Por eso su permiso es el más chico de todos:
-- lee las entradas de su organizador y nada más. Ni precios, ni
-- recaudación, ni el correo y el teléfono que viven en `ordenes`.
--
-- El rol no es un `staff` con menos pantallas. Si lo fuera, el permiso
-- estaría en el frontend, y el frontend es el teléfono que queda sobre la
-- barra con la sesión abierta. Acá el corte es de la base: aunque alguien
-- abra la consola y pegue un `update`, no tiene con qué.
--
-- Marcar la entrada como usada tampoco es un permiso de escritura: llega
-- en 0032 como función `security definer`, y `entradas` sigue sin `update`
-- para `authenticated` (0012 se lo revocó). El portero puede leer y
-- llamar a la función; escribir la tabla a mano, no.
--
-- Idempotente: el `do` reemplaza el check si ya está, `create or replace`
-- la función, y `drop policy if exists` delante del `create policy`.
-- ============================================================

do $$
begin
  if exists (select 1 from pg_constraint where conname = 'perfiles_rol_check') then
    alter table perfiles drop constraint perfiles_rol_check;
  end if;
  alter table perfiles add constraint perfiles_rol_check
    check (rol in ('admin','staff','rrpp','portero'));
end $$;

create or replace function es_portero() returns boolean
  language sql stable security definer set search_path = public as $$
  select coalesce(mi_rol() = 'portero', false)
$$;
revoke execute on function es_portero() from anon, public;
grant execute on function es_portero() to authenticated;

comment on function es_portero() is
  'Quién está en la puerta. Compañera de puede_editar() (0012): las dos salen de mi_rol() y ninguna recibe el rol por parámetro.';

-- ── entradas: el portero lee las de su organizador ──────────
-- 0012 dejó esta policy con `puede_editar() or rrpp_id = auth.uid()`, que
-- para el portero da falso por los dos lados: no edita el catálogo y las
-- entradas no son suyas, son de quien las vendió. Sin este `or` el
-- escáner ve la base vacía y toda entrada buena le parece falsa.
--
-- Sigue nombrando puede_editar() y auth.uid(), así que el invariante 5 no
-- se mueve. Y sigue siendo `for select`: el portero lee, no escribe.
drop policy if exists "entradas leer" on entradas;
create policy "entradas leer" on entradas for select to authenticated
  using (organizador_id = mi_organizador()
         and (puede_editar() or es_portero() or rrpp_id = auth.uid()));

-- `ordenes` NO se toca a propósito. Su policy de lectura (0012) pide
-- `puede_editar() or rrpp_id = auth.uid()`, y el portero falla las dos:
-- es exactamente el resultado que se quiere. Ahí están el correo, el
-- teléfono y el total del comprador.
