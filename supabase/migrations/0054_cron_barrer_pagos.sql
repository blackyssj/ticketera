-- ============================================================
-- 0054 — el barrido de pagos, por fin escrito
--
-- `barrer_pagos` corre cada minuto desde agosto y nunca estuvo en una
-- migración: se creó a mano contra la base y vivía sólo ahí. Es el trabajo
-- que rescata al comprador que pagó y cerró la pestaña antes de volver de
-- la pasarela — sin él, esa plata queda cobrada y la entrada sin emitir.
--
-- El problema no era el desorden: era que este archivo, más los otros 53,
-- son lo único que puede reconstruir el sistema. Un proyecto nuevo armado
-- corriendo las migraciones habría quedado sin barrido, andando bien y en
-- silencio, hasta que alguien reclamara que pagó y no tiene entrada.
--
-- ── por qué la clave sale del vault ──────────────────────────
--
-- La función `barrer-pagos` exige la cabecera `x-barrido`, y el comando
-- del cron la llevaba escrita en texto plano. Traerla acá tal cual habría
-- puesto el secreto en el repo, que es peor que no tener la migración.
-- Así que el comando la lee del vault en cada corrida.
--
-- El secreto NO se crea acá, por lo mismo. En un proyecto nuevo hay que
-- cargarlo una vez, con el mismo valor que el secret BARRIDO_CLAVE de las
-- Edge Functions:
--
--     select vault.create_secret('<valor>', 'barrido_clave');
--
-- Si falta, el cron manda la cabecera vacía y la función contesta 403: no
-- emite de más, simplemente no hace nada. Falla del lado seguro.
--
-- La `apikey` sí va escrita: es la anon key, pública por diseño y ya
-- presente en app/config.js. Sola no abre nada — anon no tiene un solo
-- grant en esta base. Va para recorrer el mismo camino que el navegador.
-- La service_role NO va acá ni en ninguna migración.
--
-- Idempotente: desprograma por jobid si ya existe (unschedule por nombre
-- revienta cuando no está) y vuelve a programar.
-- ============================================================

select cron.unschedule(jobid) from cron.job where jobname = 'barrer_pagos';

select cron.schedule('barrer_pagos', '* * * * *', $cron$
  select net.http_post(
    url     := 'https://mjotxzcddhqqpuhkcetl.supabase.co/functions/v1/barrer-pagos',
    headers := jsonb_build_object(
                 'Content-Type', 'application/json',
                 'apikey',       'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im1qb3R4emNkZGhxcXB1aGtjZXRsIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODc4NTk2NzMsImV4cCI6MjEwMzQzNTY3M30.yym969pECvbp_01-vM4d5QCVEvUV_kPUmNhtp51a0g0',
                 'x-barrido',    coalesce((select decrypted_secret from vault.decrypted_secrets
                                            where name = 'barrido_clave'), '')),
    body    := '{}'::jsonb,
    timeout_milliseconds := 20000)
$cron$);
