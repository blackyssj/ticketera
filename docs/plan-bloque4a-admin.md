# Ticketera — Bloque 4a: acceso, eventos y entradas

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Que el organizador entre con usuario y clave, arme un evento con sus tipos y fases, y lo publique — sin que nadie escriba SQL.

**Architecture:** Página aparte en `app/admin/`, servida por el mismo proyecto de Vercel en `/admin/`. El staff está autenticado, así que **la guardia es RLS y el navegador habla directo con PostgREST**: cero Edge Functions en este bloque. La única regla que no puede vivir en una policy — "no publicar un evento sin fase ni precio" — va en una función `security definer`.

**Tech Stack:** HTML/CSS/JS planos sin build, `@supabase/supabase-js` por CDN, PostgREST, Postgres 17.

**Spec:** [docs/superpowers/specs/2026-08-28-ticketera-vistas-internas-design.md](../specs/2026-08-28-ticketera-vistas-internas-design.md)

## Global Constraints

- Proyecto Supabase `mjotxzcddhqqpuhkcetl`. Migraciones y SQL con `python3 scripts/sql.py`, que lee el PAT de `SUPABASE_PAT` o `~/.supabase_pat`.
- Toda tabla nueva lleva `organizador_id uuid not null references organizadores`.
- Ninguna función es ejecutable por `anon`: `revoke execute ... from anon, public` explícito, siempre.
- Cambiar la firma de una función es `drop function` con la firma vieja completa + `create`. Nunca `create or replace` agregando un parámetro.
- Toda función `security definer` lleva `set search_path = public`.
- Montos en `numeric(12,2)`.
- El login mapea `usuario` → `usuario@ticketera.local`, igual que Puerta.
- Los cuatro invariantes de `supabase/tests/invariantes.sql` tienen que quedar en verde al final de **cada** tarea.
- Repo `blackyssj/ticketera`, rama `main`. Un commit por tarea.

## Estructura de archivos

| Archivo | Responsabilidad |
|---|---|
| `supabase/migrations/0012_policies_por_rol.sql` | Cierra la escritura por rol. Hoy cualquier autenticado del tenant edita todo |
| `supabase/migrations/0013_publicar_evento.sql` | `publicar_evento()` y `listo_para_publicar()` |
| `supabase/tests/invariantes.sql` | Se le suma el invariante 5: nadie escribe sin rol |
| `scripts/crear-usuario.py` | Alta de la primera cuenta, por la Admin API |
| `app/admin/index.html` | Estructura de la app interna |
| `app/admin/admin.css` | Estilos, reusando los tokens de `styles.css` |
| `app/admin/admin.js` | Sesión, ruteo por pantalla y las tres pantallas |

`admin.js` va a crecer en 4b y 4c. Si pasa de ~800 líneas, se parte por pantalla antes de seguir.

---

### Task 1: Cerrar la escritura por rol

Hoy `for all to authenticated using (organizador_id = mi_organizador())` deja que **cualquier** usuario del tenant edite precios, cupos, mesas y órdenes. No es explotable todavía porque hay cero usuarios, pero este bloque crea los primeros.

**Files:**
- Create: `supabase/migrations/0012_policies_por_rol.sql`
- Modify: `supabase/tests/invariantes.sql`

**Interfaces:**
- Consumes: `mi_organizador()`, `mi_rol()`.
- Produces: `puede_editar() returns boolean` — verdadero solo para `admin` y `staff`. Las tareas siguientes la usan en toda policy de escritura.

- [ ] **Step 1: Escribir la prueba que demuestra el agujero**

`supabase/tests/policies.sql`:

```sql
-- Un rrpp NO puede tocar precios. Se prueba con la sesión simulada que usa
-- PostgREST: rol `authenticated` más el claim del usuario.
begin;

insert into organizadores (id, slug, nombre) values
  ('cccccccc-0000-4000-8000-000000000001', 'prueba-rol', 'Prueba');
insert into auth.users (id, email) values
  ('dddddddd-0000-4000-8000-000000000001', 'rrpp@ticketera.local');
insert into perfiles (id, organizador_id, nombre, rol) values
  ('dddddddd-0000-4000-8000-000000000001', 'cccccccc-0000-4000-8000-000000000001', 'Un Rrpp', 'rrpp');
insert into eventos (id, organizador_id, slug, nombre, fecha) values
  ('eeeeeeee-0000-4000-8000-000000000001', 'cccccccc-0000-4000-8000-000000000001',
   'prueba', 'Prueba', current_date + 10);
insert into tipo_entrada (id, organizador_id, evento_id, nombre) values
  ('ffffffff-0000-4000-8000-000000000001', 'cccccccc-0000-4000-8000-000000000001',
   'eeeeeeee-0000-4000-8000-000000000001', 'General');

do $$
declare v_n int;
begin
  set local role authenticated;
  perform set_config('request.jwt.claim.sub', 'dddddddd-0000-4000-8000-000000000001', true);

  begin
    update tipo_entrada set nombre = 'Hackeado'
     where id = 'ffffffff-0000-4000-8000-000000000001';
  exception when others then null;
  end;

  reset role;
  select count(*) into v_n from tipo_entrada
   where id = 'ffffffff-0000-4000-8000-000000000001' and nombre = 'Hackeado';
  if v_n > 0 then
    raise exception 'TEST_FAIL: un rrpp cambio el nombre de un tipo de entrada';
  end if;
  raise notice 'OK un rrpp no escribe el catalogo';
end $$;

rollback;
```

- [ ] **Step 2: Correrla y verla fallar**

Run: `python3 scripts/sql.py supabase/tests/policies.sql`
Expected: FALLA con `TEST_FAIL: un rrpp cambio el nombre de un tipo de entrada`. Ese fallo **es** el agujero: verlo antes de taparlo es lo que prueba que la policy nueva sirve.

- [ ] **Step 3: Escribir la migración**

`supabase/migrations/0012_policies_por_rol.sql`:

```sql
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
```

- [ ] **Step 4: Aplicar y ver la prueba pasar**

```bash
python3 scripts/sql.py supabase/migrations/0012_policies_por_rol.sql
python3 scripts/sql.py supabase/tests/policies.sql
python3 scripts/sql.py supabase/tests/invariantes.sql
```

Expected: `OK un rrpp no escribe el catalogo`, y los cuatro invariantes en verde.

- [ ] **Step 5: Agregar el invariante que impide la regresión**

Al final de `supabase/tests/invariantes.sql`:

```sql
do $$
declare v_malas text;
begin
  -- Toda policy que permita escribir tiene que nombrar a puede_editar() o a
  -- auth.uid(). Una que solo mire el tenant deja escribir a cualquier
  -- usuario del organizador, que es exactamente el agujero de 0012.
  select string_agg(tablename || '.' || policyname, ', ') into v_malas
  from pg_policies
  where schemaname = 'public'
    and cmd in ('ALL','INSERT','UPDATE','DELETE')
    and 'authenticated' = any(roles)
    and coalesce(qual, '') || coalesce(with_check, '') not like '%puede_editar%'
    and coalesce(qual, '') || coalesce(with_check, '') not like '%auth.uid()%';
  if v_malas is not null then
    raise exception 'TEST_FAIL: policies de escritura sin filtro de rol: %', v_malas;
  end if;
  raise notice 'OK invariante 5 - escribir pide rol';
end $$;
```

- [ ] **Step 6: Verlo fallar y volver a verde**

```bash
python3 scripts/sql.py <(echo "create policy \"mala\" on eventos for update to authenticated using (true);")
python3 scripts/sql.py supabase/tests/invariantes.sql   # debe FALLAR nombrando eventos.mala
python3 scripts/sql.py <(echo "drop policy \"mala\" on eventos;")
python3 scripts/sql.py supabase/tests/invariantes.sql   # verde
```

- [ ] **Step 7: Commit**

```bash
git add -A && git commit -m "fix: la escritura pide rol, no solo tenant"
git push origin main
```

---

### Task 2: Publicar con chequeo previo

**Files:**
- Create: `supabase/migrations/0013_publicar_evento.sql`
- Modify: `supabase/tests/policies.sql`

**Interfaces:**
- Consumes: `eventos`, `evento_fase`, `fase_precio`, `puede_editar()`.
- Produces: `listo_para_publicar(p_evento uuid) returns jsonb` → `{"ok":bool,"faltan":[texto,...]}`; `publicar_evento(p_evento uuid, p_publicar boolean) returns jsonb`.

- [ ] **Step 1: Escribir la prueba**

Antes del `rollback;` de `supabase/tests/policies.sql`:

```sql
do $$
declare v_ev uuid := 'eeeeeeee-0000-4000-8000-000000000001';
        v_tipo uuid := 'ffffffff-0000-4000-8000-000000000001';
        v_fase uuid; v_r jsonb;
begin
  -- sin fase ni precio: no se publica y dice qué falta
  v_r := listo_para_publicar(v_ev);
  if (v_r->>'ok')::boolean is not false then
    raise exception 'TEST_FAIL: dijo que estaba listo sin fase ni precio';
  end if;
  if jsonb_array_length(v_r->'faltan') < 2 then
    raise exception 'TEST_FAIL: deberia listar las dos cosas que faltan, dijo %', v_r->'faltan';
  end if;

  begin
    perform publicar_evento(v_ev, true);
    raise exception 'TEST_FAIL: publico un evento sin fase ni precio';
  exception when others then
    if sqlerrm not like 'NO_PUBLICABLE:%' then raise; end if;
  end;

  -- con fase abierta y precio: publica
  insert into evento_fase (id, organizador_id, evento_id, nombre, desde, hasta)
  values (gen_random_uuid(), 'cccccccc-0000-4000-8000-000000000001', v_ev, 'F1',
          now() - interval '1 hour', now() + interval '10 days')
  returning id into v_fase;
  insert into fase_precio (organizador_id, fase_id, tipo_id, precio, cupo)
  values ('cccccccc-0000-4000-8000-000000000001', v_fase, v_tipo, 100, 50);

  v_r := listo_para_publicar(v_ev);
  if (v_r->>'ok')::boolean is not true then
    raise exception 'TEST_FAIL: con fase y precio deberia estar listo: %', v_r;
  end if;

  perform publicar_evento(v_ev, true);
  if (select estado from eventos where id = v_ev) <> 'publicado' then
    raise exception 'TEST_FAIL: no quedo publicado';
  end if;

  -- despublicar siempre se puede: es la salida de emergencia
  perform publicar_evento(v_ev, false);
  if (select estado from eventos where id = v_ev) <> 'borrador' then
    raise exception 'TEST_FAIL: no volvio a borrador';
  end if;

  raise notice 'OK publicar exige fase abierta y precio';
end $$;
```

- [ ] **Step 2: Correrla y verla fallar**

Run: `python3 scripts/sql.py supabase/tests/policies.sql`
Expected: FALLA con `function listo_para_publicar(uuid) does not exist`.

- [ ] **Step 3: Escribir la migración**

`supabase/migrations/0013_publicar_evento.sql`:

```sql
-- ============================================================
-- 0013 — publicar
--
-- Un evento publicado sin fase abierta hace que la landing responda
-- SIN_FASE, y el organizador ve una página rota sin entender por qué. El
-- chequeo vive en la base y no en el botón: el botón es comodidad, la
-- función es la garantía.
--
-- Despublicar NO pide nada. Es la salida de emergencia cuando el evento
-- salió con un precio mal.
-- ============================================================

create function listo_para_publicar(p_evento uuid) returns jsonb
  language plpgsql stable security definer set search_path = public as $function$
declare v_faltan text[] := '{}'; v_org uuid; v_fase uuid;
begin
  select organizador_id into v_org from eventos where id = p_evento;
  if v_org is null then raise exception 'EVENTO_INEXISTENTE: %', p_evento; end if;
  if v_org <> mi_organizador() then raise exception 'Sin acceso a este evento'; end if;

  if not exists (select 1 from tipo_entrada
                  where evento_id = p_evento and activo) then
    v_faltan := v_faltan || 'Falta al menos un tipo de entrada';
  end if;

  v_fase := fase_vigente(p_evento);
  if v_fase is null then
    v_faltan := v_faltan || 'Ninguna fase está abierta en este momento';
  elsif not exists (select 1 from fase_precio where fase_id = v_fase) then
    v_faltan := v_faltan || 'La fase abierta no tiene ningún precio cargado';
  end if;

  return jsonb_build_object('ok', array_length(v_faltan, 1) is null,
                            'faltan', to_jsonb(v_faltan));
end $function$;
revoke execute on function listo_para_publicar(uuid) from anon, public;
grant execute on function listo_para_publicar(uuid) to authenticated;

create function publicar_evento(p_evento uuid, p_publicar boolean default true)
returns jsonb
  language plpgsql volatile security definer set search_path = public as $function$
declare v_org uuid; v_r jsonb;
begin
  if not puede_editar() then raise exception 'Sin permiso'; end if;
  select organizador_id into v_org from eventos where id = p_evento;
  if v_org is null then raise exception 'EVENTO_INEXISTENTE: %', p_evento; end if;
  if v_org <> mi_organizador() then raise exception 'Sin acceso a este evento'; end if;

  if not p_publicar then
    update eventos set estado = 'borrador' where id = p_evento;
    return jsonb_build_object('ok', true, 'estado', 'borrador');
  end if;

  v_r := listo_para_publicar(p_evento);
  if (v_r->>'ok')::boolean is not true then
    raise exception 'NO_PUBLICABLE: %', array_to_string(
      array(select jsonb_array_elements_text(v_r->'faltan')), ' · ');
  end if;

  update eventos set estado = 'publicado' where id = p_evento;
  return jsonb_build_object('ok', true, 'estado', 'publicado');
end $function$;
revoke execute on function publicar_evento(uuid, boolean) from anon, public;
grant execute on function publicar_evento(uuid, boolean) to authenticated;
```

- [ ] **Step 4: Aplicar y correr**

```bash
python3 scripts/sql.py supabase/migrations/0013_publicar_evento.sql
python3 scripts/sql.py supabase/tests/policies.sql
python3 scripts/sql.py supabase/tests/invariantes.sql
```

Expected: `OK publicar exige fase abierta y precio` y los cinco invariantes en verde.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat: publicar_evento() con chequeo previo"
git push origin main
```

---

### Task 3: La primera cuenta

Sin usuario no se puede entrar a nada, y la pantalla que los crea llega recién en 4c.

**Files:**
- Create: `scripts/crear-usuario.py`

**Interfaces:**
- Consumes: la Admin API de Supabase (`/auth/v1/admin/users`) con la service_role key.
- Produces: un usuario en `auth.users` y su fila en `perfiles`.

- [ ] **Step 1: Escribir el script**

`scripts/crear-usuario.py`:

```python
#!/usr/bin/env python3
"""Crea una cuenta del staff. El registro público está cerrado a propósito,
así que las cuentas se crean desde acá (o desde la pantalla de Equipo, que
llega en el bloque 4c).

    export SUPABASE_PAT=...
    python3 scripts/crear-usuario.py amstel jose "Jose Menacho" admin

El correo es sintético: <usuario>@ticketera.local. No se usa para nada más
que como identificador de Supabase — no hay recuperación por correo, y eso
fue una decisión, no un olvido.
"""
import json, os, pathlib, secrets, string, subprocess, sys

REF = os.environ.get("TICKETERA_REF", "mjotxzcddhqqpuhkcetl")
ROLES = ("admin", "staff", "rrpp", "portero")


def pat() -> str:
    if os.environ.get("SUPABASE_PAT"):
        return os.environ["SUPABASE_PAT"].strip()
    f = pathlib.Path.home() / ".supabase_pat"
    if f.exists():
        return f.read_text().strip()
    sys.exit("Falta el PAT. Exportá SUPABASE_PAT o dejalo en ~/.supabase_pat")


def curl(url, metodo="GET", cabeceras=None, cuerpo=None):
    args = ["curl", "-s", "-w", "\\n%{http_code}", "-X", metodo, url]
    for k, v in (cabeceras or {}).items():
        args += ["-H", f"{k}: {v}"]
    if cuerpo is not None:
        args += ["--data-binary", "@-"]
    p = subprocess.run(args, input=cuerpo, capture_output=True, text=True)
    body, _, code = p.stdout.rpartition("\\n")
    return code.strip(), body


def service_key(token: str) -> str:
    code, body = curl(f"https://api.supabase.com/v1/projects/{REF}/api-keys",
                      cabeceras={"Authorization": f"Bearer {token}"})
    if code not in ("200", "201"):
        sys.exit(f"No pude leer las api-keys: {body[:200]}")
    for k in json.loads(body):
        if k.get("name") == "service_role":
            return k["api_key"]
    sys.exit("No encontré la service_role key")


def main() -> int:
    if len(sys.argv) < 5:
        sys.exit("Uso: crear-usuario.py <organizador-slug> <usuario> <nombre> <rol>")
    org_slug, usuario, nombre, rol = sys.argv[1:5]
    if rol not in ROLES:
        sys.exit(f"Rol inválido. Alguno de: {', '.join(ROLES)}")

    token = pat()
    srv = service_key(token)
    base = f"https://{REF}.supabase.co"
    h = {"apikey": srv, "Authorization": f"Bearer {srv}",
         "Content-Type": "application/json"}

    code, body = curl(f"{base}/rest/v1/organizadores?slug=eq.{org_slug}&select=id",
                      cabeceras=h)
    filas = json.loads(body or "[]")
    if not filas:
        sys.exit(f"No existe el organizador '{org_slug}'")
    org_id = filas[0]["id"]

    alfabeto = string.ascii_letters + string.digits
    clave = "".join(secrets.choice(alfabeto) for _ in range(14))

    code, body = curl(f"{base}/auth/v1/admin/users", "POST", h, json.dumps({
        "email": f"{usuario}@ticketera.local",
        "password": clave,
        "email_confirm": True,
    }))
    if code not in ("200", "201"):
        sys.exit(f"No pude crear el usuario: {body[:300]}")
    uid = json.loads(body)["id"]

    code, body = curl(f"{base}/rest/v1/perfiles", "POST",
                      {**h, "Prefer": "return=representation"},
                      json.dumps({"id": uid, "organizador_id": org_id,
                                  "nombre": nombre, "rol": rol}))
    if code not in ("200", "201"):
        sys.exit(f"Usuario creado pero sin perfil: {body[:300]}")

    print(f"usuario:  {usuario}")
    print(f"clave:    {clave}")
    print(f"rol:      {rol}")
    print("Anotala ahora: no se puede recuperar, solo resetear.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 2: Crear la cuenta y verificarla**

```bash
python3 scripts/crear-usuario.py amstel jose "Jose Menacho" admin
python3 scripts/sql.py <(echo "select p.nombre, p.rol, o.slug, u.email from perfiles p join organizadores o on o.id = p.organizador_id join auth.users u on u.id = p.id;")
```

Expected: una fila con `Jose Menacho | admin | amstel | jose@ticketera.local`. Guardar la clave: no hay recuperación.

- [ ] **Step 3: Commit**

La clave **no** se commitea. Va al `.credenciales` local, que está en `.gitignore`.

```bash
git add scripts/crear-usuario.py && git commit -m "feat: alta de cuentas del staff por la Admin API"
git push origin main
```

---

### Task 4: Entrar

**Files:**
- Create: `app/admin/index.html`, `app/admin/admin.css`, `app/admin/admin.js`

**Interfaces:**
- Consumes: `window.CONFIG` de `../config.js`, `perfiles`, `mi_rol()`.
- Produces: `sb` (cliente de Supabase), `S.yo = {id, nombre, rol, organizador_id}`, y `mostrar(pantalla)` que las tareas siguientes usan para navegar.

- [ ] **Step 1: Escribir el HTML**

`app/admin/index.html`:

```html
<!doctype html>
<html lang="es-BO">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<title>Ticketera — administración</title>
<meta name="robots" content="noindex">
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link href="https://fonts.googleapis.com/css2?family=Big+Shoulders+Display:wght@600;700;800&family=Inter+Tight:wght@400;500;600&family=DM+Mono:wght@400;500&display=swap" rel="stylesheet">
<link rel="stylesheet" href="admin.css">
</head>
<body>

<section class="entrar" id="pantallaEntrar">
  <form class="caja" id="formEntrar">
    <h1>Ticketera</h1>
    <p class="sub">Administración</p>
    <label><span>Usuario</span>
      <input id="eUsuario" autocomplete="username" autocapitalize="none" required></label>
    <label><span>Clave</span>
      <input id="eClave" type="password" autocomplete="current-password" required></label>
    <button class="btn primario ancho" id="btnEntrar">Entrar</button>
    <p class="error" id="eError"></p>
  </form>
</section>

<div class="app" id="app" hidden>
  <header class="cab">
    <span class="marca">Ticketera</span>
    <nav class="tabs" id="tabs"></nav>
    <span class="yo" id="yo"></span>
    <button class="btn plano chico" id="btnSalir">Salir</button>
  </header>
  <main id="main"></main>
</div>

<div class="toast" id="toast" role="status" aria-live="polite"></div>

<script src="https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2/dist/umd/supabase.min.js"></script>
<script src="../config.js"></script>
<script src="admin.js"></script>
</body>
</html>
```

- [ ] **Step 2: Escribir `admin.css`**

Reusa los tokens de la landing para que las dos caras del producto se vean de
la misma familia, pero es una herramienta y no una vitrina: fondo claro, densidad
alta, cero animación decorativa.

```css
:root{
  --noche:#0B0A0A; --rojo:#DC0A2D; --rojo-claro:#F01236; --dorado:#E9B44C;
  --espuma:#F6F1E4; --tinta:#171310; --verde:#1E7A4C;
  --tinta-60:rgba(23,19,16,.60); --tinta-40:rgba(23,19,16,.40);
  --tinta-16:rgba(23,19,16,.16);
  --display:"Big Shoulders Display","Arial Narrow",system-ui,sans-serif;
  --texto:"Inter Tight",system-ui,-apple-system,sans-serif;
  --dato:"DM Mono",ui-monospace,Menlo,monospace;
}
*{box-sizing:border-box}
body{margin:0;background:var(--espuma);color:var(--tinta);font-family:var(--texto);font-size:15px;line-height:1.5}
h1,h2,h3{margin:0;font-family:var(--display);text-transform:uppercase;line-height:.95;letter-spacing:.01em}
button{font:inherit;color:inherit;background:none;border:0;cursor:pointer}
input{font:inherit}
:focus-visible{outline:2px solid var(--rojo);outline-offset:2px}
[hidden]{display:none !important}

/* entrar */
.entrar{min-height:100dvh;display:grid;place-items:center;background:var(--noche);padding:20px}
.caja{width:min(360px,100%);background:var(--espuma);border-radius:6px;padding:28px;display:flex;flex-direction:column;gap:14px}
.caja h1{font-size:34px}
.caja .sub{margin:-10px 0 6px;font-family:var(--dato);font-size:12px;letter-spacing:.14em;text-transform:uppercase;color:var(--tinta-40)}

/* estructura */
.cab{display:flex;align-items:center;gap:16px;padding:0 20px;height:56px;background:var(--noche);color:var(--espuma);position:sticky;top:0;z-index:10}
.marca{font-family:var(--display);font-size:19px;text-transform:uppercase;letter-spacing:.06em}
.tabs{display:flex;gap:2px}
.tabs button{padding:6px 13px;border-radius:3px;font-family:var(--dato);font-size:12px;letter-spacing:.05em;color:rgba(246,241,228,.58)}
.tabs button[aria-current]{background:var(--rojo);color:#fff}
.yo{margin-left:auto;font-family:var(--dato);font-size:12px;color:rgba(246,241,228,.58)}
main{max-width:1080px;margin:0 auto;padding:26px 20px 80px}
.cab-seccion{display:flex;align-items:center;gap:14px;margin-bottom:20px}
.cab-seccion h2{font-size:30px}
.cab-seccion .btn{margin-left:auto}
.cab-seccion .btn.chico{margin-left:0}

/* lista */
.lista{list-style:none;margin:0;padding:0;display:flex;flex-direction:column;gap:6px}
.fila{display:flex;align-items:center;gap:14px;padding:13px 16px;background:#fff;border:1.5px solid var(--tinta-16);border-radius:4px;cursor:pointer}
.fila:hover{border-color:var(--tinta)}
.fila-nombre{font-weight:600}
.fila-dato{font-family:var(--dato);font-size:12.5px;color:var(--tinta-60);margin-left:auto}
.fila-dato.tenue{color:var(--tinta-40);margin-left:0}
.pastilla{font-family:var(--dato);font-size:11px;padding:3px 9px;border-radius:999px;text-transform:uppercase;letter-spacing:.05em}
.pastilla.verde{background:var(--verde);color:#fff}
.pastilla.gris{background:var(--tinta-16);color:var(--tinta-60)}
.vacio,.cargando{font-family:var(--dato);font-size:13px;color:var(--tinta-40);padding:20px 0}

/* formularios */
.form-evento{display:grid;grid-template-columns:1fr 1fr;gap:14px;max-width:680px}
label{display:flex;flex-direction:column;gap:5px}
label span{font-family:var(--dato);font-size:11px;letter-spacing:.08em;text-transform:uppercase;color:var(--tinta-60)}
input{padding:10px 12px;border:1.5px solid var(--tinta-16);border-radius:3px;background:#fff}
input:focus{border-color:var(--tinta);outline:none}
.ayuda{font-family:var(--dato);font-size:11px;color:var(--tinta-40);font-style:normal}
.acciones{grid-column:1/-1;display:flex;gap:10px;flex-wrap:wrap;margin-top:6px}
.error{grid-column:1/-1;font-family:var(--dato);font-size:12px;color:var(--rojo);min-height:1em}

/* grilla de precios */
.grilla-envoltorio{overflow-x:auto;max-width:100%}
.grilla{border-collapse:collapse;background:#fff;min-width:100%}
.grilla th,.grilla td{border:1px solid var(--tinta-16);padding:9px 11px;text-align:left;vertical-align:top}
.grilla thead th{background:var(--tinta);color:var(--espuma);font-family:var(--display);font-size:16px;text-transform:uppercase;font-weight:700}
.grilla th em{display:block;font-family:var(--dato);font-size:10.5px;font-style:normal;font-weight:400;opacity:.7;text-transform:none;letter-spacing:0}
.grilla tbody th{font-family:var(--display);font-size:18px;text-transform:uppercase;background:#fff}
.grilla tbody th em{color:var(--tinta-40)}
.grilla td input{width:88px;padding:6px 8px;font-family:var(--dato);font-size:13px}
.celda-cupo{margin-top:5px;color:var(--tinta-60)}
.col-accion{width:1%;white-space:nowrap}

/* publicar */
.publicar{display:flex;align-items:center;gap:18px;margin-top:26px;padding:18px 20px;border:1.5px solid var(--tinta-16);border-radius:4px;background:#fff}
.publicar.vivo{border-color:var(--verde);background:rgba(30,122,76,.05)}
.publicar h3{font-size:20px}
.publicar p{margin:4px 0 0;font-size:13.5px;color:var(--tinta-60)}
.publicar .btn{margin-left:auto;flex:0 0 auto}
.faltan{margin:8px 0 0;padding-left:18px;font-size:13px;color:var(--rojo)}

/* botones y aviso */
.btn{padding:11px 18px;border-radius:3px;font-family:var(--display);font-size:17px;text-transform:uppercase;letter-spacing:.04em;transition:background .15s ease}
.btn.ancho{width:100%}
.btn.chico{font-size:13px;padding:7px 12px}
.btn.primario{background:var(--rojo);color:#fff}
.btn.primario:hover:not(:disabled){background:var(--rojo-claro)}
.btn.primario:disabled{background:var(--tinta-16);color:var(--tinta-40);cursor:not-allowed}
.btn.plano{border:1.5px solid var(--tinta-16);color:var(--tinta-60)}
.btn.plano:hover{border-color:var(--tinta);color:var(--tinta)}
.toast{position:fixed;left:50%;bottom:22px;transform:translate(-50%,150%);z-index:100;background:var(--noche);color:var(--espuma);padding:12px 17px;border-radius:3px;font-size:14px;box-shadow:0 10px 34px rgba(0,0,0,.3);transition:transform .28s cubic-bezier(.2,.9,.3,1.1)}
.toast[data-on="1"]{transform:translate(-50%,0)}

@media (max-width:720px){
  .form-evento{grid-template-columns:1fr}
  .fila{flex-wrap:wrap}
  .fila-dato{margin-left:0}
}
@media (prefers-reduced-motion:reduce){*{transition-duration:.001ms !important}}
```

- [ ] **Step 3: Escribir la sesión en `admin.js`**

```javascript
/* Administración de la ticketera.
   El staff está autenticado, así que la guardia es RLS: este archivo habla
   directo con PostgREST y NO valida permisos — los valida la base. Cualquier
   `if (rol === ...)` de acá es comodidad de interfaz, nunca seguridad. */
(() => {
"use strict";

const CFG = window.CONFIG;
const sb = window.supabase.createClient(CFG.SUPABASE_URL, CFG.SUPABASE_ANON_KEY);

const S = { yo: null, pantalla: "eventos", evento: null };
const $ = s => document.querySelector(s);
const esc = s => String(s ?? "").replace(/[&<>"']/g, c =>
  ({ "&":"&amp;", "<":"&lt;", ">":"&gt;", '"':"&quot;", "'":"&#39;" }[c]));

let tToast;
function avisar(txt) {
  const t = $("#toast");
  t.textContent = txt; t.dataset.on = "1";
  clearTimeout(tToast);
  tToast = setTimeout(() => t.dataset.on = "0", 4000);
}

/* El usuario no tiene correo: se le arma uno sintético, igual que en Puerta.
   Es un identificador, no una casilla — no hay recuperación por correo. */
const correoDe = u => `${u.trim().toLowerCase()}@ticketera.local`;

async function entrar(usuario, clave) {
  const { error } = await sb.auth.signInWithPassword(
    { email: correoDe(usuario), password: clave });
  if (error) throw new Error("Usuario o clave incorrectos.");
  await cargarPerfil();
}

async function cargarPerfil() {
  const { data: { user } } = await sb.auth.getUser();
  if (!user) return false;
  const { data, error } = await sb.from("perfiles")
    .select("id,nombre,rol,organizador_id,activo").eq("id", user.id).maybeSingle();
  if (error || !data || !data.activo) {
    await sb.auth.signOut();
    throw new Error("Tu cuenta no está habilitada.");
  }
  S.yo = data;
  return true;
}

$("#formEntrar").addEventListener("submit", async e => {
  e.preventDefault();
  $("#eError").textContent = "";
  $("#btnEntrar").disabled = true;
  try {
    await entrar($("#eUsuario").value, $("#eClave").value);
    arrancarApp();
  } catch (err) {
    $("#eError").textContent = err.message;
  } finally {
    $("#btnEntrar").disabled = false;
  }
});

$("#btnSalir").addEventListener("click", async () => {
  await sb.auth.signOut();
  location.reload();
});

/* El rol decide qué pestañas se ven. La base decide qué se puede hacer. */
const PANTALLAS = [
  { id: "eventos", txt: "Eventos", roles: ["admin", "staff"] },
];

function arrancarApp() {
  $("#pantallaEntrar").hidden = true;
  $("#app").hidden = false;
  $("#yo").textContent = `${S.yo.nombre} · ${S.yo.rol}`;
  const mias = PANTALLAS.filter(p => p.roles.includes(S.yo.rol));
  $("#tabs").innerHTML = mias.map(p =>
    `<button data-p="${p.id}"${p.id === S.pantalla ? ' aria-current="page"' : ""}>${esc(p.txt)}</button>`
  ).join("");
  if (!mias.some(p => p.id === S.pantalla) && mias.length) S.pantalla = mias[0].id;
  mostrar(S.pantalla);
}

$("#tabs").addEventListener("click", e => {
  const b = e.target.closest("button[data-p]");
  if (b) mostrar(b.dataset.p);
});

function mostrar(p) {
  S.pantalla = p;
  document.querySelectorAll("#tabs button").forEach(b =>
    b.toggleAttribute("aria-current", b.dataset.p === p));
  if (p === "eventos") return pantallaEventos();
  $("#main").innerHTML = "";
}

// las tareas 5 a 7 la reemplazan
async function pantallaEventos() { $("#main").innerHTML = "<p>…</p>"; }

/* ── arranque: si ya había sesión, entrar directo ── */
(async () => {
  try {
    if (await cargarPerfil()) arrancarApp();
  } catch { /* sesión vieja o cuenta deshabilitada: queda la pantalla de entrar */ }
})();

window.ADMIN = { S, sb, mostrar, avisar, esc };   // para las tareas siguientes
})();
```

- [ ] **Step 4: Verificar que entra**

```bash
python3 -m http.server 4174 --directory app &
```

Abrir `http://localhost:4174/admin/`, poner el usuario y la clave de la Tarea 3.
Expected: desaparece la pantalla de entrar, arriba a la derecha dice `Jose Menacho · admin`, y la consola no tiene errores.

Probar también la clave equivocada.
Expected: `Usuario o clave incorrectos.` y no entra.

- [ ] **Step 5: Verificar que la sesión sobrevive al refresco**

Recargar la página.
Expected: entra directo, sin volver a pedir la clave.

- [ ] **Step 6: Commit**

```bash
git add -A && git commit -m "feat: pantalla de acceso de la administración"
git push origin main
```

---

### Task 5: Lista de eventos

**Files:**
- Modify: `app/admin/admin.js`, `app/admin/admin.css`

**Interfaces:**
- Consumes: `window.ADMIN`, tabla `eventos`.
- Produces: `pantallaEventos()` completa y `abrirEvento(id)` que la Tarea 6 usa.

- [ ] **Step 1: Escribir la pantalla**

Reemplazar el `pantallaEventos()` provisorio. **Todo lo de esta tarea y de las
dos siguientes va DENTRO del mismo IIFE de `admin.js`**, antes de la línea
`window.ADMIN = ...`: las funciones usan `sb`, `S`, `$`, `esc` y `avisar`, que
son locales al closure y no existen fuera.

```javascript
const fmtF = f => new Date(f + "T00:00:00-04:00")
  .toLocaleDateString("es-BO", { day: "numeric", month: "short", year: "numeric" });
const bs = n => Number(n || 0).toLocaleString("es-BO") + " Bs";

const ESTADOS = {
  borrador:  { txt: "Borrador",  cls: "gris" },
  publicado: { txt: "A la venta", cls: "verde" },
  cerrado:   { txt: "Cerrado",   cls: "gris" },
};

async function pantallaEventos() {
  $("#main").innerHTML = `<p class="cargando">Cargando eventos…</p>`;
  const { data, error } = await sb.from("eventos")
    .select("id,slug,nombre,fecha,estado,lugar")
    .order("fecha", { ascending: false });
  if (error) { $("#main").innerHTML = `<p class="error">${esc(error.message)}</p>`; return; }

  $("#main").innerHTML = `
    <div class="cab-seccion">
      <h2>Eventos</h2>
      <button class="btn primario" id="btnNuevo">Nuevo evento</button>
    </div>
    ${data.length ? `<ul class="lista">${data.map(e => `
      <li class="fila" data-ev="${e.id}">
        <span class="fila-nombre">${esc(e.nombre)}</span>
        <span class="pastilla ${ESTADOS[e.estado].cls}">${ESTADOS[e.estado].txt}</span>
        <span class="fila-dato">${fmtF(e.fecha)}</span>
        <span class="fila-dato tenue">${esc(e.lugar || "")}</span>
      </li>`).join("")}</ul>`
      : `<p class="vacio">Todavía no hay eventos. Creá el primero.</p>`}`;

  $("#btnNuevo").onclick = () => abrirEvento(null);
  document.querySelectorAll("#main .fila").forEach(f =>
    f.onclick = () => abrirEvento(f.dataset.ev));
}

/* Alta y edición en el mismo formulario: son los mismos campos, y tener dos
   pantallas casi iguales garantiza que una se olvide de un campo. */
async function abrirEvento(id) {
  let e = { nombre: "", slug: "", lugar: "", fecha: "", hora_inicio: "21:00",
            edad_min: 18, tope_entradas_orden: 10, estado: "borrador" };
  if (id) {
    const { data } = await sb.from("eventos").select("*").eq("id", id).single();
    e = data;
  }
  $("#main").innerHTML = `
    <div class="cab-seccion">
      <button class="btn plano chico" id="btnVolver">← Eventos</button>
      <h2>${id ? esc(e.nombre) : "Nuevo evento"}</h2>
    </div>
    <form class="form-evento" id="formEvento">
      <label><span>Nombre</span><input id="fNombre" value="${esc(e.nombre)}" required></label>
      <label><span>Link público</span>
        <input id="fSlug" value="${esc(e.slug)}" pattern="[a-z0-9-]{2,60}" required>
        <em class="ayuda">/${esc(CFG.ORGANIZADOR)}/<b id="vistaSlug">${esc(e.slug || "…")}</b></em></label>
      <label><span>Lugar</span><input id="fLugar" value="${esc(e.lugar || "")}"></label>
      <label><span>Fecha</span><input id="fFecha" type="date" value="${e.fecha || ""}" required></label>
      <label><span>Hora</span><input id="fHora" type="time" value="${String(e.hora_inicio).slice(0,5)}"></label>
      <label><span>Edad mínima</span><input id="fEdad" type="number" min="0" max="99" value="${e.edad_min}"></label>
      <label><span>Máximo de entradas por compra</span>
        <input id="fTope" type="number" min="1" max="50" value="${e.tope_entradas_orden}"></label>
      <div class="acciones">
        <button class="btn primario" id="btnGuardar">Guardar</button>
        ${id ? `<button type="button" class="btn plano" id="btnEntradas">Entradas y precios →</button>` : ""}
      </div>
      <p class="error" id="fError"></p>
    </form>`;

  $("#btnVolver").onclick = () => mostrar("eventos");
  $("#fSlug").oninput = ev => $("#vistaSlug").textContent = ev.target.value || "…";
  if (id) $("#btnEntradas").onclick = () => pantallaEntradas(id);

  $("#formEvento").onsubmit = async ev => {
    ev.preventDefault();
    $("#fError").textContent = "";
    const fila = {
      organizador_id: S.yo.organizador_id,
      nombre: $("#fNombre").value.trim(),
      slug: $("#fSlug").value.trim().toLowerCase(),
      lugar: $("#fLugar").value.trim() || null,
      fecha: $("#fFecha").value,
      hora_inicio: $("#fHora").value || "21:00",
      edad_min: Number($("#fEdad").value),
      tope_entradas_orden: Number($("#fTope").value),
    };
    const q = id ? sb.from("eventos").update(fila).eq("id", id)
                 : sb.from("eventos").insert(fila).select("id").single();
    const { data, error } = await q;
    if (error) {
      // 23505 = unique_violation: el slug ya existe EN ESTE organizador
      $("#fError").textContent = error.code === "23505"
        ? "Ya tenés un evento con ese link. Elegí otro."
        : error.message;
      return;
    }
    avisar("Evento guardado.");
    id ? mostrar("eventos") : abrirEvento(data.id);
  };
}
```

- [ ] **Step 2: Verificar el alta**

Con la app abierta: **Nuevo evento** → nombre "Prueba Admin", link `prueba-admin`, fecha cualquiera → Guardar.
Expected: avisa "Evento guardado" y queda en la pantalla del evento, ahora con el botón "Entradas y precios".

```bash
python3 scripts/sql.py <(echo "select nombre, slug, estado from eventos order by created_at desc limit 1;")
```

Expected: la fila recién creada, en `borrador`.

- [ ] **Step 3: Verificar el slug repetido**

Crear otro evento con el mismo link `prueba-admin`.
Expected: `Ya tenés un evento con ese link. Elegí otro.` y no se crea nada.

- [ ] **Step 4: Commit**

```bash
git add -A && git commit -m "feat: lista y alta de eventos"
git push origin main
```

---

### Task 6: Entradas y precios en la grilla

La pantalla que más piensa. Precio y cupo viven en el cruce `fase × tipo`, no en la fase ni en el tipo.

**Files:**
- Modify: `app/admin/admin.js`, `app/admin/admin.css`

**Interfaces:**
- Consumes: `tipo_entrada`, `evento_fase`, `fase_precio`.
- Produces: `pantallaEntradas(eventoId)`.

- [ ] **Step 1: Escribir la pantalla**

```javascript
/* La grilla es fases × tipos porque el precio vive en el cruce. Con dos
   listas separadas el organizador no ve que "General" cuesta distinto en
   cada fase, y eso es justamente lo que está vendiendo. */
async function pantallaEntradas(eventoId) {
  $("#main").innerHTML = `<p class="cargando">Cargando…</p>`;

  const [ev, tipos, fases, precios] = await Promise.all([
    sb.from("eventos").select("id,nombre,estado").eq("id", eventoId).single(),
    sb.from("tipo_entrada").select("*").eq("evento_id", eventoId).order("orden"),
    sb.from("evento_fase").select("*").eq("evento_id", eventoId).order("orden"),
    sb.from("fase_precio").select("*"),
  ]);
  const T = tipos.data || [], F = fases.data || [];
  const idsFase = new Set(F.map(f => f.id));
  const P = new Map((precios.data || [])
    .filter(p => idsFase.has(p.fase_id))
    .map(p => [`${p.fase_id}|${p.tipo_id}`, p]));

  $("#main").innerHTML = `
    <div class="cab-seccion">
      <button class="btn plano chico" id="btnVolver">← ${esc(ev.data.nombre)}</button>
      <h2>Entradas y precios</h2>
    </div>
    <div class="grilla-envoltorio">
      <table class="grilla">
        <thead><tr><th>Tipo</th>
          ${F.map(f => `<th>${esc(f.nombre)}<em>${ventana(f)}</em></th>`).join("")}
          <th class="col-accion"><button class="btn plano chico" id="btnFase">+ Fase</button></th>
        </tr></thead>
        <tbody>
          ${T.map(t => `<tr data-tipo="${t.id}">
            <th>${esc(t.nombre)}<em>${esc(t.descripcion || "")}</em></th>
            ${F.map(f => {
              const p = P.get(`${f.id}|${t.id}`);
              return `<td>
                <input class="celda-precio" data-f="${f.id}" data-t="${t.id}"
                       type="number" min="0" step="1" placeholder="—"
                       value="${p ? Number(p.precio) : ""}" aria-label="Precio">
                <input class="celda-cupo" data-f="${f.id}" data-t="${t.id}"
                       type="number" min="1" placeholder="sin tope"
                       value="${p && p.cupo != null ? p.cupo : ""}" aria-label="Cupo">
              </td>`;
            }).join("")}
            <td class="col-accion"></td></tr>`).join("")}
        </tbody>
      </table>
    </div>
    <div class="acciones">
      <button class="btn plano" id="btnTipo">+ Tipo de entrada</button>
      <button class="btn primario" id="btnGuardarGrilla">Guardar precios</button>
    </div>
    <p class="ayuda">Precio vacío = ese tipo no se vende en esa fase. Cupo vacío = sin tope.</p>
    <div id="zonaPublicar"></div>`;

  $("#btnVolver").onclick = () => abrirEvento(eventoId);
  $("#btnTipo").onclick = () => nuevoTipo(eventoId);
  $("#btnFase").onclick = () => nuevaFase(eventoId);
  $("#btnGuardarGrilla").onclick = () => guardarGrilla(eventoId, P);
  zonaPublicar(eventoId, ev.data.estado);
}

function ventana(f) {
  const d = x => x ? new Date(x).toLocaleDateString("es-BO", { day: "numeric", month: "short" }) : "";
  if (!f.desde && !f.hasta) return "siempre";
  return `${d(f.desde)} → ${d(f.hasta) || "sin fin"}`;
}

async function guardarGrilla(eventoId, P) {
  const filas = [], borrar = [];
  document.querySelectorAll(".celda-precio").forEach(inp => {
    const f = inp.dataset.f, t = inp.dataset.t;
    const cupoInp = document.querySelector(`.celda-cupo[data-f="${f}"][data-t="${t}"]`);
    const precio = inp.value.trim();
    if (precio === "") { if (P.has(`${f}|${t}`)) borrar.push({ f, t }); return; }
    filas.push({ organizador_id: S.yo.organizador_id, fase_id: f, tipo_id: t,
                 precio: Number(precio),
                 cupo: cupoInp.value.trim() === "" ? null : Number(cupoInp.value) });
  });

  for (const b of borrar) {
    await sb.from("fase_precio").delete().eq("fase_id", b.f).eq("tipo_id", b.t);
  }
  if (filas.length) {
    const { error } = await sb.from("fase_precio")
      .upsert(filas, { onConflict: "fase_id,tipo_id" });
    if (error) { avisar("No se pudo guardar: " + error.message); return; }
  }
  avisar("Precios guardados.");
  pantallaEntradas(eventoId);
}

async function nuevoTipo(eventoId) {
  const nombre = prompt("Nombre del tipo de entrada (General, VIP, Palco…)");
  if (!nombre) return;
  const { error } = await sb.from("tipo_entrada").insert({
    organizador_id: S.yo.organizador_id, evento_id: eventoId,
    nombre: nombre.trim(), orden: Date.parse(new Date().toISOString()) % 1000 });
  if (error) {
    avisar(error.code === "23505" ? "Ya existe un tipo con ese nombre." : error.message);
    return;
  }
  pantallaEntradas(eventoId);
}

async function nuevaFase(eventoId) {
  const nombre = prompt("Nombre de la fase (Preventa 1, General…)");
  if (!nombre) return;
  const hasta = prompt("¿Hasta qué día vale? (AAAA-MM-DD, vacío = sin fin)");
  const { error } = await sb.from("evento_fase").insert({
    organizador_id: S.yo.organizador_id, evento_id: eventoId,
    nombre: nombre.trim(), desde: new Date().toISOString(),
    hasta: hasta ? `${hasta}T23:59:00-04:00` : null, orden: 0 });
  if (error) { avisar(error.message); return; }
  pantallaEntradas(eventoId);
}
```

- [ ] **Step 2: Verificar los dos ejes**

En el evento de prueba: crear el tipo "General", crear las fases "Preventa" (hasta dentro de 5 días) y "General" (sin fin). Poner 120 en Preventa y 150 en General. Guardar.

```bash
python3 scripts/sql.py <(echo "select f.nombre fase, t.nombre tipo, p.precio, p.cupo from fase_precio p join evento_fase f on f.id=p.fase_id join tipo_entrada t on t.id=p.tipo_id where f.evento_id=(select id from eventos where slug='prueba-admin') order by f.orden;")
```

Expected: dos filas, el mismo tipo con 120 y 150. Ese es el punto entero de la pantalla.

- [ ] **Step 3: Verificar que vaciar el precio borra el cruce**

Vaciar la celda de la fase "General" y guardar.
Expected: queda una sola fila en `fase_precio`. Un precio vacío significa "ese tipo no se vende en esa fase", y tiene que borrar de verdad — dejarlo en 0 lo pondría a la venta gratis.

- [ ] **Step 4: Commit**

```bash
git add -A && git commit -m "feat: grilla de fases x tipos con precio en el cruce"
git push origin main
```

---

### Task 7: Publicar

**Files:**
- Modify: `app/admin/admin.js`, `app/admin/admin.css`

**Interfaces:**
- Consumes: `listo_para_publicar(uuid)`, `publicar_evento(uuid, boolean)`.
- Produces: `zonaPublicar(eventoId, estado)`.

- [ ] **Step 1: Escribir la zona de publicación**

```javascript
/* El chequeo se muestra ANTES de que el organizador apriete, no como error
   después. Un botón que se puede apretar y siempre falla enseña a ignorar
   los mensajes. */
async function zonaPublicar(eventoId, estado) {
  const { data: chequeo } = await sb.rpc("listo_para_publicar", { p_evento: eventoId });
  const listo = chequeo && chequeo.ok;
  const faltan = (chequeo && chequeo.faltan) || [];
  const publicado = estado === "publicado";
  const url = `${location.origin}/${CFG.ORGANIZADOR}/`;

  $("#zonaPublicar").innerHTML = `
    <div class="publicar ${publicado ? "vivo" : ""}">
      <div>
        <h3>${publicado ? "A la venta" : "Sin publicar"}</h3>
        <p>${publicado
          ? `Cualquiera con el link puede comprar.`
          : listo
            ? "Está todo listo para ponerlo a la venta."
            : "Falta esto antes de poder publicarlo:"}</p>
        ${!publicado && !listo
          ? `<ul class="faltan">${faltan.map(f => `<li>${esc(f)}</li>`).join("")}</ul>` : ""}
      </div>
      <button class="btn ${publicado ? "plano" : "primario"}" id="btnPublicar"
        ${!publicado && !listo ? "disabled" : ""}>
        ${publicado ? "Quitar de la venta" : "Poner a la venta"}</button>
    </div>`;

  $("#btnPublicar").onclick = async () => {
    const { data, error } = await sb.rpc("publicar_evento",
      { p_evento: eventoId, p_publicar: !publicado });
    if (error) {
      avisar(error.message.replace(/^.*NO_PUBLICABLE:\s*/, "Falta: "));
      return;
    }
    avisar(data.estado === "publicado" ? "El evento está a la venta." : "Quitado de la venta.");
    pantallaEntradas(eventoId);
  };
}
```

- [ ] **Step 2: Verificar que no publica sin fase ni precio**

Crear un evento nuevo sin tipos ni fases y entrar a Entradas y precios.
Expected: el botón "Poner a la venta" aparece **deshabilitado** y debajo la lista: "Falta al menos un tipo de entrada" y "Ninguna fase está abierta en este momento".

- [ ] **Step 3: Verificar que publica y que la landing lo levanta**

En el evento de prueba, con su tipo, su fase abierta y su precio: apretar "Poner a la venta".

```bash
curl -s -X POST "https://mjotxzcddhqqpuhkcetl.supabase.co/functions/v1/evento" \
  -H "Authorization: Bearer $(cat /tmp/anon.txt)" -H "Content-Type: application/json" \
  -d '{"organizador":"amstel","evento":"prueba-admin"}' | head -c 200
```

Expected: `{"ok":true,...}` con el tipo y el precio cargados desde la pantalla. Esta es la prueba de que el bloque cumple su objetivo: un evento armado sin escribir una línea de SQL.

- [ ] **Step 4: Verificar que despublicar siempre se puede**

Apretar "Quitar de la venta".
Expected: vuelve a `borrador` sin pedir nada, y la función `evento` responde "El evento todavía no está a la venta". Es la salida de emergencia cuando algo salió con un precio mal.

- [ ] **Step 5: Limpiar el evento de prueba**

```bash
python3 scripts/sql.py <(echo "delete from eventos where slug='prueba-admin';")
```

- [ ] **Step 6: Desplegar y commitear**

```bash
cd app && npx vercel@latest deploy --prod
cd .. && git add -A && git commit -m "feat: publicar un evento con chequeo previo"
git push origin main
```

Verificar en `https://ticketera-coral.vercel.app/admin/` que se entra y que la lista de eventos carga.

---

## Lo que queda para los bloques siguientes

| Bloque | Qué construye |
|---|---|
| **4b** | Editor de planimetría: arrastrar, ajustar a grilla, deshacer, y el trigger que impide mover una mesa vendida |
| **4c** | Ventas en vivo, las órdenes en `revision_manual`, y la pantalla de Equipo con la Edge Function `crear-usuario` |
| **5** | Relacionador: `?r=<slug>`, atribución del lado del servidor, comisión fija por entrada |
| **6** | Puerta: rol `portero`, `validar_entrada`, modo filtro, descheckin y el escáner con `jsQR` |
| **7** | Pasarela real: `callback-pago`, el job del barrido y las credenciales del comercio 1518 |
