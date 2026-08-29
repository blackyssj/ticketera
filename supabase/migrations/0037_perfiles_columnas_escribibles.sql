-- ============================================================
-- 0037 — el navegador solo escribe dos columnas de `perfiles`
--
-- La pantalla de Equipo (0036 del lado de la app) manda `rol` y `activo`
-- por la Edge Function `equipo`, que verifica quién llama y se niega a que
-- un admin se desactive o se baje el rol a sí mismo. Esa guardia estaba
-- solo ahí.
--
-- Y ahí no alcanza. La policy de 0002 le da al admin `for all` sobre las
-- filas de su organizador, incluida la suya: con la consola del navegador
-- abierta podía hacerse `activo = false` por PostgREST, sin pasar por la
-- función, y quedarse afuera de su propio sistema sin nadie que lo vuelva
-- a entrar. Un `if` del lado del servidor que se puede rodear por otra
-- puerta no es una guardia, es una sugerencia.
--
-- El arreglo no es tapar ese caso: es cerrar la puerta. `authenticated`
-- pierde el UPDATE sobre la tabla y lo recupera **solo sobre las dos
-- columnas que la pantalla realmente edita**, que son las del acuerdo
-- comercial con un relacionador. `rol`, `activo` y `organizador_id` dejan
-- de ser escribibles desde un navegador, por cualquiera y sobre cualquier
-- fila. Quedan en manos de la función, que corre con service_role — a esa
-- los grants por columna no la tocan.
--
-- Se van también INSERT y DELETE: una cuenta se crea en `auth.users` antes
-- que en `perfiles`, así que un insert suelto desde el navegador solo
-- puede dejar un perfil huérfano; y borrar a alguien con ventas hechas
-- rompe el historial de comisiones — por eso la pantalla desactiva en vez
-- de borrar. La policy de 0002 sigue donde está: filtra QUÉ filas, esto
-- decide QUÉ columnas, y hacen falta las dos.
-- ============================================================

revoke insert, update, delete on perfiles from authenticated;

grant update (slug, comision_entrada) on perfiles to authenticated;

comment on column perfiles.rol is
  'Solo lo escribe la Edge Function `equipo`, con service_role. Desde el
   navegador no es escribible: 0037 le sacó el UPDATE a authenticated sobre
   todo lo que no sea slug y comision_entrada.';
comment on column perfiles.activo is
  'Baja lógica. Nunca se borra una persona con ventas: se pierde la prueba
   de cuánto vendió. Solo lo escribe la Edge Function `equipo`.';
