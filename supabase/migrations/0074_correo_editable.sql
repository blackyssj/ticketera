-- ============================================================
-- 0074 — el correo de contacto tambien se edita desde el panel
--
-- 0072 agrego `perfiles.email_contacto` y la pantalla de Equipo el campo
-- para cargarlo. Faltaba la mitad: 0037 le habia sacado a `authenticated`
-- el UPDATE sobre `perfiles` y se lo devolvio SOLO sobre (slug,
-- comision_entrada). Cualquier columna nueva nace sin permiso.
--
-- El sintoma no se parece a la causa: la pantalla contesta "permission
-- denied for table perfiles" y el admin, que ES admin, cree que perdio
-- permisos. No los perdio — nunca los tuvo sobre esa columna.
--
-- ── por que este grant no repite el agujero que 0037 cerro ──
--
-- Lo que 0037 protegia era `rol`, `activo` y `organizador_id`: columnas
-- que deciden QUIEN sos y QUE podes hacer. Con ellas escribibles, un
-- admin podia desactivarse a si mismo por PostgREST y quedarse afuera de
-- su propio sistema, rodeando la guardia de la Edge Function.
--
-- `email_contacto` no es de esas. Es un dato de contacto, del mismo tipo
-- que `slug` y `comision_entrada`, que ya son escribibles: parte del
-- acuerdo con el relacionador, no de sus permisos. Y no abre nada nuevo
-- —el link de venta no es secreto, se reparte a proposito, y el admin ya
-- lo ve entero en la pantalla—. La policy de 0002 sigue decidiendo QUE
-- FILAS: solo las del organizador de quien edita.
--
-- Nota para el que agregue la proxima columna a `perfiles`: si la pantalla
-- la va a escribir, hace falta el grant. Si no, no lo pongas — la lista
-- corta es la que hace que 0037 siga sirviendo.
-- ============================================================

grant update (email_contacto) on perfiles to authenticated;

comment on column perfiles.email_contacto is
  'El correo REAL de la persona, para mandarle su link de venta. Distinto de auth.users.email, que es sintetico (<usuario>@ticketera.local) y es con lo que entra al panel: tocar aquel le rompe el acceso. Nullable porque medio equipo usa solo WhatsApp. Escribible desde el panel (0074), a diferencia de rol y activo.';
