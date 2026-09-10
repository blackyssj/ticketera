-- ============================================================
-- 0084 — tres permisos que nadie usaba y que abrían la caja
--
-- Salen de un audit del 10/09: siete agentes buscando por ángulo, tres
-- escépticos por hallazgo. Estos tres sobrevivieron y se verificaron a
-- mano antes de escribir esto. Cada uno es una línea, y ninguno lo usa
-- el panel: todas las escrituras legítimas ya pasan por funciones con
-- guardia. Se cierra lo que estaba abierto por omisión.
--
-- ── 1. UPDATE sobre ordenes ──
--
-- `authenticated` tenía UPDATE sobre TODAS las columnas de `ordenes`. Con
-- RLS eso acota al propio organizador, pero el propio organizador es el
-- problema: un admin de un cliente, desde la consola del navegador con
-- su sesión, le sube el subtotal a una orden pagada o pasa una vencida a
-- 'pagada'. `disponible_de` suma esas mismas columnas, y el giro de la
-- mañana le manda plata que no vendió — plata que sale del monedero
-- común, o sea de los otros clientes y de nuestra comisión. La migración
-- 0038 ya sabía que la tabla era editable a mano (lo dice un comentario)
-- y no la cerró. El panel nunca hizo un update directo: crear_orden,
-- emitir_orden, vencer_ordenes y anular corren como security definer.
--
-- ── 2. INSERT sobre puerta_bitacora ──
--
-- 0034 le dio INSERT a `authenticated` para que la puerta pudiera anotar.
-- Pero la puerta anota desde funciones (validar_entrada, deshacer,
-- sincronizar_puerta), no desde el cliente. Lo que quedaba abierto era
-- que cualquier portero escriba a mano la bitácora con la hora y el
-- evento que quiera: ensuciar justo la herramienta que sirve para saber
-- quién dejó pasar a quién, firmada por el auditado.
--
-- ── 3. es_plataforma() y el operador dado de baja ──
--
-- La única baja que ofrece el panel (Equipo → desactivar) pone
-- perfiles.activo en false, y todas las guardias del tenant lo miran.
-- es_plataforma() no lo miraba: un ex-operador de TICKETAZO, con su
-- clave de siempre desde una terminal, seguía viendo ventas, cobros,
-- giros y cuentas bancarias de TODOS los clientes, y podía disparar
-- giros. Ahora la baja lo saca también de plataforma.
-- ============================================================

-- 1.
revoke update on ordenes from authenticated;

-- 2.
revoke insert on puerta_bitacora from authenticated;

-- 3.
create or replace function es_plataforma() returns boolean
  language sql stable security definer set search_path = public as $$
  select exists (select 1 from plataforma_operador po
                   join perfiles p on p.id = po.perfil_id and p.activo
                  where po.perfil_id = auth.uid())
$$;

-- ── control ─────────────────────────────────────────────────
select * from chequeo_funciones_sin_guardia();
