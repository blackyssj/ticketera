-- 0049 — la cuenta del comprador
--
-- Hasta acá el comprador no existía como usuario: compraba, le llegaba un
-- link con el uuid de la orden y ese uuid era su única credencial. Lo que
-- tenía guardado vivía en el localStorage de ESE navegador
-- (`ticketazo.compras`), y si cambiaba de teléfono perdía todo.
--
-- Esta migración le da una cuenta. Es un usuario de auth.users igual que
-- el staff, con UNA diferencia que es toda la seguridad del asunto: NO
-- tiene fila en `perfiles`. `perfiles` es el staff; mi_organizador() y
-- mi_rol() (0002) leen de ahí, y para un comprador devuelven null. Todas
-- las policies de staff comparan contra ese null y no abren nada. Así
-- que un comprador logueado, con `authenticated` y todo, ve exactamente
-- lo mismo que `anon`: nada. La única puerta que se le abre es
-- mis_compras(), y es una función, no una policy — devuelve SUS órdenes
-- y ni una fila más.
--
-- Por qué correo + contraseña sin verificación: no hay SMTP configurado
-- (mailer_autoconfirm=false, smtp_host=null) y el registro público sigue
-- cerrado (disable_signup=true). Las cuentas las crea SOLO la Edge
-- Function `cuenta` con la admin API y email_confirm=true. Si olvidan la
-- contraseña, soporte por WhatsApp la resetea. El día que haya correo se
-- agregan verificación y recuperación.
--
-- Qué cambia:
--   1. ordenes.comprador_user_id — de quién es la compra. Nullable: las
--      compras sin cuenta siguen existiendo igual que hoy.
--   2. cuenta_intentos — un registro por intento de creación, por
--      ip_hash, para frenar a 5 por hora. Sin organizador_id a propósito:
--      una cuenta de comprador es de la plataforma, no de un cliente.
--   3. mis_compras() — lo que ve el comprador. Lo único que ve.

-- ── 1) de quién es la orden ──────────────────────────────────
-- on delete set null y no cascade: si un día se borra la cuenta, la
-- orden sigue siendo una venta que pasó. Lo que se pierde es el vínculo,
-- no la venta.
alter table ordenes add column comprador_user_id uuid references auth.users (id) on delete set null;
comment on column ordenes.comprador_user_id is
  'El comprador logueado al que pertenece la compra. Null si compró sin cuenta. '
  'Lo escribe crear-orden (si ya estaba logueado) o la Edge Function cuenta (vincular).';

-- Parcial: la mayoría de las órdenes van a seguir sin cuenta y no vale la
-- pena indexar nulls que nadie busca.
create index ordenes_comprador_user_idx on ordenes (comprador_user_id)
  where comprador_user_id is not null;

-- ── 2) el tope de creaciones ─────────────────────────────────
-- Un intento por fila. Se cuenta por ip_hash en la última hora desde la
-- Edge Function, que corre con service_role. Nadie más la lee ni la
-- escribe: ni anon ni authenticated, y esto incluye la secuencia del id,
-- que Supabase también regala por defecto.
create table cuenta_intentos (
  id         bigserial primary key,
  ip_hash    text not null,
  creado_at  timestamptz not null default now()
);
create index cuenta_intentos_ip_idx on cuenta_intentos (ip_hash, creado_at desc);

alter table cuenta_intentos enable row level security;
revoke all on cuenta_intentos from anon, authenticated;
revoke all on sequence cuenta_intentos_id_seq from anon, authenticated;

-- ── 3) mis_compras — la única ventana del comprador ─────────
-- security definer porque el comprador no tiene select sobre ordenes
-- (ni lo va a tener): la función lee por él y le devuelve SOLO las filas
-- con su auth.uid(). Sin uid (anon, o un token roto) devuelve '[]' y no
-- una excepción: es una lista vacía, no un error.
--
-- Solo las pagadas: una pendiente que después venció no es una compra, y
-- una anulada tampoco. `entradas` cuenta las que sirven para entrar —
-- valida o usada—, nunca las anuladas (los estados reales de la tabla son
-- valida / usada / anulada, ver entradas_estado_check).
--
-- Devuelve jsonb y no un set de filas por lo mismo que las estadísticas
-- (0033): PostgREST lo entrega tal cual y el front lo lee sin adivinar
-- tipos. El orden va adentro del jsonb_agg — afuera no se puede ordenar
-- un agregado.
--
-- `fecha` y `hora_inicio` salen ya formateadas (YYYY-MM-DD y HH:MM) para
-- que el navegador no tenga que interpretar un `date` o un `time` de
-- Postgres, que en JSON llegan como texto de todos modos.
create or replace function mis_compras() returns jsonb
  language sql stable security definer set search_path = public as $$
  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'id',          o.id,
        'evento',      e.nombre,
        'organizador', g.nombre,
        'org',         g.slug,
        'slug',        e.slug,
        'lugar',       e.lugar,
        'fecha',       to_char(e.fecha, 'YYYY-MM-DD'),
        'hora_inicio', to_char(e.hora_inicio, 'HH24:MI'),
        'arte_url',    e.arte_url,
        'flyer_url',   e.flyer_url,
        'entradas',    (select count(*) from entradas t
                         where t.orden_id = o.id and t.estado <> 'anulada'),
        'pagada_at',   o.pagada_at
      )
      order by e.fecha desc nulls last, o.pagada_at desc
    ),
    '[]'::jsonb)
  from ordenes o
  join eventos e       on e.id = o.evento_id
  join organizadores g on g.id = o.organizador_id
  where auth.uid() is not null
    and o.comprador_user_id = auth.uid()
    and o.estado = 'pagada'
$$;

-- La regla de la casa para funciones (0002): anon y public no ejecutan
-- nada; authenticated sí. El corte de "qué ve" no está en el grant sino
-- en el where por auth.uid().
revoke all on function mis_compras() from public, anon;
grant execute on function mis_compras() to authenticated;
