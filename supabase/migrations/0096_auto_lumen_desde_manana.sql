-- ============================================================
-- 0096 — el giro automático de LÜMEN arranca el 03/10 a las 08:00
--
-- El 02/10 se prendió el giro diario de LÜMEN (a la cuenta de Francisco
-- Aguilera) a las 11:00, una hora antes del último intento del día
-- (12:00). Ese día el dueño liquida todo a mano —lo del cliente y la
-- ganancia—, así que el automático se apaga hasta mañana para que no gire
-- los 38.880 Bs por su cuenta en el medio.
--
-- Lo vuelve a prender un trabajo de una sola vez el 03/10 a las 07:50 de
-- La Paz (11:50 UTC), diez minutos antes del giro de las 08:00, y se
-- borra a sí mismo. Va en una migración y no a mano porque los crons
-- viven acá (CLAUDE.md, regla 3): si no está en el repo, no existe.
-- ============================================================

update organizadores set pago_automatico = false where slug = 'lumen';

select cron.schedule('activar_auto_lumen', '50 11 3 10 *', $job$
  update organizadores set pago_automatico = true where slug = 'lumen';
  select cron.unschedule('activar_auto_lumen');
$job$);

-- ── control ─────────────────────────────────────────────────
select * from chequeo_funciones_sin_guardia();
