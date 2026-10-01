-- ============================================================
-- 0090 — los operadores de TICKETAZO pueden entrar como un cliente
--
-- Hasta acá un operador (plataforma_operador, 0069) veía la plata de cada
-- cliente en la pestaña Plataforma y nada más: no podía abrir un evento de
-- un cliente, ni crearle uno, ni cargarle el equipo. Para armarle algo a un
-- cliente había que pedirle su clave. El 30/09/2026 se cerró LÜMEN y los
-- dueños pidieron poder "setear todo" ellos.
--
-- Cómo funciona: el operador elige un cliente desde Plataforma y queda una
-- fila en `plataforma_contexto`. Mientras esa fila exista, mi_organizador()
-- devuelve el cliente elegido en vez del propio. Como TODA la seguridad del
-- panel (RLS, RPCs, storage) se apoya en mi_organizador(), todo el panel
-- pasa a funcionar como ese cliente sin tocar una sola policy más. El rol no
-- cambia: los operadores son admin de TICKETAZO y siguen siendo admin.
--
-- Lo que lo hace seguro:
--   · la fila sólo cuenta si el perfil sigue en plataforma_operador y
--     activo, y el cliente sigue activo. Una fila suelta —un operador al
--     que se dio de baja, un insert a mano— no le cambia el cliente a nadie;
--   · plataforma_contexto no tiene policies ni grants: se llega sólo por
--     plataforma_operar(), que exige es_plataforma();
--   · cada acción adentro ya queda con el actor_id del operador, como
--     cualquier otra; y cada entrada y salida queda en plataforma_ingreso.
-- ============================================================

create table if not exists plataforma_contexto (
  perfil_id      uuid primary key references perfiles(id) on delete cascade,
  organizador_id uuid not null references organizadores(id) on delete cascade,
  desde          timestamptz not null default clock_timestamp()
);
alter table plataforma_contexto enable row level security;
revoke all on plataforma_contexto from anon, authenticated;

comment on table plataforma_contexto is
  'El cliente que un operador de TICKETAZO está operando ahora. Una fila por operador. Sin policies: se escribe por plataforma_operar() y plataforma_dejar().';

create table if not exists plataforma_ingreso (
  id             uuid primary key default gen_random_uuid(),
  perfil_id      uuid not null references perfiles(id),
  organizador_id uuid not null references organizadores(id),
  entro_at       timestamptz not null default clock_timestamp(),
  salio_at       timestamptz
);
alter table plataforma_ingreso enable row level security;
revoke all on plataforma_ingreso from anon, authenticated;

comment on table plataforma_ingreso is
  'Quién de TICKETAZO entró como qué cliente y cuándo salió. Para la pregunta "¿quién tocó esto?" cuando la respuesta es alguien que no es del cliente.';

-- ── la regla única ──────────────────────────────────────────
-- Recibe el uid en vez de leer auth.uid() para que las Edge Functions, que
-- corren con service_role y saben quién llama por /auth/v1/user, puedan
-- preguntar lo mismo que pregunta la base. Por eso no se le da a
-- authenticated: con un uid de parámetro, cualquiera averiguaría el
-- cliente de cualquiera.
create or replace function organizador_efectivo(p_uid uuid) returns uuid
  language sql stable security definer set search_path = public as $$
  select coalesce(
    (select c.organizador_id
       from plataforma_contexto c
       join plataforma_operador po on po.perfil_id = c.perfil_id
       join perfiles p on p.id = c.perfil_id and p.activo
       join organizadores o on o.id = c.organizador_id and o.activo
      where c.perfil_id = p_uid),
    (select organizador_id from perfiles where id = p_uid and activo))
$$;
revoke execute on function organizador_efectivo(uuid) from anon, public, authenticated;
grant execute on function organizador_efectivo(uuid) to service_role;

create or replace function mi_organizador() returns uuid
  language sql stable security definer set search_path = public, auth as $$
  select organizador_efectivo(auth.uid())
$$;

-- ── cada uno ve su propia ficha ─────────────────────────────
-- Sin esto, un operador dentro de un cliente no podía leer su propio
-- perfil (es de TICKETAZO, no del cliente) y el panel lo echaba al entrar.
-- Ver la fila propia no le abre nada a nadie que no tuviera ya.
drop policy if exists "perfiles: el propio" on perfiles;
create policy "perfiles: el propio" on perfiles for select to authenticated
  using (id = auth.uid());

-- ── lo que el panel necesita saber ──────────────────────────
-- `id` para que el panel escriba con el cliente efectivo, y `operando`
-- para pintar la franja que avisa que no estás en tu cuenta.
create or replace function mi_organizador_config() returns jsonb
  language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
           'id',             o.id,
           'slug',           o.slug,
           'nombre',         o.nombre,
           'rrpp_ve_ventas', o.rrpp_ve_ventas,
           'comision_modo',  o.comision_modo,
           'muestra_cupo',   o.muestra_cupo,
           'operando',       o.id is distinct from
                               (select organizador_id from perfiles where id = auth.uid()))
    from organizadores o
   where o.id = mi_organizador() and auth.uid() is not null
$$;

-- ── entrar y salir ──────────────────────────────────────────
drop function if exists plataforma_operar(text);
create function plataforma_operar(p_slug text) returns jsonb
  language plpgsql volatile security definer set search_path = public as $$
declare o organizadores; v_propio uuid;
begin
  if not es_plataforma() then raise exception 'Sin permiso'; end if;
  select * into o from organizadores where slug = p_slug;
  if not found then
    return jsonb_build_object('ok', false, 'motivo', 'Ese cliente no existe.');
  end if;
  select organizador_id into v_propio from perfiles where id = auth.uid();
  -- El organizador de TICKETAZO está inactivo a propósito (no es un
  -- cliente), así que "es el propio" se pregunta ANTES que "está activo".
  if o.id is distinct from v_propio and not o.activo then
    return jsonb_build_object('ok', false, 'motivo', 'Ese cliente está dado de baja.');
  end if;

  -- Si ya estaba adentro de otro, esa visita se cierra acá.
  update plataforma_ingreso set salio_at = clock_timestamp()
   where perfil_id = auth.uid() and salio_at is null;

  -- Volver a TICKETAZO desde acá es lo mismo que salir.
  if o.id = v_propio then
    delete from plataforma_contexto where perfil_id = auth.uid();
    return jsonb_build_object('ok', true, 'slug', o.slug, 'nombre', o.nombre, 'operando', false);
  end if;

  insert into plataforma_contexto (perfil_id, organizador_id) values (auth.uid(), o.id)
  on conflict (perfil_id) do update
    set organizador_id = excluded.organizador_id, desde = clock_timestamp();
  insert into plataforma_ingreso (perfil_id, organizador_id) values (auth.uid(), o.id);

  return jsonb_build_object('ok', true, 'slug', o.slug, 'nombre', o.nombre, 'operando', true);
end $$;
revoke execute on function plataforma_operar(text) from anon, public;
grant execute on function plataforma_operar(text) to authenticated;

-- Salir no pide es_plataforma(): a un operador que dieron de baja con la
-- sesión abierta hay que poder sacarlo igual. Lo único que borra es la
-- fila propia.
drop function if exists plataforma_dejar();
create function plataforma_dejar() returns jsonb
  language plpgsql volatile security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Sin permiso'; end if;
  delete from plataforma_contexto where perfil_id = auth.uid();
  update plataforma_ingreso set salio_at = clock_timestamp()
   where perfil_id = auth.uid() and salio_at is null;
  return jsonb_build_object('ok', true);
end $$;
revoke execute on function plataforma_dejar() from anon, public;
grant execute on function plataforma_dejar() to authenticated;

select * from chequeo_funciones_sin_guardia();
