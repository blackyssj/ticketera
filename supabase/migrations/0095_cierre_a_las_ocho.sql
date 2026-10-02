-- ============================================================
-- 0095 — el giro diario sale a las 08:00, con red a las 10:00 y 12:00
--
-- 0083 lo había puesto a las 07:00 por pedido de Distrito Ferial. El
-- 02/10, con LÜMEN y Latina sumándose al giro automático, el pedido es
-- cortar a las 08:00: es la hora desde la que los giros salieron siempre
-- bien del lado del BCP (0076 ya lo decía: los que pasaron fueron entre
-- las 08:00 y las 09:45). Las 10:00 y 12:00 quedan de red: la guardia de
-- un giro automático por día de 0076 hace que el primero que sale apague
-- a los otros dos, y un rechazo no gasta el día.
--
-- 12, 14 y 16 UTC = 08:00, 10:00 y 12:00 de La Paz (pg_cron corre en GMT).
-- ============================================================

select cron.alter_job(jobid, schedule := '0 12,14,16 * * *')
  from cron.job where jobname = 'pago_automatico';

-- ── control ─────────────────────────────────────────────────
select * from chequeo_funciones_sin_guardia();
