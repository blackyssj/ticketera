-- ============================================================
-- 0083 — el cierre del día se gira a las 07:00, no a medianoche
--
-- 0077 lo puso a las 00:00 porque el cliente lo pidió así. Duró una
-- noche: el BCP rechazó los dos giros de las 00:00 con "Fuera de
-- horario" (código 01), la red de las 08:00 los sacó, y en el medio
-- Francisco vio la fila roja de RECHAZADO en el panel y creyó que había
-- un error de monto. No lo había. Había un banco cerrado.
--
-- Un intento que rebota todas las noches no es un giro: es una fila
-- roja diaria que hay que explicar. Se saca.
--
-- El cliente pide las 07:00 de la mañana siguiente. No hay evidencia de
-- que a las 07:00 el BCP ya procese —los giros que salieron fueron entre
-- las 08:00 y las 09:45, y uno a las 23:00— así que las 07:00 quedan
-- como el intento y las 09:00 y 11:00 como la red. Si a las 07:00 está
-- cerrado, la plata sale a las 09:00, que es una hora probada. Si está
-- abierto, mejor: sale a las 07:00 y las otras dos no hacen nada, por la
-- guardia de un giro por día de 0076.
--
-- 11, 13 y 15 UTC = 07:00, 09:00 y 11:00 de La Paz (pg_cron corre en GMT).
-- ============================================================

select cron.alter_job(jobid, schedule := '0 11,13,15 * * *')
  from cron.job where jobname = 'pago_automatico';

-- ── control ─────────────────────────────────────────────────
select * from chequeo_funciones_sin_guardia();
