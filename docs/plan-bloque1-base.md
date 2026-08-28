# Ticketera — Bloque 1: base multi-tenant y órdenes

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Dejar en pie la base de datos de la ticketera — tenant, catálogo, órdenes con hold y emisión idempotente de entradas — con los invariantes que impiden repetir los errores de Plataforma Puerta.

**Architecture:** Proyecto Supabase nuevo. Postgres con RLS por `organizador_id` para el staff, y **cero permisos para `anon`** salvo `select` sobre tres vistas, que llegan en el Bloque 3. Toda escritura pública entrará por Edge Functions (Bloque 2), así que en este bloque las funciones de negocio son `security definer` y **no** se le otorgan a `anon`.

**Tech Stack:** Supabase (Postgres 15), migraciones SQL numeradas bajo `supabase/migrations/`, `psql` para las pruebas, `bash` para las de concurrencia.

**Spec:** [docs/superpowers/specs/2026-08-27-ticketera-design.md](../specs/2026-08-27-ticketera-design.md)

## Global Constraints

- Toda tabla de `public` excepto `organizadores` lleva `organizador_id uuid not null references organizadores`.
- Ninguna función es ejecutable por `anon`. `revoke execute ... from anon, public` explícito en cada una.
- Toda vista lleva `alter view … set (security_invoker = on)` en la **misma migración** en que se crea o se reemplaza.
- Cambiar la firma de una función es `drop function` con la firma vieja completa, después `create`. Nunca `create or replace` agregando un parámetro.
- Fee: `max(round(subtotal × fee_pct) + fee_fijo_transaccion, fee_piso)`. Defaults `0.07`, `3`, `5`.
- Hold público: **10 minutos** (`interval '10 minutes'`).
- Toda función `security definer` lleva `set search_path = public`.
- Los montos son `numeric(12,2)`. Nunca `float`.
- `/Users/jmenacho/Beeplay` **no es un repositorio git**. El Paso 0 de la Tarea 1 lo inicializa dentro de `ticketera/`.

## Estructura de archivos

| Archivo | Responsabilidad |
|---|---|
| `ticketera/supabase/migrations/0001_organizadores.sql` | Tabla raíz del tenant y sus parámetros de fee |
| `ticketera/supabase/migrations/0002_perfiles.sql` | Staff ↔ organizador, `mi_organizador()`, `mi_rol()` |
| `ticketera/supabase/migrations/0003_eventos.sql` | Eventos y su publicación |
| `ticketera/supabase/migrations/0004_catalogo.sql` | `tipo_entrada`, `evento_fase`, `fase_precio` |
| `ticketera/supabase/migrations/0005_mesas.sql` | Planimetría y estados de mesa |
| `ticketera/supabase/migrations/0006_ordenes.sql` | `ordenes`, `orden_items`, hold |
| `ticketera/supabase/migrations/0007_entradas.sql` | Entradas emitidas y su código |
| `ticketera/supabase/migrations/0008_crear_orden.sql` | `crear_orden()` con bloqueo de cupo y cálculo de fee |
| `ticketera/supabase/migrations/0009_emitir_orden.sql` | `emitir_orden()` idempotente |
| `ticketera/supabase/migrations/0010_vencer_ordenes.sql` | Barrido y `disponibilidad_tipo()` |
| `ticketera/supabase/tests/invariantes.sql` | Los cuatro guardas estructurales |
| `ticketera/supabase/tests/flujo.sql` | Pruebas de negocio, en transacción con rollback |
| `ticketera/supabase/tests/concurrencia.sh` | Carrera real con dos sesiones psql |
| `ticketera/README.md` | Cómo levantar la base y correr las pruebas |

Cada migración es autocontenida: crea sus tablas, sus policies, sus grants y sus `comment on`. No hay migración que "arregle" a otra dentro de este bloque.

---

### Task 1: Andamiaje y el invariante de tenancy

**Files:**
- Create: `ticketera/README.md`
- Create: `ticketera/supabase/migrations/0001_organizadores.sql`
- Test: `ticketera/supabase/tests/invariantes.sql`

**Interfaces:**
- Consumes: nada.
- Produces: tabla `organizadores(id uuid, slug text, nombre text, activo boolean, fee_pct numeric, fee_fijo_transaccion numeric, fee_piso numeric, comercio_id integer)`. El resto del plan la referencia como `organizadores(id)`.

- [ ] **Step 0: Inicializar el repositorio y la base local**

```bash
mkdir -p ticketera/supabase/migrations ticketera/supabase/tests
cd ticketera && git init && cd ..
```

Instalar la CLI si no está, y levantar Postgres local:

```bash
supabase init --workdir ticketera && supabase start --workdir ticketera
```

`supabase start` imprime la `DB URL`. Guardarla:

```bash
export TICKETERA_DB="postgresql://postgres:postgres@127.0.0.1:54322/postgres"
```

- [ ] **Step 1: Escribir el invariante de tenancy**

`ticketera/supabase/tests/invariantes.sql`:

```sql
-- Invariantes estructurales. Corren contra una base ya migrada.
-- Fallan con TEST_FAIL y no dejan nada escrito.

do $$
declare v_malas text;
begin
  select string_agg(t.tablename, ', ' order by t.tablename) into v_malas
  from pg_tables t
  where t.schemaname = 'public'
    and t.tablename <> 'organizadores'
    and not exists (
      select 1 from information_schema.columns c
      where c.table_schema = 'public'
        and c.table_name = t.tablename
        and c.column_name = 'organizador_id'
        and c.is_nullable = 'NO');
  if v_malas is not null then
    raise exception 'TEST_FAIL: tablas sin organizador_id not null: %', v_malas;
  end if;
  raise notice 'OK invariante 1 — tenancy';
end $$;
```

- [ ] **Step 2: Correrlo y verlo pasar en vacío**

Run: `psql "$TICKETERA_DB" -v ON_ERROR_STOP=1 -f ticketera/supabase/tests/invariantes.sql`
Expected: `NOTICE: OK invariante 1 — tenancy`. Con la base vacía no hay nada que violarlo; el paso siguiente prueba que el chequeo sirve.

- [ ] **Step 3: Probar que el invariante atrapa una violación**

```bash
psql "$TICKETERA_DB" -c "create table public.tabla_mala (id int);"
psql "$TICKETERA_DB" -v ON_ERROR_STOP=1 -f ticketera/supabase/tests/invariantes.sql
```

Expected: FALLA con `TEST_FAIL: tablas sin organizador_id not null: tabla_mala`. Un invariante que nunca se lo vio fallar no es un invariante.

Limpiar:

```bash
psql "$TICKETERA_DB" -c "drop table public.tabla_mala;"
```

- [ ] **Step 4: Escribir la migración de `organizadores`**

`ticketera/supabase/migrations/0001_organizadores.sql`:

```sql
-- ============================================================
-- 0001 — la raíz del tenant
--
-- Todo lo demás cuelga de acá. Los tres parámetros de fee viven en la fila
-- del organizador porque se negocian por cliente: un multi-tenant termina
-- necesitándolo igual, y tenerlos acá desde el día uno evita la migración
-- de "sacar la constante del código".
-- ============================================================

create table organizadores (
  id          uuid primary key default gen_random_uuid(),
  slug        text not null unique check (slug ~ '^[a-z0-9-]{2,40}$'),
  nombre      text not null,
  activo      boolean not null default true,

  fee_pct                 numeric(5,4)  not null default 0.0700 check (fee_pct >= 0 and fee_pct < 1),
  fee_fijo_transaccion    numeric(12,2) not null default 3.00   check (fee_fijo_transaccion >= 0),
  fee_piso                numeric(12,2) not null default 5.00   check (fee_piso >= 0),

  comercio_id integer,
  created_at  timestamptz not null default now()
);

comment on table organizadores is
  'Raíz del tenant. El slug va en la URL pública: /<slug>/<evento>.';
comment on column organizadores.comercio_id is
  'comercios.id en v2pro. 1518 es BeePlay Stage, el que se usa para probar.';

alter table organizadores enable row level security;

-- Sin policies todavía: hasta que exista `perfiles` (0002) nadie lee esto
-- salvo service_role, que no pasa por RLS. Es el default correcto.

revoke all on organizadores from anon, authenticated;
```

- [ ] **Step 5: Aplicar y verificar que el invariante sigue en verde**

```bash
psql "$TICKETERA_DB" -v ON_ERROR_STOP=1 -f ticketera/supabase/migrations/0001_organizadores.sql
psql "$TICKETERA_DB" -v ON_ERROR_STOP=1 -f ticketera/supabase/tests/invariantes.sql
```

Expected: `NOTICE: OK invariante 1 — tenancy`. `organizadores` está exceptuada a propósito: es la raíz.

- [ ] **Step 6: Escribir el README**

`ticketera/README.md`:

```markdown
# Ticketera

Base de datos de la ticketera multi-tenant. Diseño en
`docs/superpowers/specs/2026-08-27-ticketera-design.md`.

## Levantar

    supabase start
    export TICKETERA_DB="postgresql://postgres:postgres@127.0.0.1:54322/postgres"

## Migrar desde cero

    supabase db reset

## Correr las pruebas

    psql "$TICKETERA_DB" -v ON_ERROR_STOP=1 -f supabase/tests/invariantes.sql
    psql "$TICKETERA_DB" -v ON_ERROR_STOP=1 -f supabase/tests/flujo.sql
    bash supabase/tests/concurrencia.sh

Los invariantes corren contra la base migrada y no escriben nada. Las pruebas
de flujo escriben dentro de una transacción que termina en rollback.
```

- [ ] **Step 7: Commit**

```bash
cd ticketera && git add . && git commit -m "feat: organizadores y el invariante de tenancy"
```

---

### Task 2: Los tres invariantes de seguridad

**Files:**
- Modify: `ticketera/supabase/tests/invariantes.sql`

**Interfaces:**
- Consumes: `organizadores` de la Tarea 1.
- Produces: nada que el código consuma. Produce las tres guardas que el resto del plan tiene que seguir cumpliendo.

- [ ] **Step 1: Agregar el invariante de `security_invoker`**

Al final de `ticketera/supabase/tests/invariantes.sql`:

```sql
do $$
declare v_malas text;
begin
  select string_agg(c.relname, ', ' order by c.relname) into v_malas
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public' and c.relkind = 'v'
    and coalesce(array_to_string(c.reloptions, ','), '') not like '%security_invoker=on%';
  if v_malas is not null then
    raise exception 'TEST_FAIL: vistas sin security_invoker: %', v_malas;
  end if;
  raise notice 'OK invariante 2 — security_invoker';
end $$;
```

- [ ] **Step 2: Verlo fallar**

```bash
psql "$TICKETERA_DB" -c "create view public.vista_mala as select 1 as x;"
psql "$TICKETERA_DB" -v ON_ERROR_STOP=1 -f ticketera/supabase/tests/invariantes.sql
```

Expected: FALLA con `TEST_FAIL: vistas sin security_invoker: vista_mala`.

```bash
psql "$TICKETERA_DB" -c "drop view public.vista_mala;"
```

- [ ] **Step 3: Agregar el invariante de permisos de `anon`**

```sql
do $$
declare v_tab text; v_fun text;
begin
  select string_agg(distinct table_name, ', ') into v_tab
  from information_schema.role_table_grants
  where grantee = 'anon' and table_schema = 'public'
    and privilege_type in ('INSERT','UPDATE','DELETE','TRUNCATE');
  if v_tab is not null then
    raise exception 'TEST_FAIL: anon escribe en: %', v_tab;
  end if;

  select string_agg(p.proname, ', ' order by p.proname) into v_fun
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public'
    and has_function_privilege('anon', p.oid, 'execute');
  if v_fun is not null then
    raise exception 'TEST_FAIL: anon ejecuta: %', v_fun;
  end if;
  raise notice 'OK invariante 3 — anon no escribe ni ejecuta';
end $$;
```

- [ ] **Step 4: Verlo fallar**

```bash
psql "$TICKETERA_DB" -c "create function public.fn_mala() returns int language sql as \$\$ select 1 \$\$;"
psql "$TICKETERA_DB" -v ON_ERROR_STOP=1 -f ticketera/supabase/tests/invariantes.sql
```

Expected: FALLA con `TEST_FAIL: anon ejecuta: fn_mala`. Postgres le da `execute` a `public` por defecto, y `anon` lo hereda — por eso cada función del plan lleva su `revoke` explícito.

```bash
psql "$TICKETERA_DB" -c "drop function public.fn_mala();"
```

- [ ] **Step 5: Agregar el invariante de firmas duplicadas**

```sql
do $$
declare v_malas text;
begin
  select string_agg(proname || ' (' || n || ' firmas)', ', ') into v_malas
  from (select p.proname, count(*) as n
        from pg_proc p
        join pg_namespace ns on ns.oid = p.pronamespace
        where ns.nspname = 'public' and p.prokind = 'f'
        group by p.proname having count(*) > 1) d;
  if v_malas is not null then
    raise exception 'TEST_FAIL: funciones con firma duplicada: %', v_malas;
  end if;
  raise notice 'OK invariante 4 — una firma por función';
end $$;
```

Este es el que más caro salió en Puerta: dos firmas vivas hacen que PostgREST responda *could not choose a candidate function* y la función queda muerta sin que nada avise.

- [ ] **Step 6: Verlo fallar**

```bash
psql "$TICKETERA_DB" -c "create function public.dup(a int) returns int language sql as \$\$ select a \$\$;"
psql "$TICKETERA_DB" -c "create function public.dup(a int, b int) returns int language sql as \$\$ select a+b \$\$;"
psql "$TICKETERA_DB" -v ON_ERROR_STOP=1 -f ticketera/supabase/tests/invariantes.sql
```

Expected: FALLA con `TEST_FAIL: funciones con firma duplicada: dup (2 firmas)`.

```bash
psql "$TICKETERA_DB" -c "drop function public.dup(int); drop function public.dup(int,int);"
```

- [ ] **Step 7: Correr los cuatro en verde y commitear**

Run: `psql "$TICKETERA_DB" -v ON_ERROR_STOP=1 -f ticketera/supabase/tests/invariantes.sql`
Expected: cuatro `NOTICE: OK invariante …`, sin error.

```bash
cd ticketera && git add . && git commit -m "test: invariantes de security_invoker, permisos de anon y firmas duplicadas"
```

---

### Task 3: Staff — `perfiles`, `mi_organizador()` y RLS

**Files:**
- Create: `ticketera/supabase/migrations/0002_perfiles.sql`
- Test: `ticketera/supabase/tests/flujo.sql`

**Interfaces:**
- Consumes: `organizadores(id)`.
- Produces: `perfiles(id uuid, organizador_id uuid, nombre text, rol text)`; `mi_organizador() returns uuid`; `mi_rol() returns text`. Todas las policies posteriores usan `organizador_id = mi_organizador()`.

- [ ] **Step 1: Escribir la prueba de aislamiento entre tenants**

`ticketera/supabase/tests/flujo.sql`:

```sql
-- Pruebas de negocio. Escriben dentro de una transacción que termina en
-- rollback: la base queda como estaba.
begin;

-- ── dos organizadores y un perfil en cada uno ──
insert into organizadores (id, slug, nombre) values
  ('11111111-1111-1111-1111-111111111111', 'bowie',   'Bowie'),
  ('22222222-2222-2222-2222-222222222222', 'ferial',  'Ferial');

insert into auth.users (id, email) values
  ('aaaaaaaa-0000-0000-0000-000000000001', 'a@test.bo'),
  ('bbbbbbbb-0000-0000-0000-000000000002', 'b@test.bo');

insert into perfiles (id, organizador_id, nombre, rol) values
  ('aaaaaaaa-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'Ana',  'admin'),
  ('bbbbbbbb-0000-0000-0000-000000000002', '22222222-2222-2222-2222-222222222222', 'Beto', 'admin');

do $$
declare v uuid;
begin
  perform set_config('request.jwt.claim.sub', 'aaaaaaaa-0000-0000-0000-000000000001', true);
  select mi_organizador() into v;
  if v <> '11111111-1111-1111-1111-111111111111' then
    raise exception 'TEST_FAIL: mi_organizador() devolvio % para Ana', v;
  end if;

  perform set_config('request.jwt.claim.sub', 'bbbbbbbb-0000-0000-0000-000000000002', true);
  select mi_organizador() into v;
  if v <> '22222222-2222-2222-2222-222222222222' then
    raise exception 'TEST_FAIL: mi_organizador() devolvio % para Beto', v;
  end if;

  raise notice 'OK mi_organizador() resuelve el tenant de cada usuario';
end $$;

rollback;
```

- [ ] **Step 2: Correrla y verla fallar**

Run: `psql "$TICKETERA_DB" -v ON_ERROR_STOP=1 -f ticketera/supabase/tests/flujo.sql`
Expected: FALLA con `relation "perfiles" does not exist`.

- [ ] **Step 3: Escribir la migración**

`ticketera/supabase/migrations/0002_perfiles.sql`:

```sql
-- ============================================================
-- 0002 — el staff y la resolución del tenant
--
-- El organizador de un usuario sale de acá y NUNCA de un parámetro que
-- mande el cliente. Si viniera por parámetro, cualquier usuario autenticado
-- podría leer el tenant de al lado pasando otro uuid.
-- ============================================================

create table perfiles (
  id              uuid primary key references auth.users on delete cascade,
  organizador_id  uuid not null references organizadores on delete restrict,
  nombre          text not null,
  rol             text not null default 'staff' check (rol in ('admin','staff','rrpp')),
  activo          boolean not null default true,
  created_at      timestamptz not null default now()
);
create index perfiles_org_idx on perfiles (organizador_id);

comment on table perfiles is
  'Staff del organizador. La membresía es 1 a 1: un usuario pertenece a un tenant.';

create function mi_organizador() returns uuid
  language sql stable security definer set search_path = public, auth as $$
  select organizador_id from perfiles where id = auth.uid() and activo
$$;
revoke execute on function mi_organizador() from anon, public;
grant execute on function mi_organizador() to authenticated;

create function mi_rol() returns text
  language sql stable security definer set search_path = public, auth as $$
  select rol from perfiles where id = auth.uid() and activo
$$;
revoke execute on function mi_rol() from anon, public;
grant execute on function mi_rol() to authenticated;

alter table perfiles enable row level security;

create policy "perfiles: ver los de mi organizador" on perfiles
  for select to authenticated
  using (organizador_id = mi_organizador());

create policy "perfiles: el admin administra los suyos" on perfiles
  for all to authenticated
  using  (organizador_id = mi_organizador() and mi_rol() = 'admin')
  with check (organizador_id = mi_organizador() and mi_rol() = 'admin');

revoke all on perfiles from anon;
grant select, insert, update, delete on perfiles to authenticated;

-- organizadores: cada uno ve el suyo y nada más
create policy "organizadores: el mío" on organizadores
  for select to authenticated
  using (id = mi_organizador());
grant select on organizadores to authenticated;
```

- [ ] **Step 4: Aplicar y correr las pruebas**

```bash
psql "$TICKETERA_DB" -v ON_ERROR_STOP=1 -f ticketera/supabase/migrations/0002_perfiles.sql
psql "$TICKETERA_DB" -v ON_ERROR_STOP=1 -f ticketera/supabase/tests/flujo.sql
psql "$TICKETERA_DB" -v ON_ERROR_STOP=1 -f ticketera/supabase/tests/invariantes.sql
```

Expected: `NOTICE: OK mi_organizador() resuelve el tenant de cada usuario`, y los cuatro invariantes en verde. `perfiles` tiene `organizador_id not null`, así que el invariante 1 la acepta.

- [ ] **Step 5: Commit**

```bash
cd ticketera && git add . && git commit -m "feat: perfiles, mi_organizador() y RLS por tenant"
```

---

### Task 4: Eventos

**Files:**
- Create: `ticketera/supabase/migrations/0003_eventos.sql`
- Modify: `ticketera/supabase/tests/flujo.sql`

**Interfaces:**
- Consumes: `organizadores(id)`, `mi_organizador()`, `mi_rol()`.
- Produces: `eventos(id uuid, organizador_id uuid, slug text, nombre text, fecha date, hora_inicio time, edad_min int, estado text, tope_entradas_orden int)`. `estado in ('borrador','publicado','cerrado')`.

- [ ] **Step 1: Escribir la prueba de unicidad de slug por tenant**

Antes del `rollback;` de `ticketera/supabase/tests/flujo.sql`:

```sql
-- ── el mismo slug de evento puede existir en dos organizadores ──
insert into eventos (organizador_id, slug, nombre, fecha) values
  ('11111111-1111-1111-1111-111111111111', 'halloween', 'Halloween Bowie',  '2026-10-31'),
  ('22222222-2222-2222-2222-222222222222', 'halloween', 'Halloween Ferial', '2026-10-31');

do $$
declare v_n int;
begin
  select count(*) into v_n from eventos where slug = 'halloween';
  if v_n <> 2 then
    raise exception 'TEST_FAIL: se esperaban 2 eventos halloween, hay %', v_n;
  end if;

  begin
    insert into eventos (organizador_id, slug, nombre, fecha)
    values ('11111111-1111-1111-1111-111111111111', 'halloween', 'Repetido', '2026-11-01');
    raise exception 'TEST_FAIL: aceptó dos slugs iguales en el mismo organizador';
  exception when unique_violation then
    null;
  end;

  raise notice 'OK el slug de evento es único por organizador, no global';
end $$;
```

- [ ] **Step 2: Correrla y verla fallar**

Run: `psql "$TICKETERA_DB" -v ON_ERROR_STOP=1 -f ticketera/supabase/tests/flujo.sql`
Expected: FALLA con `relation "eventos" does not exist`.

- [ ] **Step 3: Escribir la migración**

`ticketera/supabase/migrations/0003_eventos.sql`:

```sql
-- ============================================================
-- 0003 — eventos
--
-- El slug es único POR ORGANIZADOR, no global: dos clientes distintos
-- pueden tener su propio 'halloween'. Por eso la URL pública lleva los dos
-- slugs, /<organizador>/<evento>.
-- ============================================================

create table eventos (
  id              uuid primary key default gen_random_uuid(),
  organizador_id  uuid not null references organizadores on delete restrict,
  slug            text not null check (slug ~ '^[a-z0-9-]{2,60}$'),
  nombre          text not null,
  descripcion     text,
  lugar           text,
  flyer_url       text,
  fecha           date not null,
  hora_inicio     time not null default '21:00',
  hora_fin        time not null default '06:00',
  edad_min        int  not null default 18,
  estado          text not null default 'borrador'
                    check (estado in ('borrador','publicado','cerrado')),
  tope_entradas_orden int not null default 10 check (tope_entradas_orden between 1 and 50),
  created_at      timestamptz not null default now(),
  unique (organizador_id, slug)
);
create index eventos_org_fecha_idx on eventos (organizador_id, fecha desc);

comment on column eventos.tope_entradas_orden is
  'Máximo de entradas que el público puede llevar en una sola orden. Freno de abuso.';

alter table eventos enable row level security;

create policy "eventos: los de mi organizador" on eventos
  for select to authenticated
  using (organizador_id = mi_organizador());

create policy "eventos: el admin los administra" on eventos
  for all to authenticated
  using  (organizador_id = mi_organizador() and mi_rol() = 'admin')
  with check (organizador_id = mi_organizador() and mi_rol() = 'admin');

revoke all on eventos from anon;
grant select, insert, update, delete on eventos to authenticated;
```

- [ ] **Step 4: Aplicar y correr**

```bash
psql "$TICKETERA_DB" -v ON_ERROR_STOP=1 -f ticketera/supabase/migrations/0003_eventos.sql
psql "$TICKETERA_DB" -v ON_ERROR_STOP=1 -f ticketera/supabase/tests/flujo.sql
```

Expected: `NOTICE: OK el slug de evento es único por organizador, no global`.

- [ ] **Step 5: Commit**

```bash
cd ticketera && git add . && git commit -m "feat: eventos con slug unico por organizador"
```

---

### Task 5: Catálogo — tipos, fases y el precio en el cruce

**Files:**
- Create: `ticketera/supabase/migrations/0004_catalogo.sql`
- Modify: `ticketera/supabase/tests/flujo.sql`

**Interfaces:**
- Consumes: `eventos(id)`, `organizadores(id)`.
- Produces: `tipo_entrada(id, organizador_id, evento_id, nombre, orden, activo)`; `evento_fase(id, organizador_id, evento_id, nombre, desde, hasta, orden, activo)`; `fase_precio(organizador_id, fase_id, tipo_id, precio, cupo)` con PK `(fase_id, tipo_id)`; `fase_vigente(p_evento uuid) returns uuid`.

- [ ] **Step 1: Escribir la prueba de los dos ejes**

Antes del `rollback;`:

```sql
-- ── precio por tipo Y por fase: el mismo tipo cuesta distinto en cada fase ──
do $$
declare v_ev uuid; v_gen uuid; v_vip uuid; v_f1 uuid; v_f2 uuid; v_precio numeric;
begin
  select id into v_ev from eventos
   where organizador_id = '11111111-1111-1111-1111-111111111111' and slug = 'halloween';

  insert into tipo_entrada (organizador_id, evento_id, nombre, orden)
  values ('11111111-1111-1111-1111-111111111111', v_ev, 'General', 1) returning id into v_gen;
  insert into tipo_entrada (organizador_id, evento_id, nombre, orden)
  values ('11111111-1111-1111-1111-111111111111', v_ev, 'VIP', 2) returning id into v_vip;

  insert into evento_fase (organizador_id, evento_id, nombre, desde, hasta, orden)
  values ('11111111-1111-1111-1111-111111111111', v_ev, 'Preventa',
          now() - interval '2 days', now() + interval '2 days', 1) returning id into v_f1;
  insert into evento_fase (organizador_id, evento_id, nombre, desde, hasta, orden)
  values ('11111111-1111-1111-1111-111111111111', v_ev, 'General',
          now() + interval '2 days', now() + interval '20 days', 2) returning id into v_f2;

  insert into fase_precio (organizador_id, fase_id, tipo_id, precio, cupo) values
    ('11111111-1111-1111-1111-111111111111', v_f1, v_gen, 120, 100),
    ('11111111-1111-1111-1111-111111111111', v_f1, v_vip, 250, 20),
    ('11111111-1111-1111-1111-111111111111', v_f2, v_gen, 150, 200),
    ('11111111-1111-1111-1111-111111111111', v_f2, v_vip, 290, 20);

  if fase_vigente(v_ev) <> v_f1 then
    raise exception 'TEST_FAIL: la fase vigente deberia ser Preventa';
  end if;

  select precio into v_precio from fase_precio where fase_id = fase_vigente(v_ev) and tipo_id = v_gen;
  if v_precio <> 120 then
    raise exception 'TEST_FAIL: General en Preventa deberia costar 120, cuesta %', v_precio;
  end if;

  select precio into v_precio from fase_precio where fase_id = v_f2 and tipo_id = v_gen;
  if v_precio <> 150 then
    raise exception 'TEST_FAIL: General en fase General deberia costar 150, cuesta %', v_precio;
  end if;

  raise notice 'OK precio y cupo viven en el cruce fase x tipo';
end $$;
```

- [ ] **Step 2: Correrla y verla fallar**

Run: `psql "$TICKETERA_DB" -v ON_ERROR_STOP=1 -f ticketera/supabase/tests/flujo.sql`
Expected: FALLA con `relation "tipo_entrada" does not exist`.

- [ ] **Step 3: Escribir la migración**

`ticketera/supabase/migrations/0004_catalogo.sql`:

```sql
-- ============================================================
-- 0004 — catálogo: dos ejes de precio
--
-- `evento_fase` es la ventana temporal, `tipo_entrada` la categoría.
-- Precio y cupo NO viven en ninguna de las dos: viven en el cruce. En
-- Plataforma Puerta el precio está en la fase porque hay un solo tipo de
-- entrada; con dos tipos ahí ya no entra.
-- ============================================================

create table tipo_entrada (
  id              uuid primary key default gen_random_uuid(),
  organizador_id  uuid not null references organizadores on delete restrict,
  evento_id       uuid not null references eventos on delete cascade,
  nombre          text not null,
  descripcion     text,
  manillas        int  not null default 1 check (manillas >= 1),
  orden           int  not null default 0,
  activo          boolean not null default true,
  unique (evento_id, nombre)
);
create index tipo_entrada_ev_idx on tipo_entrada (evento_id, orden);

comment on column tipo_entrada.manillas is
  'Cuántas entradas emite una unidad de este tipo. Casi siempre 1; un pack de 2x1 sería 2.';

create table evento_fase (
  id              uuid primary key default gen_random_uuid(),
  organizador_id  uuid not null references organizadores on delete restrict,
  evento_id       uuid not null references eventos on delete cascade,
  nombre          text not null,
  desde           timestamptz,
  hasta           timestamptz,
  arte_url        text,
  orden           int not null default 0,
  activo          boolean not null default true,
  check (desde is null or hasta is null or desde < hasta)
);
create index evento_fase_ev_idx on evento_fase (evento_id, orden);

create table fase_precio (
  organizador_id  uuid not null references organizadores on delete restrict,
  fase_id         uuid not null references evento_fase on delete cascade,
  tipo_id         uuid not null references tipo_entrada on delete cascade,
  precio          numeric(12,2) not null check (precio >= 0),
  cupo            int check (cupo is null or cupo > 0),
  primary key (fase_id, tipo_id)
);
create index fase_precio_tipo_idx on fase_precio (tipo_id);

comment on column fase_precio.cupo is
  'null = sin tope; la fase corta por fecha. Un número = stock de ese tipo en esa fase.';

-- La fase abierta ahora. Si hay solapadas gana la de menor `orden`.
create function fase_vigente(p_evento uuid) returns uuid
  language sql stable security definer set search_path = public as $$
  select f.id from evento_fase f
   where f.evento_id = p_evento
     and f.activo
     and (f.desde is null or f.desde <= now())
     and (f.hasta is null or f.hasta >  now())
   order by f.orden
   limit 1
$$;
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
```

- [ ] **Step 4: Aplicar y correr**

```bash
psql "$TICKETERA_DB" -v ON_ERROR_STOP=1 -f ticketera/supabase/migrations/0004_catalogo.sql
psql "$TICKETERA_DB" -v ON_ERROR_STOP=1 -f ticketera/supabase/tests/flujo.sql
psql "$TICKETERA_DB" -v ON_ERROR_STOP=1 -f ticketera/supabase/tests/invariantes.sql
```

Expected: `NOTICE: OK precio y cupo viven en el cruce fase x tipo`, invariantes en verde.

- [ ] **Step 5: Commit**

```bash
cd ticketera && git add . && git commit -m "feat: tipos de entrada, fases y precio en el cruce"
```

---

### Task 6: Mesas con el estado `bloqueada`

**Files:**
- Create: `ticketera/supabase/migrations/0005_mesas.sql`
- Modify: `ticketera/supabase/tests/flujo.sql`

**Interfaces:**
- Consumes: `eventos(id)`, `organizadores(id)`.
- Produces: `mesas(id, organizador_id, evento_id, planta, etiqueta, categoria, x, y, w, precio, manillas, estado, orden_id)`. `estado in ('disponible','bloqueada','reservada','pagada','ocupada')`.

- [ ] **Step 1: Escribir la prueba del `update` condicional**

Antes del `rollback;`:

```sql
-- ── el update condicional ES la exclusión: la segunda toma devuelve 0 filas ──
do $$
declare v_ev uuid; v_mesa uuid; v_n int;
begin
  select id into v_ev from eventos
   where organizador_id = '11111111-1111-1111-1111-111111111111' and slug = 'halloween';

  insert into mesas (organizador_id, evento_id, planta, etiqueta, categoria, x, y, w, precio, manillas)
  values ('11111111-1111-1111-1111-111111111111', v_ev, 'baja', 'M1', 'mesa', 16, 26, 7.4, 1200, 8)
  returning id into v_mesa;

  update mesas set estado = 'bloqueada' where id = v_mesa and estado = 'disponible';
  get diagnostics v_n = row_count;
  if v_n <> 1 then raise exception 'TEST_FAIL: la primera toma deberia agarrar 1 fila, agarro %', v_n; end if;

  update mesas set estado = 'bloqueada' where id = v_mesa and estado = 'disponible';
  get diagnostics v_n = row_count;
  if v_n <> 0 then raise exception 'TEST_FAIL: la segunda toma agarro % filas, deberia agarrar 0', v_n; end if;

  raise notice 'OK una mesa tomada no se puede volver a tomar';
end $$;
```

- [ ] **Step 2: Correrla y verla fallar**

Run: `psql "$TICKETERA_DB" -v ON_ERROR_STOP=1 -f ticketera/supabase/tests/flujo.sql`
Expected: FALLA con `relation "mesas" does not exist`.

- [ ] **Step 3: Escribir la migración**

`ticketera/supabase/migrations/0005_mesas.sql`:

```sql
-- ============================================================
-- 0005 — planimetría
--
-- `bloqueada` es un estado NUEVO, separado de `reservada`: el organizador
-- tiene que poder distinguir "un desconocido de la web está pagando ahora
-- mismo" de "el relacionador la comprometió con un cliente". Si fueran el
-- mismo estado, el tablero mentiría.
--
-- x/y/w son porcentajes del lienzo, no píxeles: el plano escala solo.
-- ============================================================

create table mesas (
  id              uuid primary key default gen_random_uuid(),
  organizador_id  uuid not null references organizadores on delete restrict,
  evento_id       uuid not null references eventos on delete cascade,
  planta          text not null default 'baja',
  etiqueta        text not null,
  categoria       text not null default 'mesa' check (categoria in ('mesa','lounge','palco')),
  x               numeric(6,3) not null check (x between 0 and 100),
  y               numeric(6,3) not null check (y between 0 and 100),
  w               numeric(6,3) not null check (w > 0 and w <= 100),
  precio          numeric(12,2) not null check (precio >= 0),
  manillas        int not null default 1 check (manillas >= 1),
  estado          text not null default 'disponible'
                    check (estado in ('disponible','bloqueada','reservada','pagada','ocupada')),
  orden_id        uuid,     -- FK agregada en 0006, cuando `ordenes` exista
  updated_at      timestamptz not null default now(),
  unique (evento_id, etiqueta)
);
create index mesas_evento_idx on mesas (evento_id, planta);
create index mesas_orden_idx  on mesas (orden_id) where orden_id is not null;

comment on column mesas.manillas is
  'Cuántas entradas emite esta mesa. La puerta escanea personas, no muebles.';
comment on column mesas.estado is
  'bloqueada = hay una orden pública pendiente. reservada = la comprometió el staff.';

alter table mesas enable row level security;
create policy "mesas: las mías" on mesas for all to authenticated
  using (organizador_id = mi_organizador()) with check (organizador_id = mi_organizador());

revoke all on mesas from anon;
grant select, insert, update, delete on mesas to authenticated;
```

- [ ] **Step 4: Aplicar y correr**

```bash
psql "$TICKETERA_DB" -v ON_ERROR_STOP=1 -f ticketera/supabase/migrations/0005_mesas.sql
psql "$TICKETERA_DB" -v ON_ERROR_STOP=1 -f ticketera/supabase/tests/flujo.sql
```

Expected: `NOTICE: OK una mesa tomada no se puede volver a tomar`.

- [ ] **Step 5: Commit**

```bash
cd ticketera && git add . && git commit -m "feat: mesas con estado bloqueada separado de reservada"
```

---

### Task 7: Órdenes y sus ítems

**Files:**
- Create: `ticketera/supabase/migrations/0006_ordenes.sql`
- Modify: `ticketera/supabase/tests/flujo.sql`

**Interfaces:**
- Consumes: `eventos(id)`, `mesas(id)`, `tipo_entrada(id)`, `evento_fase(id)`.
- Produces: `ordenes(id, organizador_id, evento_id, estado, client_key, expira_at, comprador_nombre, comprador_email, comprador_telefono, subtotal, fee, total, pago_ref, rrpp_id, ip_hash, created_at)` con `estado in ('pendiente','pagada','vencida','anulada','revision_manual')`; `orden_items(id, organizador_id, orden_id, tipo_id, fase_id, mesa_id, cantidad, precio_unitario)`.

- [ ] **Step 1: Escribir la prueba del ítem exclusivo y de la `client_key`**

Antes del `rollback;`:

```sql
-- ── un ítem es de entrada O de mesa, y la client_key no se repite ──
do $$
declare v_ev uuid; v_ord uuid; v_tipo uuid; v_key uuid := gen_random_uuid();
begin
  select id into v_ev from eventos
   where organizador_id = '11111111-1111-1111-1111-111111111111' and slug = 'halloween';
  select id into v_tipo from tipo_entrada where evento_id = v_ev and nombre = 'General';

  insert into ordenes (organizador_id, evento_id, client_key, expira_at, subtotal, fee, total)
  values ('11111111-1111-1111-1111-111111111111', v_ev, v_key,
          now() + interval '10 minutes', 120, 11, 131)
  returning id into v_ord;

  begin
    insert into ordenes (organizador_id, evento_id, client_key, expira_at, subtotal, fee, total)
    values ('11111111-1111-1111-1111-111111111111', v_ev, v_key,
            now() + interval '10 minutes', 120, 11, 131);
    raise exception 'TEST_FAIL: acepto dos ordenes con la misma client_key';
  exception when unique_violation then null;
  end;

  begin
    insert into orden_items (organizador_id, orden_id, tipo_id, mesa_id, cantidad, precio_unitario)
    values ('11111111-1111-1111-1111-111111111111', v_ord, v_tipo,
            (select id from mesas where evento_id = v_ev limit 1), 1, 120);
    raise exception 'TEST_FAIL: acepto un item que es entrada Y mesa a la vez';
  exception when check_violation then null;
  end;

  raise notice 'OK client_key unica y item exclusivo entrada/mesa';
end $$;
```

- [ ] **Step 2: Correrla y verla fallar**

Run: `psql "$TICKETERA_DB" -v ON_ERROR_STOP=1 -f ticketera/supabase/tests/flujo.sql`
Expected: FALLA con `relation "ordenes" does not exist`.

- [ ] **Step 3: Escribir la migración**

`ticketera/supabase/migrations/0006_ordenes.sql`:

```sql
-- ============================================================
-- 0006 — la orden: la columna vertebral que Puerta no tiene
--
-- En Puerta cuatro entradas de una misma venta son cuatro filas sueltas.
-- Sin una orden no hay dónde colgar el hold, ni la client_key, ni el
-- reintento del callback de la pasarela.
--
-- Los montos se CONGELAN al crear la orden. Si el organizador cambia el
-- precio mientras alguien está pagando, esa persona paga lo que vio.
-- ============================================================

create table ordenes (
  id                 uuid primary key default gen_random_uuid(),
  organizador_id     uuid not null references organizadores on delete restrict,
  evento_id          uuid not null references eventos on delete restrict,

  estado             text not null default 'pendiente'
                       check (estado in ('pendiente','pagada','vencida','anulada','revision_manual')),
  client_key         uuid,
  expira_at          timestamptz not null,

  comprador_nombre   text,
  comprador_email    text,
  comprador_telefono text,

  subtotal           numeric(12,2) not null check (subtotal >= 0),
  fee                numeric(12,2) not null check (fee >= 0),
  total              numeric(12,2) not null check (total >= 0),

  pago_ref           text,
  rrpp_id            uuid references perfiles(id),
  ip_hash            text,

  created_at         timestamptz not null default now(),
  pagada_at          timestamptz,
  check (total = subtotal + fee)
);

-- Idempotencia: el mismo patrón que bar_ventas en Puerta (migracion-v5.5).
-- Índice PARCIAL porque client_key es nullable — las órdenes que crea el
-- staff a mano no traen una.
create unique index ordenes_client_key_uq on ordenes (client_key) where client_key is not null;
create index ordenes_evento_idx   on ordenes (evento_id, estado);
create index ordenes_pendientes_idx on ordenes (evento_id, expira_at) where estado = 'pendiente';
create index ordenes_pago_ref_idx  on ordenes (pago_ref) where pago_ref is not null;

comment on column ordenes.expira_at is
  'Fin del hold. La disponibilidad filtra por expira_at > now(), así que una
   orden vencida deja de retener stock aunque el barrido no haya corrido.';
comment on column ordenes.client_key is
  'Idempotencia del checkout. Reintentar con la misma clave devuelve la orden original.';

create table orden_items (
  id              uuid primary key default gen_random_uuid(),
  organizador_id  uuid not null references organizadores on delete restrict,
  orden_id        uuid not null references ordenes on delete cascade,
  tipo_id         uuid references tipo_entrada on delete restrict,
  fase_id         uuid references evento_fase  on delete restrict,
  mesa_id         uuid references mesas        on delete restrict,
  cantidad        int  not null check (cantidad > 0),
  precio_unitario numeric(12,2) not null check (precio_unitario >= 0),
  -- un ítem es de entrada O de mesa, nunca las dos ni ninguna
  constraint orden_items_exclusivo
    check ((tipo_id is not null) <> (mesa_id is not null)),
  -- si es de entrada, tiene que decir de qué fase salió: sin eso no se
  -- puede contar el stock de la fase
  constraint orden_items_fase_si_entrada
    check (tipo_id is null or fase_id is not null),
  -- una mesa se lleva de a una
  constraint orden_items_mesa_unitaria
    check (mesa_id is null or cantidad = 1)
);
create index orden_items_orden_idx on orden_items (orden_id);
create index orden_items_tipo_idx  on orden_items (tipo_id, fase_id) where tipo_id is not null;
create unique index orden_items_mesa_uq on orden_items (mesa_id) where mesa_id is not null;

-- Ahora que `ordenes` existe, cerrar la FK que 0005 dejó abierta.
alter table mesas
  add constraint mesas_orden_fk foreign key (orden_id) references ordenes on delete set null;

alter table ordenes     enable row level security;
alter table orden_items enable row level security;

create policy "ordenes: las de mi organizador" on ordenes for all to authenticated
  using (organizador_id = mi_organizador()) with check (organizador_id = mi_organizador());
create policy "items: los de mi organizador" on orden_items for all to authenticated
  using (organizador_id = mi_organizador()) with check (organizador_id = mi_organizador());

-- El público NO toca esto ni por vista: la página /orden/<uuid> la sirve una
-- Edge Function. Una vista podría perder security_invoker en un `create or
-- replace` y exponer todas las compras del sistema; una función no.
revoke all on ordenes, orden_items from anon;
grant select, insert, update on ordenes, orden_items to authenticated;
```

- [ ] **Step 4: Aplicar y correr**

```bash
psql "$TICKETERA_DB" -v ON_ERROR_STOP=1 -f ticketera/supabase/migrations/0006_ordenes.sql
psql "$TICKETERA_DB" -v ON_ERROR_STOP=1 -f ticketera/supabase/tests/flujo.sql
psql "$TICKETERA_DB" -v ON_ERROR_STOP=1 -f ticketera/supabase/tests/invariantes.sql
```

Expected: `NOTICE: OK client_key unica y item exclusivo entrada/mesa`, invariantes en verde.

- [ ] **Step 5: Commit**

```bash
cd ticketera && git add . && git commit -m "feat: ordenes con hold, client_key unica e items exclusivos"
```

---

### Task 8: Entradas emitidas

**Files:**
- Create: `ticketera/supabase/migrations/0007_entradas.sql`
- Modify: `ticketera/supabase/tests/flujo.sql`

**Interfaces:**
- Consumes: `eventos(id)`, `ordenes(id)`, `tipo_entrada(id)`, `evento_fase(id)`, `mesas(id)`, `perfiles(id)`.
- Produces: `entradas(id, organizador_id, evento_id, orden_id, code, canal, tipo_id, fase_id, mesa_id, rrpp_id, precio, estado, created_at, used_at)`; `nuevo_code() returns text`.

- [ ] **Step 1: Escribir la prueba del canal explícito**

Antes del `rollback;`:

```sql
-- ── el canal es un dato propio, no se deduce de rrpp_id is null ──
do $$
declare v_ev uuid; v_ord uuid; v_tipo uuid; v_fase uuid; v_c1 text; v_c2 text;
begin
  select id into v_ev   from eventos where organizador_id = '11111111-1111-1111-1111-111111111111' and slug = 'halloween';
  select id into v_tipo from tipo_entrada where evento_id = v_ev and nombre = 'General';
  select fase_vigente(v_ev) into v_fase;
  select id into v_ord  from ordenes where evento_id = v_ev limit 1;

  insert into entradas (organizador_id, evento_id, orden_id, code, canal, tipo_id, fase_id, precio)
  values ('11111111-1111-1111-1111-111111111111', v_ev, v_ord, nuevo_code(), 'publico', v_tipo, v_fase, 120)
  returning code into v_c1;

  insert into entradas (organizador_id, evento_id, orden_id, code, canal, tipo_id, fase_id, precio)
  values ('11111111-1111-1111-1111-111111111111', v_ev, v_ord, nuevo_code(), 'publico', v_tipo, v_fase, 120)
  returning code into v_c2;

  if v_c1 = v_c2 then raise exception 'TEST_FAIL: nuevo_code() repitio el codigo'; end if;
  if length(v_c1) < 10 then raise exception 'TEST_FAIL: el codigo es muy corto: %', v_c1; end if;

  begin
    insert into entradas (organizador_id, evento_id, orden_id, code, canal, tipo_id, fase_id, precio)
    values ('11111111-1111-1111-1111-111111111111', v_ev, v_ord, v_c1, 'publico', v_tipo, v_fase, 120);
    raise exception 'TEST_FAIL: acepto dos entradas con el mismo code en el mismo evento';
  exception when unique_violation then null;
  end;

  raise notice 'OK entradas con canal explicito y code unico por evento';
end $$;
```

- [ ] **Step 2: Correrla y verla fallar**

Run: `psql "$TICKETERA_DB" -v ON_ERROR_STOP=1 -f ticketera/supabase/tests/flujo.sql`
Expected: FALLA con `relation "entradas" does not exist`.

- [ ] **Step 3: Escribir la migración**

`ticketera/supabase/migrations/0007_entradas.sql`:

```sql
-- ============================================================
-- 0007 — entradas emitidas
--
-- Tres diferencias con Puerta:
--   rrpp_id es NULLABLE — una venta pública no tiene relacionador.
--   orden_id agrupa las de una misma compra.
--   canal es un dato propio. Deducir "es pública porque rrpp_id is null"
--   es el NULL = NULL esperando a morder: mañana una venta de puerta
--   tampoco va a tener rrpp y quedarían contadas como públicas.
-- ============================================================

create table entradas (
  id              uuid primary key default gen_random_uuid(),
  organizador_id  uuid not null references organizadores on delete restrict,
  evento_id       uuid not null references eventos on delete cascade,
  orden_id        uuid references ordenes on delete restrict,

  code            text not null,
  canal           text not null check (canal in ('publico','rrpp','puerta','cortesia')),

  tipo_id         uuid references tipo_entrada on delete set null,
  fase_id         uuid references evento_fase  on delete set null,
  mesa_id         uuid references mesas        on delete set null,
  rrpp_id         uuid references perfiles(id),

  cliente         text,
  precio          numeric(12,2) not null check (precio >= 0),
  estado          text not null default 'valida' check (estado in ('valida','usada','anulada')),

  created_at      timestamptz not null default now(),
  used_at         timestamptz,
  portero_id      uuid references perfiles(id),
  unique (evento_id, code)
);
create index entradas_orden_idx on entradas (orden_id) where orden_id is not null;
create index entradas_evento_idx on entradas (evento_id, canal);
create index entradas_fase_idx  on entradas (fase_id) where fase_id is not null;

comment on column entradas.canal is
  'De dónde vino la venta. Dato propio, nunca deducido de rrpp_id is null.';
comment on column entradas.fase_id is
  'De qué fase salió. Sin esto no se puede contar el stock de la fase ni
   dibujar el arte correcto en el ticket.';

-- Código del QR. Base32 sin vocales para que no se formen palabras y sin
-- caracteres que se confundan a mano (0/O, 1/I).
create function nuevo_code() returns text
  language sql volatile set search_path = public as $$
  select string_agg(substr('23456789BCDFGHJKLMNPQRSTVWXZ',
                           1 + floor(random() * 28)::int, 1), '')
    from generate_series(1, 12)
$$;
revoke execute on function nuevo_code() from anon, public;
grant execute on function nuevo_code() to authenticated;

alter table entradas enable row level security;
create policy "entradas: las de mi organizador" on entradas for all to authenticated
  using (organizador_id = mi_organizador()) with check (organizador_id = mi_organizador());

revoke all on entradas from anon;
grant select, insert, update on entradas to authenticated;
```

- [ ] **Step 4: Aplicar y correr**

```bash
psql "$TICKETERA_DB" -v ON_ERROR_STOP=1 -f ticketera/supabase/migrations/0007_entradas.sql
psql "$TICKETERA_DB" -v ON_ERROR_STOP=1 -f ticketera/supabase/tests/flujo.sql
```

Expected: `NOTICE: OK entradas con canal explicito y code unico por evento`.

- [ ] **Step 5: Commit**

```bash
cd ticketera && git add . && git commit -m "feat: entradas con orden_id, canal explicito y rrpp_id nullable"
```

---

### Task 9: Disponibilidad que no depende del barrido

**Files:**
- Create: `ticketera/supabase/migrations/0008_disponibilidad.sql`
- Modify: `ticketera/supabase/tests/flujo.sql`

**Interfaces:**
- Consumes: `fase_precio`, `orden_items`, `ordenes`, `entradas`.
- Produces: `disponibilidad_tipo(p_fase uuid, p_tipo uuid) returns int` — devuelve cuántas quedan, o `null` si la fase no tiene cupo.

- [ ] **Step 1: Escribir la prueba de que una orden vencida libera stock sin barrido**

Antes del `rollback;`:

```sql
-- ── una orden vencida deja de retener cupo aunque nadie la haya barrido ──
do $$
declare v_ev uuid; v_tipo uuid; v_fase uuid; v_ord uuid; v_disp int;
begin
  select id into v_ev   from eventos where organizador_id = '11111111-1111-1111-1111-111111111111' and slug = 'halloween';
  select id into v_tipo from tipo_entrada where evento_id = v_ev and nombre = 'VIP';
  select fase_vigente(v_ev) into v_fase;   -- Preventa: VIP con cupo 20

  v_disp := disponibilidad_tipo(v_fase, v_tipo);
  if v_disp <> 20 then raise exception 'TEST_FAIL: al arrancar deberia haber 20 VIP, hay %', v_disp; end if;

  -- una orden pendiente VIVA retiene 3
  insert into ordenes (organizador_id, evento_id, expira_at, subtotal, fee, total)
  values ('11111111-1111-1111-1111-111111111111', v_ev, now() + interval '10 minutes', 750, 56, 806)
  returning id into v_ord;
  insert into orden_items (organizador_id, orden_id, tipo_id, fase_id, cantidad, precio_unitario)
  values ('11111111-1111-1111-1111-111111111111', v_ord, v_tipo, v_fase, 3, 250);

  v_disp := disponibilidad_tipo(v_fase, v_tipo);
  if v_disp <> 17 then raise exception 'TEST_FAIL: la orden viva deberia retener 3, quedan %', v_disp; end if;

  -- la misma orden VENCIDA, y SIN correr ningún barrido, no retiene nada
  update ordenes set expira_at = now() - interval '1 second' where id = v_ord;

  v_disp := disponibilidad_tipo(v_fase, v_tipo);
  if v_disp <> 20 then
    raise exception 'TEST_FAIL: la orden vencida sigue reteniendo; quedan % en vez de 20', v_disp;
  end if;

  raise notice 'OK la disponibilidad no depende de que el barrido haya corrido';
end $$;
```

- [ ] **Step 2: Correrla y verla fallar**

Run: `psql "$TICKETERA_DB" -v ON_ERROR_STOP=1 -f ticketera/supabase/tests/flujo.sql`
Expected: FALLA con `function disponibilidad_tipo(uuid, uuid) does not exist`.

- [ ] **Step 3: Escribir la migración**

`ticketera/supabase/migrations/0008_disponibilidad.sql`:

```sql
-- ============================================================
-- 0008 — cuántas quedan
--
-- Cuenta lo emitido MÁS lo que retienen las órdenes pendientes que todavía
-- están vivas. El filtro `expira_at > now()` es lo que hace que una orden
-- vencida deje de retener en el mismo instante en que vence, la haya
-- barrido alguien o no.
--
-- Importa porque en Puerta el barrido lo dispara un usuario logueado al
-- abrir la pantalla — `liberar_reservas_vencidas()` arranca con
-- `if auth.uid() is null then raise` — y en la landing pública no hay
-- ningún usuario garantizado.
-- ============================================================

create function disponibilidad_tipo(p_fase uuid, p_tipo uuid) returns int
  language plpgsql stable security definer set search_path = public as $function$
declare v_cupo int; v_emitidas int; v_retenidas int;
begin
  select cupo into v_cupo from fase_precio where fase_id = p_fase and tipo_id = p_tipo;
  if not found then return 0; end if;      -- ese tipo no se vende en esa fase
  if v_cupo is null then return null; end if;  -- sin tope: corta por fecha

  select count(*) into v_emitidas
    from entradas
   where fase_id = p_fase and tipo_id = p_tipo and estado <> 'anulada';

  select coalesce(sum(i.cantidad), 0) into v_retenidas
    from orden_items i
    join ordenes o on o.id = i.orden_id
   where i.fase_id = p_fase and i.tipo_id = p_tipo
     and o.estado = 'pendiente'
     and o.expira_at > now();

  return greatest(v_cupo - v_emitidas - v_retenidas, 0);
end $function$;
revoke execute on function disponibilidad_tipo(uuid, uuid) from anon, public;
grant execute on function disponibilidad_tipo(uuid, uuid) to authenticated;
```

- [ ] **Step 4: Aplicar y correr**

```bash
psql "$TICKETERA_DB" -v ON_ERROR_STOP=1 -f ticketera/supabase/migrations/0008_disponibilidad.sql
psql "$TICKETERA_DB" -v ON_ERROR_STOP=1 -f ticketera/supabase/tests/flujo.sql
```

Expected: `NOTICE: OK la disponibilidad no depende de que el barrido haya corrido`.

- [ ] **Step 5: Commit**

```bash
cd ticketera && git add . && git commit -m "feat: disponibilidad_tipo() cuenta pendientes vivas, no depende del barrido"
```

---

### Task 10: `crear_orden()` — bloqueo de cupo y cálculo del fee

**Files:**
- Create: `ticketera/supabase/migrations/0009_crear_orden.sql`
- Modify: `ticketera/supabase/tests/flujo.sql`
- Create: `ticketera/supabase/tests/concurrencia.sh`

**Interfaces:**
- Consumes: todo lo anterior.
- Produces:
  `crear_orden(p_evento uuid, p_items jsonb, p_comprador jsonb, p_client_key uuid, p_ip_hash text) returns jsonb`.
  `p_items` es un arreglo de `{"tipo_id":"…","cantidad":2}` y/o `{"mesa_id":"…"}`.
  Devuelve `{"ok":true,"orden":"<uuid>","subtotal":n,"fee":n,"total":n,"repetida":bool}`.
  Ante falta de cupo o mesa tomada, levanta excepción con mensaje `SIN_CUPO: …` o `MESA_TOMADA: …`.

- [ ] **Step 1: Escribir la prueba del fee**

Antes del `rollback;`:

```sql
-- ── el fee: % del subtotal + fijo por transaccion, con piso ──
do $$
declare v_ev uuid; v_tipo uuid; v_r jsonb;
begin
  select id into v_ev   from eventos where organizador_id = '11111111-1111-1111-1111-111111111111' and slug = 'halloween';
  select id into v_tipo from tipo_entrada where evento_id = v_ev and nombre = 'General';

  -- 1 General a 120 → 7% de 120 = 8.40, redondeado 8, + 3 = 11
  v_r := crear_orden(v_ev,
           jsonb_build_array(jsonb_build_object('tipo_id', v_tipo, 'cantidad', 1)),
           '{"nombre":"Test","email":"t@test.bo"}'::jsonb, gen_random_uuid(), 'hash1');
  if (v_r->>'subtotal')::numeric <> 120 then raise exception 'TEST_FAIL: subtotal % , esperaba 120', v_r->>'subtotal'; end if;
  if (v_r->>'fee')::numeric <> 11 then raise exception 'TEST_FAIL: fee % , esperaba 11', v_r->>'fee'; end if;
  if (v_r->>'total')::numeric <> 131 then raise exception 'TEST_FAIL: total % , esperaba 131', v_r->>'total'; end if;

  raise notice 'OK fee = 7%% + 3 Bs';
end $$;

-- ── el piso tapa el caso de la entrada barata ──
do $$
declare v_ev uuid; v_barato uuid; v_r jsonb; v_fase uuid;
begin
  select id into v_ev from eventos where organizador_id = '11111111-1111-1111-1111-111111111111' and slug = 'halloween';
  select fase_vigente(v_ev) into v_fase;

  insert into tipo_entrada (organizador_id, evento_id, nombre, orden)
  values ('11111111-1111-1111-1111-111111111111', v_ev, 'Estudiante', 3) returning id into v_barato;
  insert into fase_precio (organizador_id, fase_id, tipo_id, precio, cupo)
  values ('11111111-1111-1111-1111-111111111111', v_fase, v_barato, 20, 50);

  -- 7% de 20 = 1.40 → 1, + 3 = 4, menor al piso 5 → cobra 5
  v_r := crear_orden(v_ev,
           jsonb_build_array(jsonb_build_object('tipo_id', v_barato, 'cantidad', 1)),
           '{"nombre":"Test"}'::jsonb, gen_random_uuid(), 'hash2');
  if (v_r->>'fee')::numeric <> 5 then
    raise exception 'TEST_FAIL: el piso deberia dejar el fee en 5, dio %', v_r->>'fee';
  end if;

  raise notice 'OK el piso del fee funciona';
end $$;

-- ── reintentar con la misma client_key devuelve la orden original ──
do $$
declare v_ev uuid; v_tipo uuid; v_key uuid := gen_random_uuid(); v_a jsonb; v_b jsonb; v_n int;
begin
  select id into v_ev   from eventos where organizador_id = '11111111-1111-1111-1111-111111111111' and slug = 'halloween';
  select id into v_tipo from tipo_entrada where evento_id = v_ev and nombre = 'General';

  v_a := crear_orden(v_ev, jsonb_build_array(jsonb_build_object('tipo_id', v_tipo, 'cantidad', 2)),
                     '{"nombre":"Test"}'::jsonb, v_key, 'hash3');
  v_b := crear_orden(v_ev, jsonb_build_array(jsonb_build_object('tipo_id', v_tipo, 'cantidad', 2)),
                     '{"nombre":"Test"}'::jsonb, v_key, 'hash3');

  if (v_a->>'orden') <> (v_b->>'orden') then
    raise exception 'TEST_FAIL: la client_key repetida creo una orden nueva';
  end if;
  if (v_b->>'repetida')::boolean is not true then
    raise exception 'TEST_FAIL: el reintento no vino marcado como repetida';
  end if;

  select count(*) into v_n from ordenes where client_key = v_key;
  if v_n <> 1 then raise exception 'TEST_FAIL: hay % ordenes con la misma client_key', v_n; end if;

  raise notice 'OK crear_orden() es idempotente por client_key';
end $$;

-- ── el tope de entradas por orden ──
do $$
declare v_ev uuid; v_tipo uuid;
begin
  select id into v_ev   from eventos where organizador_id = '11111111-1111-1111-1111-111111111111' and slug = 'halloween';
  select id into v_tipo from tipo_entrada where evento_id = v_ev and nombre = 'General';
  begin
    perform crear_orden(v_ev, jsonb_build_array(jsonb_build_object('tipo_id', v_tipo, 'cantidad', 11)),
                        '{"nombre":"Test"}'::jsonb, gen_random_uuid(), 'hash4');
    raise exception 'TEST_FAIL: acepto 11 entradas con tope 10';
  exception when others then
    if sqlerrm not like 'TOPE:%' then raise; end if;
  end;
  raise notice 'OK el tope de entradas por orden se respeta';
end $$;
```

- [ ] **Step 2: Correrlas y verlas fallar**

Run: `psql "$TICKETERA_DB" -v ON_ERROR_STOP=1 -f ticketera/supabase/tests/flujo.sql`
Expected: FALLA con `function crear_orden(...) does not exist`.

- [ ] **Step 3: Escribir la migración**

`ticketera/supabase/migrations/0009_crear_orden.sql`:

```sql
-- ============================================================
-- 0009 — crear_orden()
--
-- Tres garantías, en este orden:
--
-- 1. `select ... for update` sobre fase_precio ANTES de contar. Contar y
--    después insertar es una carrera: dos compradores leen "queda 1" y los
--    dos insertan. El bloqueo serializa a los compradores de ese tipo en
--    esa fase, que es el grano correcto.
--
-- 2. La mesa se toma con un UPDATE CONDICIONAL. La condición viaja dentro
--    del update, nunca en un `if` previo: si vuelven 0 filas, alguien llegó
--    primero.
--
-- 3. Idempotencia por client_key antes de tocar nada.
--
-- Esta función NO se le otorga a anon. La llama una Edge Function con
-- service_role (Bloque 2).
-- ============================================================

create function crear_orden(
  p_evento     uuid,
  p_items      jsonb,
  p_comprador  jsonb default '{}'::jsonb,
  p_client_key uuid  default null,
  p_ip_hash    text  default null
) returns jsonb
  language plpgsql volatile security definer set search_path = public as $function$
declare
  v_org uuid; v_fase uuid; v_tope int; v_estado text;
  v_org_row organizadores;
  v_orden uuid; v_sub numeric(12,2) := 0; v_fee numeric(12,2); v_entradas int := 0;
  v_it jsonb; v_tipo uuid; v_mesa uuid; v_cant int;
  v_precio numeric(12,2); v_cupo int; v_disp int; v_n int;
  v_pend int;
begin
  select organizador_id, estado, tope_entradas_orden
    into v_org, v_estado, v_tope
    from eventos where id = p_evento;
  if not found then raise exception 'EVENTO_INEXISTENTE: %', p_evento; end if;
  if v_estado <> 'publicado' then raise exception 'EVENTO_NO_PUBLICADO: %', p_evento; end if;

  -- 3. idempotencia primero: si ya existe, devolverla sin tocar stock
  if p_client_key is not null then
    select id into v_orden from ordenes where client_key = p_client_key;
    if found then
      return (select jsonb_build_object('ok', true, 'orden', o.id, 'subtotal', o.subtotal,
                                        'fee', o.fee, 'total', o.total, 'repetida', true)
                from ordenes o where o.id = v_orden);
    end if;
  end if;

  -- freno de abuso por IP
  if p_ip_hash is not null then
    select count(*) into v_pend from ordenes
     where ip_hash = p_ip_hash and estado = 'pendiente' and expira_at > now();
    if v_pend >= 5 then raise exception 'DEMASIADAS_ORDENES: % pendientes desde esta IP', v_pend; end if;
  end if;

  select * into v_org_row from organizadores where id = v_org;
  v_fase := fase_vigente(p_evento);

  insert into ordenes (organizador_id, evento_id, client_key, expira_at,
                       comprador_nombre, comprador_email, comprador_telefono,
                       subtotal, fee, total, ip_hash)
  values (v_org, p_evento, p_client_key, now() + interval '10 minutes',
          p_comprador->>'nombre', p_comprador->>'email', p_comprador->>'telefono',
          0, 0, 0, p_ip_hash)
  returning id into v_orden;

  for v_it in select * from jsonb_array_elements(p_items) loop
    v_tipo := nullif(v_it->>'tipo_id','')::uuid;
    v_mesa := nullif(v_it->>'mesa_id','')::uuid;
    v_cant := coalesce((v_it->>'cantidad')::int, 1);

    if (v_tipo is null) = (v_mesa is null) then
      raise exception 'ITEM_INVALIDO: cada item lleva tipo_id o mesa_id, no los dos ni ninguno';
    end if;

    if v_tipo is not null then
      if v_fase is null then raise exception 'SIN_FASE: el evento no tiene fase abierta'; end if;
      if v_cant < 1 then raise exception 'ITEM_INVALIDO: cantidad %', v_cant; end if;

      -- 1. bloquear la fila del cruce ANTES de contar
      select precio, cupo into v_precio, v_cupo
        from fase_precio where fase_id = v_fase and tipo_id = v_tipo for update;
      if not found then raise exception 'TIPO_NO_VENDIBLE: ese tipo no se vende en la fase abierta'; end if;

      if v_cupo is not null then
        v_disp := disponibilidad_tipo(v_fase, v_tipo);
        if v_disp < v_cant then
          raise exception 'SIN_CUPO: quedan % y se pidieron %', v_disp, v_cant;
        end if;
      end if;

      insert into orden_items (organizador_id, orden_id, tipo_id, fase_id, cantidad, precio_unitario)
      values (v_org, v_orden, v_tipo, v_fase, v_cant, v_precio);

      v_sub := v_sub + v_precio * v_cant;
      v_entradas := v_entradas + v_cant;

    else
      -- 2. el update condicional ES la exclusión
      update mesas set estado = 'bloqueada', orden_id = v_orden, updated_at = now()
       where id = v_mesa and evento_id = p_evento and estado = 'disponible'
      returning precio into v_precio;
      get diagnostics v_n = row_count;
      if v_n = 0 then raise exception 'MESA_TOMADA: la mesa % ya no esta disponible', v_mesa; end if;

      insert into orden_items (organizador_id, orden_id, mesa_id, cantidad, precio_unitario)
      values (v_org, v_orden, v_mesa, 1, v_precio);

      v_sub := v_sub + v_precio;
    end if;
  end loop;

  if v_sub = 0 and v_entradas = 0 then raise exception 'ORDEN_VACIA: no se pidio nada'; end if;
  if v_entradas > v_tope then raise exception 'TOPE: % entradas, el maximo es %', v_entradas, v_tope; end if;

  v_fee := greatest(round(v_sub * v_org_row.fee_pct) + v_org_row.fee_fijo_transaccion,
                    v_org_row.fee_piso);

  update ordenes set subtotal = v_sub, fee = v_fee, total = v_sub + v_fee where id = v_orden;

  return jsonb_build_object('ok', true, 'orden', v_orden, 'subtotal', v_sub,
                            'fee', v_fee, 'total', v_sub + v_fee, 'repetida', false);
end $function$;
revoke execute on function crear_orden(uuid, jsonb, jsonb, uuid, text) from anon, public;
```

- [ ] **Step 4: Aplicar y correr las pruebas de flujo**

```bash
psql "$TICKETERA_DB" -v ON_ERROR_STOP=1 -f ticketera/supabase/migrations/0009_crear_orden.sql
psql "$TICKETERA_DB" -v ON_ERROR_STOP=1 -f ticketera/supabase/tests/flujo.sql
```

Expected: cuatro `NOTICE` — fee, piso, idempotencia y tope. Si el evento no está `publicado`, las pruebas fallan con `EVENTO_NO_PUBLICADO`: agregar `update eventos set estado = 'publicado';` justo después de los `insert into eventos` de la Tarea 4.

- [ ] **Step 5: Escribir la prueba de concurrencia real**

Un test secuencial de una carrera no prueba nada. Hacen falta dos sesiones.

`ticketera/supabase/tests/concurrencia.sh`:

```bash
#!/usr/bin/env bash
# Dos compradores por la última butaca. Solo uno puede ganar.
set -euo pipefail
: "${TICKETERA_DB:?exporta TICKETERA_DB}"

ORG=$(uuidgen | tr 'A-Z' 'a-z')

psql "$TICKETERA_DB" -v ON_ERROR_STOP=1 -q <<SQL
insert into organizadores (id, slug, nombre) values ('$ORG', 'carrera-$RANDOM', 'Carrera');
insert into eventos (id, organizador_id, slug, nombre, fecha, estado)
  values ('$ORG'::uuid, '$ORG', 'carrera', 'Carrera', current_date + 30, 'publicado');
insert into tipo_entrada (id, organizador_id, evento_id, nombre)
  values ('$ORG'::uuid, '$ORG', '$ORG', 'Unica');
insert into evento_fase (id, organizador_id, evento_id, nombre, desde, hasta)
  values ('$ORG'::uuid, '$ORG', '$ORG', 'F1', now() - interval '1 hour', now() + interval '1 day');
insert into fase_precio (organizador_id, fase_id, tipo_id, precio, cupo)
  values ('$ORG', '$ORG', '$ORG', 100, 1);
SQL

# Las dos sesiones piden la misma butaca. La primera duerme DENTRO de la
# transacción, después del `for update`, para que la segunda choque de verdad
# contra el bloqueo en vez de pasarle por al lado.
comprar () {
  psql "$TICKETERA_DB" -q -t -A <<SQL 2>&1 || true
begin;
select pg_sleep($1);
select crear_orden('$ORG'::uuid,
  jsonb_build_array(jsonb_build_object('tipo_id','$ORG','cantidad',1)),
  '{"nombre":"$2"}'::jsonb, gen_random_uuid(), null);
commit;
SQL
}

comprar 0   A > /tmp/carrera_a.txt &
comprar 0.1 B > /tmp/carrera_b.txt &
wait

OK=$(cat /tmp/carrera_a.txt /tmp/carrera_b.txt | grep -c '"ok": true' || true)
SIN=$(cat /tmp/carrera_a.txt /tmp/carrera_b.txt | grep -c 'SIN_CUPO' || true)

VENDIDAS=$(psql "$TICKETERA_DB" -t -A -c \
  "select coalesce(sum(i.cantidad),0) from orden_items i join ordenes o on o.id=i.orden_id
    where i.tipo_id='$ORG' and o.estado='pendiente' and o.expira_at > now();")

psql "$TICKETERA_DB" -q -c "delete from organizadores where id='$ORG';" || true

if [ "$VENDIDAS" != "1" ]; then
  echo "TEST_FAIL: se vendieron $VENDIDAS de 1 butaca (ok=$OK sin_cupo=$SIN)"; exit 1
fi
echo "OK la carrera por la ultima butaca la gana uno solo (ok=$OK sin_cupo=$SIN)"
```

- [ ] **Step 6: Correr la prueba de concurrencia**

```bash
chmod +x ticketera/supabase/tests/concurrencia.sh
bash ticketera/supabase/tests/concurrencia.sh
```

Expected: `OK la carrera por la ultima butaca la gana uno solo (ok=1 sin_cupo=1)`.

Si sale `TEST_FAIL: se vendieron 2 de 1 butaca`, el `for update` no está haciendo efecto: verificar que en `crear_orden` el `select … for update` esté **antes** de la llamada a `disponibilidad_tipo`, no después.

- [ ] **Step 7: Commit**

```bash
cd ticketera && git add . && git commit -m "feat: crear_orden() con bloqueo de cupo, fee y freno de abuso"
```

---

### Task 11: `emitir_orden()` idempotente

**Files:**
- Create: `ticketera/supabase/migrations/0010_emitir_orden.sql`
- Modify: `ticketera/supabase/tests/flujo.sql`

**Interfaces:**
- Consumes: `ordenes`, `orden_items`, `entradas`, `mesas`, `nuevo_code()`.
- Produces: `emitir_orden(p_orden uuid, p_monto_cobrado numeric, p_pago_ref text) returns jsonb`. Devuelve `{"ok":true,"orden":uuid,"entradas":n,"repetida":bool}`. Si el monto no coincide, deja la orden en `revision_manual` y devuelve `{"ok":false,"motivo":"MONTO"}`.

- [ ] **Step 1: Escribir las pruebas de emisión**

Antes del `rollback;`:

```sql
-- ── emitir dos veces la misma orden emite una sola vez ──
do $$
declare v_ev uuid; v_tipo uuid; v_r jsonb; v_ord uuid; v_n int;
begin
  select id into v_ev   from eventos where organizador_id = '11111111-1111-1111-1111-111111111111' and slug = 'halloween';
  select id into v_tipo from tipo_entrada where evento_id = v_ev and nombre = 'General';

  v_r := crear_orden(v_ev, jsonb_build_array(jsonb_build_object('tipo_id', v_tipo, 'cantidad', 2)),
                     '{"nombre":"Doble"}'::jsonb, gen_random_uuid(), 'hash5');
  v_ord := (v_r->>'orden')::uuid;

  perform emitir_orden(v_ord, (v_r->>'total')::numeric, 'tx-1');
  perform emitir_orden(v_ord, (v_r->>'total')::numeric, 'tx-1');

  select count(*) into v_n from entradas where orden_id = v_ord;
  if v_n <> 2 then raise exception 'TEST_FAIL: emitio % entradas, esperaba 2', v_n; end if;
  if (select estado from ordenes where id = v_ord) <> 'pagada' then
    raise exception 'TEST_FAIL: la orden no quedo pagada';
  end if;

  raise notice 'OK emitir_orden() es idempotente';
end $$;

-- ── una mesa emite tantas entradas como manillas incluye ──
do $$
declare v_ev uuid; v_mesa uuid; v_r jsonb; v_ord uuid; v_n int;
begin
  select id into v_ev from eventos where organizador_id = '11111111-1111-1111-1111-111111111111' and slug = 'halloween';
  select id into v_mesa from mesas where evento_id = v_ev and estado = 'disponible' limit 1;
  if v_mesa is null then
    insert into mesas (organizador_id, evento_id, planta, etiqueta, categoria, x, y, w, precio, manillas)
    values ('11111111-1111-1111-1111-111111111111', v_ev, 'baja', 'M99', 'mesa', 50, 50, 8, 1200, 8)
    returning id into v_mesa;
  end if;
  update mesas set manillas = 8 where id = v_mesa;

  v_r := crear_orden(v_ev, jsonb_build_array(jsonb_build_object('mesa_id', v_mesa)),
                     '{"nombre":"Mesa"}'::jsonb, gen_random_uuid(), 'hash6');
  v_ord := (v_r->>'orden')::uuid;
  perform emitir_orden(v_ord, (v_r->>'total')::numeric, 'tx-2');

  select count(*) into v_n from entradas where orden_id = v_ord;
  if v_n <> 8 then raise exception 'TEST_FAIL: la mesa de 8 emitio % entradas', v_n; end if;
  if (select estado from mesas where id = v_mesa) <> 'pagada' then
    raise exception 'TEST_FAIL: la mesa no quedo pagada';
  end if;

  raise notice 'OK una mesa emite una entrada por manilla';
end $$;

-- ── monto que no coincide: no emite nada y va a revision manual ──
do $$
declare v_ev uuid; v_tipo uuid; v_r jsonb; v_ord uuid; v_n int; v_res jsonb;
begin
  select id into v_ev   from eventos where organizador_id = '11111111-1111-1111-1111-111111111111' and slug = 'halloween';
  select id into v_tipo from tipo_entrada where evento_id = v_ev and nombre = 'General';

  v_r := crear_orden(v_ev, jsonb_build_array(jsonb_build_object('tipo_id', v_tipo, 'cantidad', 1)),
                     '{"nombre":"Monto"}'::jsonb, gen_random_uuid(), 'hash7');
  v_ord := (v_r->>'orden')::uuid;

  v_res := emitir_orden(v_ord, 1.00, 'tx-3');   -- pagó 1 Bs, debía 131

  if (v_res->>'ok')::boolean is not false then raise exception 'TEST_FAIL: emitio con monto distinto'; end if;
  select count(*) into v_n from entradas where orden_id = v_ord;
  if v_n <> 0 then raise exception 'TEST_FAIL: emitio % entradas con monto distinto', v_n; end if;
  if (select estado from ordenes where id = v_ord) <> 'revision_manual' then
    raise exception 'TEST_FAIL: la orden no quedo en revision_manual';
  end if;

  raise notice 'OK monto distinto: no emite y va a revision manual';
end $$;
```

- [ ] **Step 2: Correrlas y verlas fallar**

Run: `psql "$TICKETERA_DB" -v ON_ERROR_STOP=1 -f ticketera/supabase/tests/flujo.sql`
Expected: FALLA con `function emitir_orden(uuid, numeric, text) does not exist`.

- [ ] **Step 3: Escribir la migración**

`ticketera/supabase/migrations/0010_emitir_orden.sql`:

```sql
-- ============================================================
-- 0010 — emitir_orden()
--
-- Tres caminos distintos llaman acá y ninguno confía en el otro: el
-- callback de la pasarela, el retorno del navegador y el barrido. Por eso
-- la primera línea útil es "¿ya está pagada?" y devuelve sin tocar nada.
--
-- El monto se compara SIEMPRE. Emitir por un monto distinto al cobrado es
-- un error que después no se deshace, porque la persona ya entró al evento.
-- ============================================================

create function emitir_orden(
  p_orden          uuid,
  p_monto_cobrado  numeric default null,
  p_pago_ref       text    default null
) returns jsonb
  language plpgsql volatile security definer set search_path = public as $function$
declare o ordenes; v_n int; v_it record; i int;
begin
  select * into o from ordenes where id = p_orden for update;
  if not found then raise exception 'ORDEN_INEXISTENTE: %', p_orden; end if;

  -- ya emitida: devolver lo que hay, sin duplicar
  if o.estado = 'pagada' then
    select count(*) into v_n from entradas where orden_id = p_orden;
    return jsonb_build_object('ok', true, 'orden', p_orden, 'entradas', v_n, 'repetida', true);
  end if;

  if o.estado in ('anulada','revision_manual') then
    return jsonb_build_object('ok', false, 'motivo', upper(o.estado));
  end if;

  -- el monto manda
  if p_monto_cobrado is not null and p_monto_cobrado <> o.total then
    update ordenes set estado = 'revision_manual', pago_ref = coalesce(p_pago_ref, pago_ref)
     where id = p_orden;
    return jsonb_build_object('ok', false, 'motivo', 'MONTO',
                              'esperado', o.total, 'cobrado', p_monto_cobrado);
  end if;

  for v_it in select * from orden_items where orden_id = p_orden loop
    if v_it.tipo_id is not null then
      for i in 1 .. v_it.cantidad loop
        insert into entradas (organizador_id, evento_id, orden_id, code, canal,
                              tipo_id, fase_id, cliente, precio)
        values (o.organizador_id, o.evento_id, p_orden, nuevo_code(), 'publico',
                v_it.tipo_id, v_it.fase_id, o.comprador_nombre, v_it.precio_unitario);
      end loop;
    else
      -- una mesa emite una entrada por manilla: la puerta escanea personas
      insert into entradas (organizador_id, evento_id, orden_id, code, canal,
                            mesa_id, cliente, precio)
      select o.organizador_id, o.evento_id, p_orden, nuevo_code(), 'publico',
             m.id, o.comprador_nombre, 0
        from mesas m, generate_series(1, m.manillas)
       where m.id = v_it.mesa_id;

      update mesas set estado = 'pagada', updated_at = now() where id = v_it.mesa_id;
    end if;
  end loop;

  update ordenes
     set estado = 'pagada', pagada_at = now(), pago_ref = coalesce(p_pago_ref, pago_ref)
   where id = p_orden;

  select count(*) into v_n from entradas where orden_id = p_orden;
  return jsonb_build_object('ok', true, 'orden', p_orden, 'entradas', v_n, 'repetida', false);
end $function$;
revoke execute on function emitir_orden(uuid, numeric, text) from anon, public;
```

- [ ] **Step 4: Aplicar y correr**

```bash
psql "$TICKETERA_DB" -v ON_ERROR_STOP=1 -f ticketera/supabase/migrations/0010_emitir_orden.sql
psql "$TICKETERA_DB" -v ON_ERROR_STOP=1 -f ticketera/supabase/tests/flujo.sql
```

Expected: tres `NOTICE` — idempotencia, mesa de 8 manillas, monto distinto.

- [ ] **Step 5: Commit**

```bash
cd ticketera && git add . && git commit -m "feat: emitir_orden() idempotente con control de monto"
```

---

### Task 12: El barrido que consulta antes de anular

**Files:**
- Create: `ticketera/supabase/migrations/0011_vencer_ordenes.sql`
- Modify: `ticketera/supabase/tests/flujo.sql`

**Interfaces:**
- Consumes: `ordenes`, `mesas`.
- Produces: `vencer_ordenes(p_evento uuid default null) returns jsonb` — devuelve `{"ok":true,"vencidas":n,"mesas_liberadas":n,"a_confirmar":[uuid,…]}`. **No anula las que tienen `pago_ref`**: esas las devuelve en `a_confirmar` para que la Edge Function del Bloque 2 las consulte contra la pasarela.

- [ ] **Step 1: Escribir la prueba del barrido**

Antes del `rollback;`:

```sql
-- ── el barrido libera lo vencido, pero NO anula lo que tiene pago en curso ──
do $$
declare v_ev uuid; v_tipo uuid; v_mesa uuid; v_a uuid; v_b uuid; v_r jsonb;
begin
  select id into v_ev   from eventos where organizador_id = '11111111-1111-1111-1111-111111111111' and slug = 'halloween';
  select id into v_tipo from tipo_entrada where evento_id = v_ev and nombre = 'General';

  insert into mesas (organizador_id, evento_id, planta, etiqueta, categoria, x, y, w, precio, manillas)
  values ('11111111-1111-1111-1111-111111111111', v_ev, 'baja', 'M77', 'mesa', 30, 30, 8, 900, 6)
  returning id into v_mesa;

  -- A: vencida y sin pago iniciado → se anula y libera la mesa
  v_a := (crear_orden(v_ev, jsonb_build_array(jsonb_build_object('mesa_id', v_mesa)),
          '{"nombre":"A"}'::jsonb, gen_random_uuid(), 'hash8')->>'orden')::uuid;

  -- B: vencida PERO con pago_ref → no se toca, se devuelve para consultar
  v_b := (crear_orden(v_ev, jsonb_build_array(jsonb_build_object('tipo_id', v_tipo, 'cantidad', 1)),
          '{"nombre":"B"}'::jsonb, gen_random_uuid(), 'hash9')->>'orden')::uuid;
  update ordenes set pago_ref = 'tx-en-curso' where id = v_b;

  update ordenes set expira_at = now() - interval '1 minute' where id in (v_a, v_b);

  v_r := vencer_ordenes(v_ev);

  if (select estado from ordenes where id = v_a) <> 'vencida' then
    raise exception 'TEST_FAIL: la orden sin pago no se vencio';
  end if;
  if (select estado from mesas where id = v_mesa) <> 'disponible' then
    raise exception 'TEST_FAIL: la mesa no se libero';
  end if;
  if (select estado from ordenes where id = v_b) <> 'pendiente' then
    raise exception 'TEST_FAIL: anulo una orden con pago en curso';
  end if;
  if not (v_r->'a_confirmar') @> to_jsonb(v_b::text) then
    raise exception 'TEST_FAIL: la orden con pago no vino en a_confirmar';
  end if;

  raise notice 'OK el barrido libera lo abandonado y no toca lo que tiene pago en curso';
end $$;
```

- [ ] **Step 2: Correrla y verla fallar**

Run: `psql "$TICKETERA_DB" -v ON_ERROR_STOP=1 -f ticketera/supabase/tests/flujo.sql`
Expected: FALLA con `function vencer_ordenes(uuid) does not exist`.

- [ ] **Step 3: Escribir la migración**

`ticketera/supabase/migrations/0011_vencer_ordenes.sql`:

```sql
-- ============================================================
-- 0011 — el barrido
--
-- Anular una orden vencida sin preguntarle a la pasarela es cobrarle a
-- alguien y no darle la entrada. Por eso el barrido NO decide sobre las
-- órdenes que ya iniciaron pago: las devuelve en `a_confirmar` y la Edge
-- Function del Bloque 2 las consulta contra consulta_transaccion_v2.php
-- antes de anular o emitir.
--
-- A diferencia de liberar_reservas_vencidas() en Puerta, esta función no
-- exige auth.uid(): la llama un job, no una pantalla.
-- ============================================================

create function vencer_ordenes(p_evento uuid default null) returns jsonb
  language plpgsql volatile security definer set search_path = public as $function$
declare v_ids uuid[]; v_conf uuid[]; v_mesas int;
begin
  -- las que tienen pago en curso: no se tocan, se reportan
  select coalesce(array_agg(id), '{}') into v_conf
    from ordenes
   where estado = 'pendiente' and expira_at <= now()
     and pago_ref is not null
     and (p_evento is null or evento_id = p_evento);

  -- las abandonadas de verdad
  select coalesce(array_agg(id), '{}') into v_ids
    from ordenes
   where estado = 'pendiente' and expira_at <= now()
     and pago_ref is null
     and (p_evento is null or evento_id = p_evento);

  if array_length(v_ids, 1) is null then
    return jsonb_build_object('ok', true, 'vencidas', 0, 'mesas_liberadas', 0,
                              'a_confirmar', to_jsonb(v_conf));
  end if;

  update mesas set estado = 'disponible', orden_id = null, updated_at = now()
   where orden_id = any(v_ids) and estado = 'bloqueada';
  get diagnostics v_mesas = row_count;

  update ordenes set estado = 'vencida' where id = any(v_ids);

  return jsonb_build_object('ok', true,
                            'vencidas', array_length(v_ids, 1),
                            'mesas_liberadas', v_mesas,
                            'a_confirmar', to_jsonb(v_conf));
end $function$;
revoke execute on function vencer_ordenes(uuid) from anon, public;
```

- [ ] **Step 4: Aplicar y correr toda la batería**

```bash
psql "$TICKETERA_DB" -v ON_ERROR_STOP=1 -f ticketera/supabase/migrations/0011_vencer_ordenes.sql
psql "$TICKETERA_DB" -v ON_ERROR_STOP=1 -f ticketera/supabase/tests/flujo.sql
psql "$TICKETERA_DB" -v ON_ERROR_STOP=1 -f ticketera/supabase/tests/invariantes.sql
bash ticketera/supabase/tests/concurrencia.sh
```

Expected: todos los `NOTICE OK`, los cuatro invariantes en verde, y la carrera ganada por uno solo.

- [ ] **Step 5: Verificar desde cero**

```bash
supabase db reset --workdir ticketera
psql "$TICKETERA_DB" -v ON_ERROR_STOP=1 -f ticketera/supabase/tests/invariantes.sql
psql "$TICKETERA_DB" -v ON_ERROR_STOP=1 -f ticketera/supabase/tests/flujo.sql
```

Expected: las once migraciones aplican en orden sobre una base vacía y las pruebas pasan. Si `db reset` falla, hay una migración que depende de algo que crea una posterior.

- [ ] **Step 6: Commit**

```bash
cd ticketera && git add . && git commit -m "feat: barrido que consulta antes de anular"
```

---

## Qué queda para los bloques siguientes

Este bloque deja la base en pie y probada. **`anon` todavía no tiene ni un permiso**, que es lo correcto: las vistas públicas llegan con las Edge Functions que las acompañan, no antes.

| Bloque | Qué construye |
|---|---|
| 2 — Checkout público | Vistas públicas con `security_invoker`, los `grant select` a `anon`, y las Edge Functions `crear-orden`, `iniciar-pago`, `callback-pago`, `estado-orden`, más el job del barrido. Se prueba contra el comercio `1518` BeePlay Stage |
| 3 — Landing | La SPA real sobre el prototipo de `ticketera/demo/index.html`, más `/orden/<uuid>` y el dibujo del QR con `ticketImage()` |
| 4 — Administración | Alta de eventos, fases, tipos y planimetría; liquidación por evento |
| 5 — Relacionador y puerta | Links de relacionador con atribución, comisiones y escaneo en la puerta |
