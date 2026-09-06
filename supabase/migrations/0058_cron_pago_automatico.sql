-- ============================================================
-- 0058 — el reloj que le manda la plata al organizador
--
-- 0057 dejó todo listo menos quién aprieta. Esto es quién: cada quince
-- minutos, `liquidar` en modo automático recorre los organizadores que
-- tienen el interruptor puesto y manda lo que hoy pasa su mínimo.
--
-- ── por qué quince minutos y no uno ──────────────────────────
--
-- La cadena entera ya tiene sus propios tiempos: el barrido de pagos
-- corre cada minuto y el job del monedero de BeePay cada dos. Bajar de
-- ahí no hace que la plata llegue antes, porque lo que manda es el
-- eslabón más lento. Y cada corrida que encuentra plata es una
-- transferencia bancaria de verdad: a un minuto, una feria vendiendo
-- fuerte dispararía sesenta por hora. El piso por organizador
-- (`pago_auto_minimo`) es el otro freno, y los dos juntos son lo que
-- hace que esto sea "rápido" y no "constante".
--
-- Con quince minutos, el peor caso entre que alguien compra la entrada y
-- el organizador tiene la plata en camino es del orden de veinte minutos.
-- Para un rubro donde lo normal es cobrar a los treinta días, eso ya no
-- es una mejora de tiempo: es otra categoría.
--
-- ── por qué manda las dos cabeceras ──────────────────────────
--
-- `liquidar` tiene verify_jwt puesto, porque el camino normal es una
-- persona apretando un botón en el panel. La reja del gateway exige
-- entonces ALGÚN token firmado por el proyecto, y la anon key es uno: va
-- para pasar esa reja y nada más. La que decide de verdad es `x-auto`,
-- que la función compara en tiempo constante contra su secret. Sin ella,
-- lo que llega con la anon key muere en el chequeo de "esto no es una
-- persona".
--
-- El secreto NO se crea acá, igual que en 0054: ponerlo en una migración
-- es ponerlo en el repo. En un proyecto nuevo se carga una vez, con el
-- mismo valor que el secret AUTO_CLAVE de las Edge Functions:
--
--     select vault.create_secret('<valor>', 'auto_clave');
--
-- Si falta, el cron manda la cabecera vacía y la función contesta 401: no
-- paga de más, no paga nada. Falla del lado seguro.
--
-- Idempotente: desprograma por jobid si ya existe y vuelve a programar.
-- ============================================================

select cron.unschedule(jobid) from cron.job where jobname = 'pago_automatico';

select cron.schedule('pago_automatico', '*/15 * * * *', $cron$
  select net.http_post(
    url     := 'https://mjotxzcddhqqpuhkcetl.supabase.co/functions/v1/liquidar',
    headers := jsonb_build_object(
                 'Content-Type',  'application/json',
                 'apikey',        'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im1qb3R4emNkZGhxcXB1aGtjZXRsIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODc4NTk2NzMsImV4cCI6MjEwMzQzNTY3M30.yym969pECvbp_01-vM4d5QCVEvUV_kPUmNhtp51a0g0',
                 'Authorization', 'Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im1qb3R4emNkZGhxcXB1aGtjZXRsIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODc4NTk2NzMsImV4cCI6MjEwMzQzNTY3M30.yym969pECvbp_01-vM4d5QCVEvUV_kPUmNhtp51a0g0',
                 'x-auto',        coalesce((select decrypted_secret from vault.decrypted_secrets
                                             where name = 'auto_clave'), '')),
    body    := '{}'::jsonb,
    timeout_milliseconds := 55000)
$cron$);
