-- ============================================================
-- 0048b — las funciones públicas, calientes
--
-- Una Edge Function que nadie llamó en un rato arranca en frío, y el frío
-- se paga entero en la primera visita: el comprador que llega de WhatsApp
-- a las cuatro de la tarde, cuando hace una hora que nadie compra, espera
-- el arranque del worker más el viaje a la base. Es la peor primera
-- impresión posible y le toca justo al que no tenía por qué esperar.
--
-- Así que cada cuatro minutos se le pega a `evento` (con el evento que
-- está a la venta) y a `eventos` (la cartelera), por el mismo camino que
-- usa el navegador, para que el worker no se duerma. Es el mismo patrón
-- que `barrer_pagos` (0041): pg_cron dispara, pg_net hace el HTTP sin
-- bloquear, y el resultado queda en net._http_response por si hay que
-- mirarlo.
--
-- La cabecera `apikey` lleva la anon key. Es la misma que está en
-- app/config.js, pública por diseño: sola no abre nada en esta base (anon
-- no tiene ni un grant). Se manda para recorrer exactamente el camino del
-- navegador, no porque la función la exija. La service_role NO va acá, ni
-- en ninguna migración.
--
-- El evento es fijo a propósito (amstel/red-circle, el único a la venta).
-- Cuando cierre, la llamada va a devolver 409 "sin fase abierta" y va a
-- seguir calentando igual: lo que importa es que el worker corra, no lo
-- que conteste. Cuando haya otro evento a la venta, cambiá el slug acá o
-- dejalo: la cartelera (`eventos`) se calienta sola sin parámetros.
-- ============================================================

create extension if not exists pg_cron with schema extensions;
create extension if not exists pg_net  with schema extensions;

-- Idempotente: si la migración se corre dos veces, no quedan dos jobs.
select cron.unschedule(jobid) from cron.job
 where jobname in ('calentar_evento', 'calentar_eventos');

select cron.schedule('calentar_evento', '*/4 * * * *', $$
  select net.http_get(
    url     := 'https://mjotxzcddhqqpuhkcetl.supabase.co/functions/v1/evento',
    params  := jsonb_build_object('organizador', 'amstel', 'evento', 'red-circle'),
    headers := jsonb_build_object(
                 'apikey', 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im1qb3R4emNkZGhxcXB1aGtjZXRsIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODc4NTk2NzMsImV4cCI6MjEwMzQzNTY3M30.yym969pECvbp_01-vM4d5QCVEvUV_kPUmNhtp51a0g0'),
    timeout_milliseconds := 20000)
$$);

select cron.schedule('calentar_eventos', '*/4 * * * *', $$
  select net.http_get(
    url     := 'https://mjotxzcddhqqpuhkcetl.supabase.co/functions/v1/eventos',
    headers := jsonb_build_object(
                 'apikey', 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im1qb3R4emNkZGhxcXB1aGtjZXRsIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODc4NTk2NzMsImV4cCI6MjEwMzQzNTY3M30.yym969pECvbp_01-vM4d5QCVEvUV_kPUmNhtp51a0g0'),
    timeout_milliseconds := 20000)
$$);
