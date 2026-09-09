-- ============================================================
-- 0077 — el cierre del día se gira a medianoche
--
-- 0076 puso el giro diario a la mañana siguiente, con el argumento de que
-- el BCP rechaza fuera de horario. El cliente pide que salga a las 00:00
-- de La Paz, apenas cierra el día: quiere que la plata de la noche esté
-- en camino cuando cierra la boletería, no ocho horas después.
--
-- Es su decisión y su plata, así que se hace. Lo que NO se hace es
-- dejarlo colgando de un solo intento: si el banco está fuera de horario
-- a esa hora, un único disparo a las 00:00 deja al cliente esperando
-- veinticuatro horas, que es peor que las ocho que quería ahorrarse.
--
-- Entonces el reloj queda en 04, 12 y 14 UTC = 00:00, 08:00 y 10:00 de
-- La Paz. La medianoche es el giro; las dos de la mañana son la red.
-- Como la guardia de 0076 cuenta un solo pago no rechazado por día
-- calendario de La Paz, y el de las 00:00 cae en el MISMO día que los de
-- las 08:00 y 10:00, cuando la medianoche sale bien las otras dos
-- corridas no hacen nada. Sólo entran si el banco rebotó.
--
-- El monto sigue siendo el mismo de siempre: todo lo acumulado desde el
-- giro anterior, o sea la venta del día que acaba de cerrar.
-- ============================================================

select cron.alter_job(jobid, schedule := '0 4,12,14 * * *')
  from cron.job where jobname = 'pago_automatico';

-- ── control ─────────────────────────────────────────────────
select * from chequeo_funciones_sin_guardia();
