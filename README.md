# Ticketera

Ticketera multi-tenant con landing pública de autoservicio.
Diseño: `docs/superpowers/specs/2026-08-27-ticketera-design.md`
Plan del bloque 1: `docs/superpowers/plans/2026-08-27-ticketera-bloque1-base.md`

**En producción:** https://ticketera-coral.vercel.app

## Qué hay

| Carpeta | Qué es |
|---|---|
| `app/` | La landing pública. HTML/CSS/JS planos, sin build |
| `supabase/migrations/` | Las 11 migraciones, en orden |
| `supabase/functions/` | Las 4 Edge Functions |
| `supabase/seed.sql` | El evento de prueba (Amstel Ferial) |
| `supabase/tests/invariantes.sql` | Los 4 guardas estructurales |
| `scripts/` | Correr SQL y desplegar funciones con un PAT, sin la CLI |

**Proyecto Supabase:** `mjotxzcddhqqpuhkcetl` (sa-east-1).
La contraseña de la base está en `.credenciales`, que no se versiona.

## La regla que sostiene todo

**`anon` no tiene ni un permiso.** No lee tablas, no escribe y no ejecuta
funciones. Todo lo que hace el público pasa por una Edge Function que corre con
`service_role` del lado del servidor. La anon key del navegador sola no abre
nada, y por eso puede estar en `app/config.js`.

## Correr local

    python3 -m http.server 4174 --directory app

`app/config.js` decide contra qué habla: `MODO: "supabase"` usa la base real,
`MODO: "demo"` resuelve todo en memoria sin tocar nada.

## Invariantes

Corren contra la base migrada y no escriben. Son las trampas de Plataforma
Puerta convertidas en algo que grita solo:

1. Toda tabla lleva `organizador_id not null`.
2. Ninguna vista perdió `security_invoker=on`.
3. `anon` no escribe ni ejecuta nada.
4. Ninguna función tiene dos firmas vivas.

    export SUPABASE_PAT=...   # o dejalo en ~/.supabase_pat
    python3 scripts/sql.py supabase/tests/invariantes.sql

## Pasarela

`iniciar-pago` y `estado-orden` leen la variable `PASARELA` del proyecto:

- `simulada` (actual) — no cobra. El flujo entero funciona igual.
- `v2pro` — BeePay real. Necesita `V2PRO_LLAVE`, `V2PRO_USUARIO` y `V2PRO_PASS`
  del comercio. Empezar por `1518` (BeePlay Stage).

`estado-orden` nunca le cree al navegador: consulta la pasarela y compara el
monto contra `ordenes.total` antes de emitir.

## Resetear el evento de prueba

    python3 scripts/sql.py supabase/tests/reset.sql

## Desplegar

**Frontend** (Vercel, proyecto `blackyssjs-projects/ticketera`):

    cd app && npx vercel@latest deploy --prod

**Migraciones y funciones** (necesitan `SUPABASE_PAT`):

    python3 scripts/sql.py supabase/migrations/00XX_lo_que_sea.sql
    python3 scripts/desplegar-funciones.py            # las cuatro
    python3 scripts/desplegar-funciones.py evento     # una sola

Las Edge Functions desplegadas por API **no se bundlean**: no pueden llevar
`import` remotos (`jsr:` ni `https://esm.sh/...`) porque dan `BOOT_ERROR`. Por
eso hablan PostgREST con `fetch` en vez de usar `@supabase/supabase-js`.

## Lo que todavía no existe

Solo está la **vista pública de compra**. Faltan, en este orden:

1. **Administración** — alta de eventos, fases, tipos, planimetría y reportes.
2. **Relacionador** — link propio con atribución, sus ventas y su comisión.
3. **Puerta** — escaneo del QR y control de ingreso.

La base ya las sostiene: `perfiles` con roles, `mi_organizador()`, `mi_rol()` y
las policies de RLS por tenant. Falta la interfaz y configurar el registro de
cuentas, que hoy está cerrado a propósito.

## Reglas que no se negocian

Las cuatro salen de errores ya pagados en Plataforma Puerta, y hay un
invariante que hace fallar la migración si se rompen:

1. Toda tabla lleva `organizador_id not null`.
2. Cada vista lleva su `alter view ... set (security_invoker = on)` en la misma
   migración: `create or replace view` borra las reloptions.
3. Cambiar la firma de una función es `drop function` + `create`, nunca
   `create or replace` con un parámetro nuevo — quedan dos firmas vivas y
   PostgREST responde *could not choose a candidate function*.
4. Ninguna función es ejecutable por `anon`. Postgres le da `execute` a
   `public` por defecto y `anon` lo hereda, así que cada función nueva necesita
   su `revoke execute ... from anon, public`.
