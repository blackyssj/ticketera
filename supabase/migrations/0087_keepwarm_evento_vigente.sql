-- ============================================================
-- 0087 — el keep-warm de `evento` sigue al evento que está a la venta
--
-- 0048b dejó el slug fijo en amstel/red-circle. Ese evento cerró y desde
-- entonces el cron pega 404 cada cuatro minutos: ~360 errores por día en
-- los logs que tapan cualquier 404 real. El worker se calentaba igual,
-- pero el ruido cuesta más de lo que vale.
--
-- Ahora el job busca en cada disparo el evento publicado más próximo
-- (hoy o futuro) y le pega a ese. Si no hay ninguno, pega a la cartelera
-- —que devuelve 200 siempre— y el worker de `evento` se enfría, que es
-- lo correcto cuando no hay nada a la venta.
-- ============================================================

select cron.unschedule(jobid) from cron.job where jobname = 'calentar_evento';

select cron.schedule('calentar_evento', '*/4 * * * *', $$
  select net.http_get(
    url     := 'https://mjotxzcddhqqpuhkcetl.supabase.co/functions/v1/evento',
    params  := coalesce(
                 (select jsonb_build_object('organizador', o.slug, 'evento', e.slug)
                    from eventos e join organizadores o on o.id = e.organizador_id
                   where e.estado = 'publicado' and o.activo
                     and e.fecha >= (now() at time zone 'America/La_Paz')::date - 1
                   order by e.fecha, e.hora_inicio limit 1),
                 '{}'::jsonb),
    headers := jsonb_build_object(
                 'apikey', 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im1qb3R4emNkZGhxcXB1aGtjZXRsIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODc4NTk2NzMsImV4cCI6MjEwMzQzNTY3M30.yym969pECvbp_01-vM4d5QCVEvUV_kPUmNhtp51a0g0'),
    timeout_milliseconds := 20000)
$$);

select * from chequeo_funciones_sin_guardia();
