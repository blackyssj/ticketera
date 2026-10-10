-- Espejo de Plataforma Puerta (0103), de punta a punta, contra la base real.
--
-- Es UN solo bloque y termina SIEMPRE en una excepción: 'TEST_OK …' si todo
-- anduvo, 'TEST_FAIL …' (o el error que sea) si no. Así no queda nada
-- escrito pase lo que pase: ni los eventos de prueba, ni la orden, ni el
-- usuario. Se corre DESPUÉS de aplicar 0103:
--
--     python3 scripts/sql.py supabase/tests/puerta_espejo.sql
--
-- La salida esperada es un FALLO con el texto "TEST_OK: …". Cualquier otra
-- cosa es un error de verdad.
--
-- No llama a Puerta: lo que haría Puerta se escribe a mano en JSON, con la
-- forma exacta del contrato (accion "eventos" / "estados" / respuestas de
-- "entradas" y "anular").
--
-- Ojo al correrlo con el espejo andando: puerta_tomar_envios toma TODA la
-- cola pendiente, también filas reales. Quedan tomadas solo mientras dura
-- este bloque (unos segundos) y vuelven como estaban con el rollback; el
-- cron las saltea mientras tanto (skip locked) y las manda al minuto.
do $$
declare
  v_hoy     date := (now() at time zone 'America/La_Paz')::date;
  v_fecha   date := (now() at time zone 'America/La_Paz')::date + 6;
  v_ev1     uuid := gen_random_uuid();   -- Bowie, precio único (como Crush)
  v_ev2     uuid := gen_random_uuid();   -- BurTown, por fases (como el aniversario)
  v_ev3     uuid := gen_random_uuid();   -- antes del corte
  v_ev4     uuid := gen_random_uuid();   -- la venta abre en dos días
  v_ev5     uuid := gen_random_uuid();   -- precio 0 en Puerta
  v_otro    uuid := gen_random_uuid();   -- un evento de Bowie que NO es espejo
  v_fa      uuid := gen_random_uuid();
  v_fb      uuid := gen_random_uuid();
  v_fc      uuid := gen_random_uuid();
  v_admin   uuid := gen_random_uuid();
  v_mesa    uuid;
  v_bowie   uuid; v_burtown uuid;
  v_j1 jsonb; v_j2 jsonb; v_j2b jsonb; v_j2c jsonb; v_j3 jsonb; v_j4 jsonb; v_j5 jsonb;
  v_r jsonb; v_lote jsonb; v_res jsonb; v_fases jsonb;
  v_e eventos; v_pe puerta_evento;
  v_tipo uuid; v_online uuid; v_orden uuid; v_orden2 uuid; v_slug text;
  v_a uuid; v_b uuid; v_x uuid; v_y uuid; v_code_a text; v_code_b text;
  v_id_a bigint; v_id_b bigint;
  v_n int; v_ok boolean; v_txt text;
begin
  -- ── 0. lo que dejó la migración ──
  select id into v_bowie from organizadores
   where slug = 'bowie' and nombre = 'Bowie' and activo and fee_pct = 0
     and fee_fijo_transaccion = 0 and fee_piso = 0 and comision_modo = 'sobre'
     and comercio_id is not null and not pago_automatico and anticipo_pct = 0;
  select id into v_burtown from organizadores
   where slug = 'burtown' and nombre = 'BurTown' and activo and fee_pct = 0
     and fee_fijo_transaccion = 0 and fee_piso = 0 and comision_modo = 'sobre';
  if v_bowie is null or v_burtown is null then
    raise exception 'TEST_FAIL: faltan los organizadores bowie/burtown sin cargo';
  end if;
  if not exists (select 1 from cron.job where jobname = 'puerta_sync') then
    raise exception 'TEST_FAIL: falta el cron puerta_sync';
  end if;
  -- Ninguna función de la base puede fijar un parámetro propio en su
  -- definición: en Supabase eso es de superusuario y la migración no aplica.
  select string_agg(p.proname, ', ') into v_txt
    from pg_proc p
   where p.pronamespace = 'public'::regnamespace
     and exists (select 1 from unnest(p.proconfig) c where c like 'ticketazo.%');
  if v_txt is not null then raise exception 'TEST_FAIL: funciones con SET de un parámetro propio: %', v_txt; end if;

  -- Corte en hoy para que las fechas de prueba (dentro de 6 días) entren
  -- aunque esto se corra antes del 11/10. Se deshace con todo lo demás.
  update puerta_config set desde = v_hoy, activo = true, filtro_espera = interval '5 minutes' where id;

  -- ── 1. un evento sin fases, tal como lo manda Puerta ──
  v_j1 := jsonb_build_object(
    'id', v_ev1, 'club_id', 'bowie', 'nombre', 'Crush Ñandú', 'fecha', v_fecha,
    'hora_inicio', '21:00:00', 'hora_fin', '06:00:00', 'edad_min', 18,
    'precio_manilla', 60, 'venta_por_fases', false,
    'manilla_desde', null,
    'manilla_hasta_ts', to_jsonb((v_fecha + time '23:30') at time zone 'America/La_Paz'),
    'manilla_hasta', null, 'entrada_hasta', null, 'estado', 'proximo',
    'ticket_url', 'https://kdkjmqrbiszmkcprinir.supabase.co/storage/v1/object/public/tickets/prueba.png?v=1',
    'flyer_url', null, 'cut_rrpp', 15, 'fases', '[]'::jsonb);

  v_r := puerta_aplicar_eventos(jsonb_build_array(v_j1), v_hoy - 1);
  if (v_r->>'creados')::int <> 1 then raise exception 'TEST_FAIL: no se creó el espejo: %', v_r; end if;
  if puerta_sync_activo() then
    raise exception 'TEST_FAIL: el permiso del sync quedó prendido después de aplicar eventos';
  end if;

  select * into v_e from eventos where id = v_ev1;
  if v_e.organizador_id <> v_bowie or v_e.estado <> 'publicado' or not v_e.listado
     or v_e.slug <> 'crush-nandu' or v_e.comision_entrada <> 0 or v_e.lugar <> 'Bowie'
     or v_e.arte_url <> v_j1->>'ticket_url' or v_e.rrpp_por_defecto is not null then
    raise exception 'TEST_FAIL: el espejo quedó mal: %', to_jsonb(v_e);
  end if;
  select * into v_pe from puerta_evento where evento_id = v_ev1;
  v_tipo := v_pe.tipo_id; v_online := v_pe.fase_online;
  if not exists (select 1 from tipo_entrada where id = v_tipo and nombre = 'General'
                  and manillas = 1 and activo and en_cartelera)
     or (select count(*) from tipo_entrada where evento_id = v_ev1) <> 1 then
    raise exception 'TEST_FAIL: el tipo General no quedó bien';
  end if;
  if not exists (select 1 from evento_fase where id = v_online and evento_id = v_ev1
                  and nombre = 'Online' and activo and orden = 0 and desde is null
                  and hasta = (v_fecha + time '23:30') at time zone 'America/La_Paz')
     or (select count(*) from evento_fase where evento_id = v_ev1) <> 1
     or not exists (select 1 from fase_precio where fase_id = v_online and tipo_id = v_tipo
                     and precio = 60 and cupo is null) then
    raise exception 'TEST_FAIL: la fase Online no quedó bien';
  end if;

  v_r := evento_publico('bowie', 'crush-nandu');
  if v_r ? 'falta' or (v_r->>'sin_venta')::boolean
     or (v_r->'precios'->0->>'precio')::numeric <> 60
     or (v_r->'organizador'->>'fee_pct')::numeric <> 0 then
    raise exception 'TEST_FAIL: la página pública no vende el espejo: %', v_r;
  end if;
  if not exists (select 1 from jsonb_array_elements(cartelera_publica()) x
                  where x->>'id' = v_ev1::text) then
    raise exception 'TEST_FAIL: el espejo no está en la cartelera';
  end if;

  -- La misma versión otra vez: no se toca nada.
  v_r := puerta_aplicar_eventos(jsonb_build_array(v_j1), v_hoy - 1);
  if (v_r->>'iguales')::int <> 1 then raise exception 'TEST_FAIL: reescribió sin cambios: %', v_r; end if;

  -- Imágenes de afuera del Storage de Puerta: se ignoran, queda la que había.
  v_r := puerta_aplicar_eventos(jsonb_build_array(v_j1 || jsonb_build_object(
           'ticket_url', 'https://otro.host/x.svg', 'flyer_url', 'javascript:alert(1)')), v_hoy - 1);
  if (select arte_url from eventos where id = v_ev1) is distinct from v_j1->>'ticket_url'
     or (select flyer_url from eventos where id = v_ev1) is not null then
    raise exception 'TEST_FAIL: se copió una imagen de afuera del Storage de Puerta: %', v_r;
  end if;
  v_r := puerta_aplicar_eventos(jsonb_build_array(v_j1), v_hoy - 1);

  -- ── 1b. la venta abre en dos días: la página igual se ve ──
  v_j4 := v_j1 || jsonb_build_object('id', v_ev4, 'nombre', 'Crush Ñandú',
    'fecha', v_fecha + 1,
    'manilla_desde', to_jsonb(now() + interval '2 days'),
    'manilla_hasta_ts', to_jsonb((v_fecha + 1 + time '23:30') at time zone 'America/La_Paz'));
  v_r := puerta_aplicar_eventos(jsonb_build_array(v_j1, v_j4), v_hoy - 1);
  select slug into v_slug from eventos where id = v_ev4;
  if v_slug is distinct from 'crush-nandu-' || to_char(v_fecha + 1, 'DD-MM') then
    raise exception 'TEST_FAIL: el desempate del slug por fecha dio %', v_slug;
  end if;
  v_r := evento_publico('bowie', v_slug);
  if v_r ? 'falta' or not (v_r->>'sin_venta')::boolean
     or v_r->'fases'->0->>'estado' <> 'proxima' then
    raise exception 'TEST_FAIL: con la venta por abrir la página no se ve: %', v_r;
  end if;
  if not exists (select 1 from jsonb_array_elements(cartelera_publica()) x
                  where x->>'id' = v_ev4::text and x->>'abre' is not null) then
    raise exception 'TEST_FAIL: la fecha con venta por abrir no está en la cartelera';
  end if;

  -- ── 1c. precio 0 en Puerta: no se vende acá ──
  v_j5 := v_j1 || jsonb_build_object('id', v_ev5, 'nombre', 'Noche Free',
    'fecha', v_fecha + 2, 'precio_manilla', 0,
    'manilla_hasta_ts', to_jsonb((v_fecha + 2 + time '23:30') at time zone 'America/La_Paz'));
  v_r := puerta_aplicar_eventos(jsonb_build_array(v_j1, v_j4, v_j5), v_hoy - 1);
  if not (v_r->'sin_precio') @> to_jsonb(array[v_ev5::text])
     or exists (select 1 from evento_fase where evento_id = v_ev5 and activo)
     or fase_vigente(v_ev5) is not null then
    raise exception 'TEST_FAIL: un precio 0 de Puerta quedó a la venta: %', v_r;
  end if;
  if not (evento_publico('bowie', 'noche-free') ? 'falta')
     or exists (select 1 from jsonb_array_elements(cartelera_publica()) x
                 where x->>'id' = v_ev5::text) then
    raise exception 'TEST_FAIL: la noche a Bs 0 se muestra como vendible';
  end if;

  -- ── 2. la compra: precio de Puerta, cargo cero, y a la cola ──
  v_r := crear_orden(v_ev1, jsonb_build_array(jsonb_build_object('tipo_id', v_tipo, 'cantidad', 2)),
                     '{"nombre":"Comprador Prueba","email":"comprador@prueba.test"}'::jsonb);
  if (v_r->>'total')::numeric <> 120 or (v_r->>'fee')::numeric <> 0 then
    raise exception 'TEST_FAIL: el comprador no paga exactamente el precio de Puerta: %', v_r;
  end if;
  v_orden := (v_r->>'orden')::uuid;
  if exists (select 1 from puerta_envio where evento_id = v_ev1) then
    raise exception 'TEST_FAIL: se encoló una orden sin pagar';
  end if;

  v_r := emitir_orden(v_orden, 120, 'SIM-PRUEBA-PUERTA');
  if not (v_r->>'ok')::boolean then raise exception 'TEST_FAIL: no emitió: %', v_r; end if;
  select count(*) into v_n from puerta_envio
   where evento_id = v_ev1 and tipo = 'entrada' and estado = 'pendiente';
  if v_n <> 2 then raise exception 'TEST_FAIL: se esperaban 2 entradas en la cola, hay %', v_n; end if;

  -- ── 3. tomar la cola, como puerta-sync ──
  v_lote := puerta_tomar_envios('entrada', 200);
  select jsonb_agg(x order by (x->>'id')::bigint) into v_lote from jsonb_array_elements(v_lote) x
   where x->>'evento_id' = v_ev1::text;
  if jsonb_array_length(coalesce(v_lote, '[]')) <> 2 then
    raise exception 'TEST_FAIL: tomar no devolvió las 2: %', v_lote;
  end if;
  if exists (select 1 from jsonb_array_elements(v_lote) x
              where (x->>'precio')::numeric <> 60 or x->>'fase_id' is not null
                 or x->>'cliente' <> 'Comprador Prueba' or (x->>'forzar_precio')::boolean
                 or not exists (select 1 from entradas e where e.id = (x->>'ref')::uuid
                                  and e.code = x->>'code')) then
    raise exception 'TEST_FAIL: el lote para Puerta trae datos raros: %', v_lote;
  end if;
  -- Una segunda corrida al mismo tiempo no se lleva las mismas.
  if exists (select 1 from jsonb_array_elements(puerta_tomar_envios('entrada', 200)) x
              where x->>'evento_id' = v_ev1::text) then
    raise exception 'TEST_FAIL: dos corridas tomaron la misma entrada';
  end if;

  v_a := (v_lote->0->>'ref')::uuid; v_b := (v_lote->1->>'ref')::uuid;
  v_id_a := (v_lote->0->>'id')::bigint; v_id_b := (v_lote->1->>'id')::bigint;
  select code into v_code_a from entradas where id = v_a;
  select code into v_code_b from entradas where id = v_b;

  -- Una entra; la otra rebota porque en Puerta subieron el precio después
  -- de la reserva: vuelve a la cola sola, con forzar_precio.
  v_r := puerta_registrar_envios(jsonb_build_array(
    jsonb_build_object('id', v_id_a, 'resultado', 'creada', 'puerta_id', gen_random_uuid()),
    jsonb_build_object('id', v_id_b, 'resultado', 'rechazada',
                       'motivo', 'precio_distinto: TICKETAZO 60, Puerta 70')));
  if (v_r->>'hechos')::int <> 1 or (v_r->>'forzados')::int <> 1
     or not exists (select 1 from puerta_envio where id = v_id_b and estado = 'pendiente'
                     and forzar_precio and ultimo_error like 'precio_distinto%'
                     and proximo_at <= clock_timestamp()) then
    raise exception 'TEST_FAIL: un precio_distinto no volvió a la cola forzado: %', v_r;
  end if;
  v_lote := puerta_tomar_envios('entrada', 200);
  select jsonb_agg(x) into v_lote from jsonb_array_elements(v_lote) x where x->>'evento_id' = v_ev1::text;
  if jsonb_array_length(coalesce(v_lote, '[]')) <> 1 or v_lote->0->>'ref' <> v_b::text
     or not (v_lote->0->>'forzar_precio')::boolean then
    raise exception 'TEST_FAIL: el reenvío no va con forzar_precio: %', v_lote;
  end if;
  -- Forzada y rebotada otra vez: no se fuerza dos veces, la mira una persona…
  v_r := puerta_registrar_envios(jsonb_build_array(jsonb_build_object('id', v_id_b,
           'resultado', 'rechazada', 'motivo', 'precio_distinto: TICKETAZO 60, Puerta 70')));
  if (v_r->>'rechazados')::int <> 1
     or not exists (select 1 from puerta_envio where id = v_id_b and estado = 'rechazado') then
    raise exception 'TEST_FAIL: se forzó dos veces: %', v_r;
  end if;
  -- …y la reencola a mano como dice la migración.
  update puerta_envio set estado = 'pendiente', forzar_precio = true,
         proximo_at = clock_timestamp() where id = v_id_b;
  v_lote := puerta_tomar_envios('entrada', 200);
  select jsonb_agg(jsonb_build_object('id', (x->>'id')::bigint, 'resultado', 'creada',
                                      'puerta_id', gen_random_uuid()))
    into v_res from jsonb_array_elements(v_lote) x where x->>'ref' = v_b::text;
  v_r := puerta_registrar_envios(v_res);
  if (v_r->>'hechos')::int <> 1 then raise exception 'TEST_FAIL: registrar: %', v_r; end if;

  if not (puerta_estado_sync()->'estados') @> to_jsonb(array[v_ev1]) then
    raise exception 'TEST_FAIL: el espejo con entradas en Puerta no se consulta: %', puerta_estado_sync();
  end if;

  -- ── 4. lo que pasó en la puerta de allá ──
  -- a entró. b la acaba de marcar Seguridad: todavía nada (puede ser una
  -- doble lectura, o entrar en segundos).
  v_r := puerta_aplicar_estados(jsonb_build_array(
    jsonb_build_object('ref', v_a, 'code', v_code_a, 'estado', 'usada',
                       'used_at', now(), 'filtrada', false, 'filtrada_at', null),
    jsonb_build_object('ref', v_b, 'code', v_code_b, 'estado', 'valida',
                       'used_at', null, 'filtrada', true, 'filtrada_at', now())));
  if (select estado from entradas where id = v_a) <> 'usada'
     or (select estado from entradas where id = v_b) <> 'valida'
     or exists (select 1 from puerta_envio where entrada_id = v_b and tipo = 'anular') then
    raise exception 'TEST_FAIL: estados mal aplicados (o el filtro actuó sin esperar): %', v_r;
  end if;
  if puerta_sync_activo() then
    raise exception 'TEST_FAIL: el permiso del sync quedó prendido después de aplicar estados';
  end if;
  -- La marca sigue puesta pasada la espera: sale la anulación HACIA Puerta,
  -- y acá la entrada sigue válida hasta que Puerta confirme.
  v_r := puerta_aplicar_estados(jsonb_build_array(
    jsonb_build_object('ref', v_b, 'code', v_code_b, 'estado', 'valida',
                       'filtrada', true, 'filtrada_at', now() - interval '10 minutes')));
  if (v_r->>'filtradas_a_anular')::int <> 1
     or not exists (select 1 from puerta_envio where entrada_id = v_b and tipo = 'anular'
                     and estado = 'pendiente' and motivo = 'filtro_seguridad')
     or (select estado from entradas where id = v_b) <> 'valida' then
    raise exception 'TEST_FAIL: el filtro no encoló la anulación hacia Puerta: %', v_r;
  end if;
  -- Seguridad saca la marca antes de que salga: se cancela.
  v_r := puerta_aplicar_estados(jsonb_build_array(
    jsonb_build_object('ref', v_b, 'code', v_code_b, 'estado', 'valida', 'filtrada', false)));
  if not exists (select 1 from puerta_envio where entrada_id = v_b and tipo = 'anular'
                  and estado = 'cancelado' and resultado = 'filtro_retirado') then
    raise exception 'TEST_FAIL: retirar la marca no canceló la anulación: %', v_r;
  end if;
  -- La vuelven a marcar: la fila revive.
  v_r := puerta_aplicar_estados(jsonb_build_array(
    jsonb_build_object('ref', v_b, 'code', v_code_b, 'estado', 'valida',
                       'filtrada', true, 'filtrada_at', now() - interval '10 minutes')));
  if not exists (select 1 from puerta_envio where entrada_id = v_b and tipo = 'anular'
                  and estado = 'pendiente' and motivo = 'filtro_seguridad') then
    raise exception 'TEST_FAIL: la marca nueva no revivió la anulación: %', v_r;
  end if;
  -- Sale, Puerta la anula: recién ahí acá queda anulada. Sin devolución.
  v_lote := puerta_tomar_envios('anular', 200);
  select jsonb_agg(jsonb_build_object('id', (x->>'id')::bigint, 'resultado', 'anulada'))
    into v_res from jsonb_array_elements(v_lote) x where x->>'ref' = v_b::text;
  if jsonb_array_length(coalesce(v_res, '[]')) <> 1 then
    raise exception 'TEST_FAIL: la anulación del filtro no salió: %', v_lote;
  end if;
  v_r := puerta_registrar_envios(v_res);
  if (v_r->>'anuladas_aca')::int <> 1 or (select estado from entradas where id = v_b) <> 'anulada' then
    raise exception 'TEST_FAIL: la anulación confirmada por Puerta no anuló acá: %', v_r;
  end if;
  if (select estado from ordenes where id = v_orden) <> 'pagada' then
    raise exception 'TEST_FAIL: el filtro tocó la orden (no hay devolución)';
  end if;
  if (select count(*) from puerta_envio where entrada_id = v_b and tipo = 'anular') <> 1
     or puerta_sync_activo() then
    raise exception 'TEST_FAIL: la anulación del filtro se volvió a encolar o dejó el permiso prendido';
  end if;
  -- Anulada acá y usada allá: no se toca, se cuenta.
  v_r := puerta_aplicar_estados(jsonb_build_array(
    jsonb_build_object('ref', v_b, 'code', v_code_b, 'estado', 'usada', 'used_at', now())));
  if (v_r->>'anuladas_aca_usadas_alla')::int <> 1 or (select estado from entradas where id = v_b) <> 'anulada' then
    raise exception 'TEST_FAIL: anulada acá / usada allá: %', v_r;
  end if;
  -- Allá deshicieron el ingreso de a: acá vuelve a válida.
  v_r := puerta_aplicar_estados(jsonb_build_array(
    jsonb_build_object('ref', v_a, 'code', v_code_a, 'estado', 'valida', 'filtrada', false)));
  if (select estado from entradas where id = v_a) <> 'valida' then
    raise exception 'TEST_FAIL: no se deshizo el ingreso: %', v_r;
  end if;

  -- ── 4b. anuladas antes de llegar a Puerta ──
  -- x ya se intentó una vez (timeout: Puerta pudo haberla creado). y nunca
  -- salió. Las dos se anulan en el panel antes del reintento.
  v_r := crear_orden(v_ev1, jsonb_build_array(jsonb_build_object('tipo_id', v_tipo, 'cantidad', 2)),
                     '{"nombre":"Otro Comprador","email":"otro@prueba.test"}'::jsonb);
  v_orden2 := (v_r->>'orden')::uuid;
  v_r := emitir_orden(v_orden2, 120, 'SIM-PRUEBA-PUERTA-2');
  select id into v_x from entradas where orden_id = v_orden2 order by id limit 1;
  select id into v_y from entradas where orden_id = v_orden2 and id <> v_x;
  v_lote := puerta_tomar_envios('entrada', 200);
  select jsonb_agg(jsonb_build_object('id', (x->>'id')::bigint, 'resultado', 'error',
                                      'motivo', 'The signal has been aborted'))
    into v_res from jsonb_array_elements(v_lote) x where x->>'ref' in (v_x::text, v_y::text);
  v_r := puerta_registrar_envios(v_res);
  if (v_r->>'reintentos')::int <> 2 then raise exception 'TEST_FAIL: timeout no volvió a la cola: %', v_r; end if;
  update puerta_envio set intentos = 0 where entrada_id = v_y and tipo = 'entrada';   -- y: nunca salió
  update entradas set estado = 'anulada' where id in (v_x, v_y);                      -- como el panel
  update puerta_envio set proximo_at = clock_timestamp() where entrada_id in (v_x, v_y);
  v_lote := puerta_tomar_envios('entrada', 200);
  if not exists (select 1 from jsonb_array_elements(v_lote) x where x->>'ref' = v_x::text)
     or exists (select 1 from jsonb_array_elements(v_lote) x where x->>'ref' = v_y::text)
     or not exists (select 1 from puerta_envio where entrada_id = v_y and tipo = 'entrada'
                     and estado = 'cancelado') then
    raise exception 'TEST_FAIL: la entrada intentada y anulada no se manda igual: %', v_lote;
  end if;
  -- Mientras x está en camino su anulación espera; la de y no tiene a qué ir.
  -- (Tomar va en su propia sentencia: las consultas de abajo tienen que ver
  -- lo que tomar acaba de escribir.)
  v_res := puerta_tomar_envios('anular', 200);
  if exists (select 1 from jsonb_array_elements(v_res) x
              where x->>'ref' in (v_x::text, v_y::text))
     or not exists (select 1 from puerta_envio where entrada_id = v_y and tipo = 'anular'
                     and estado = 'hecho' and resultado = 'nunca_llego')
     or not exists (select 1 from puerta_envio where entrada_id = v_x and tipo = 'anular'
                     and estado = 'pendiente') then
    raise exception 'TEST_FAIL: las anulaciones de x / y quedaron mal';
  end if;
  select jsonb_agg(jsonb_build_object('id', (x->>'id')::bigint, 'resultado', 'ya_estaba',
                                      'puerta_id', gen_random_uuid()))
    into v_res from jsonb_array_elements(v_lote) x where x->>'ref' = v_x::text;
  v_r := puerta_registrar_envios(v_res);
  v_lote := puerta_tomar_envios('anular', 200);
  select jsonb_agg(jsonb_build_object('id', (x->>'id')::bigint, 'resultado', 'anulada'))
    into v_res from jsonb_array_elements(v_lote) x where x->>'ref' = v_x::text;
  if jsonb_array_length(coalesce(v_res, '[]')) <> 1 then
    raise exception 'TEST_FAIL: la anulación de x no salió después de la entrada: %', v_lote;
  end if;
  v_r := puerta_registrar_envios(v_res);
  if (v_r->>'hechos')::int <> 1 then raise exception 'TEST_FAIL: anulación de x: %', v_r; end if;

  -- ── 4c. filtrada allá y anulada en el panel acá ──
  -- La anulación del filtro está en la cola; alguien la anula también en el
  -- panel; después Seguridad retira la marca. La del panel tiene que salir
  -- igual.
  v_r := crear_orden(v_ev1, jsonb_build_array(jsonb_build_object('tipo_id', v_tipo, 'cantidad', 1)),
                     '{"nombre":"Tercer Comprador","email":"tercero@prueba.test"}'::jsonb);
  v_r := emitir_orden((v_r->>'orden')::uuid, 60, 'SIM-PRUEBA-PUERTA-4');
  select e.id, e.code into v_x, v_code_b from entradas e
    join ordenes o on o.id = e.orden_id where o.pago_ref = 'SIM-PRUEBA-PUERTA-4';
  v_lote := puerta_tomar_envios('entrada', 200);
  select jsonb_agg(jsonb_build_object('id', (x->>'id')::bigint, 'resultado', 'creada',
                                      'puerta_id', gen_random_uuid()))
    into v_res from jsonb_array_elements(v_lote) x where x->>'ref' = v_x::text;
  v_r := puerta_registrar_envios(v_res);
  v_r := puerta_aplicar_estados(jsonb_build_array(
    jsonb_build_object('ref', v_x, 'code', v_code_b, 'estado', 'valida',
                       'filtrada', true, 'filtrada_at', now() - interval '10 minutes')));
  update entradas set estado = 'anulada' where id = v_x;                              -- como el panel
  v_r := puerta_aplicar_estados(jsonb_build_array(
    jsonb_build_object('ref', v_x, 'code', v_code_b, 'estado', 'valida', 'filtrada', false)));
  if not exists (select 1 from puerta_envio where entrada_id = v_x and tipo = 'anular'
                  and estado = 'pendiente' and motivo = 'panel') then
    raise exception 'TEST_FAIL: retirar el filtro canceló una anulación del panel: %',
      (select to_jsonb(s) from puerta_envio s where entrada_id = v_x and tipo = 'anular');
  end if;
  v_lote := puerta_tomar_envios('anular', 200);
  select jsonb_agg(jsonb_build_object('id', (x->>'id')::bigint, 'resultado', 'anulada'))
    into v_res from jsonb_array_elements(v_lote) x where x->>'ref' = v_x::text;
  if jsonb_array_length(coalesce(v_res, '[]')) <> 1 then
    raise exception 'TEST_FAIL: la anulación del panel no salió: %', v_lote;
  end if;
  v_r := puerta_registrar_envios(v_res);

  -- ── 5. el panel, con un admin de Bowie de verdad (sesión simulada) ──
  if puerta_sync_activo() then
    raise exception 'TEST_FAIL: el permiso del sync está prendido antes de probar la guarda';
  end if;
  insert into auth.users (id, email) values (v_admin, 'admin-bowie@prueba.test');
  insert into perfiles (id, organizador_id, nombre, rol) values (v_admin, v_bowie, 'Admin Prueba', 'admin');
  -- Una mesa de una fecha de Bowie que NO es espejo, para intentar mudarla.
  insert into eventos (id, organizador_id, slug, nombre, fecha)
  values (v_otro, v_bowie, 'prueba-no-espejo-' || left(replace(v_otro::text, '-', ''), 8),
          'Prueba no espejo', v_fecha);
  insert into mesas (organizador_id, evento_id, etiqueta, x, y, w, precio)
  values (v_bowie, v_otro, 'M1', 10, 10, 5, 100) returning id into v_mesa;
  set local role authenticated;
  perform set_config('request.jwt.claim.sub', v_admin::text, true);

  begin
    update eventos set nombre = 'Otro nombre' where id = v_ev1;
    v_ok := false;
  exception when others then v_ok := sqlerrm like 'ESPEJO_PUERTA%';
  end;
  if not v_ok then raise exception 'TEST_FAIL: el panel cambió el nombre del espejo'; end if;

  begin
    update fase_precio set precio = 1 where fase_id = v_online;
    v_ok := false;
  exception when others then v_ok := sqlerrm like 'ESPEJO_PUERTA%';
  end;
  if not v_ok then raise exception 'TEST_FAIL: el panel cambió el precio del espejo'; end if;

  begin
    insert into tipo_entrada (organizador_id, evento_id, nombre) values (v_bowie, v_ev1, 'VIP');
    v_ok := false;
  exception when others then v_ok := sqlerrm like 'ESPEJO_PUERTA%';
  end;
  if not v_ok then raise exception 'TEST_FAIL: el panel agregó un tipo al espejo'; end if;

  begin
    delete from evento_fase where id = v_online;
    v_ok := false;
  exception when others then v_ok := sqlerrm like 'ESPEJO_PUERTA%';
  end;
  if not v_ok then raise exception 'TEST_FAIL: el panel borró la fase del espejo'; end if;

  begin
    update mesas set evento_id = v_ev1 where id = v_mesa;
    get diagnostics v_n = row_count;
    v_ok := false;
  exception when others then v_ok := sqlerrm like 'ESPEJO_PUERTA%';
  end;
  if not v_ok then raise exception 'TEST_FAIL: una mesa se mudó a una fecha espejo (filas: %)', v_n; end if;

  begin
    perform emitir_cortesias(v_ev1, v_tipo, 1, 'Alguien', 'prueba');
    v_ok := false;
  exception when others then v_ok := sqlerrm like '%ESPEJO_PUERTA%';
  end;
  if not v_ok then raise exception 'TEST_FAIL: se emitió una cortesía en el espejo'; end if;

  begin
    perform cerrar_evento(v_ev1, 'prueba');
    v_ok := false;
  exception when others then v_ok := sqlerrm like '%ESPEJO_PUERTA%';
  end;
  if not v_ok then raise exception 'TEST_FAIL: el panel cerró el espejo'; end if;

  -- Lo que sí se puede: flyer y descripción, y el arte de la fase.
  update eventos set flyer_url = 'https://ejemplo.test/flyer.jpg', descripcion = 'Prueba'
   where id = v_ev1;
  get diagnostics v_n = row_count;
  if v_n <> 1 then raise exception 'TEST_FAIL: el panel no pudo cambiar el flyer'; end if;
  update evento_fase set arte_url = 'https://ejemplo.test/arte.jpg' where id = v_online;
  get diagnostics v_n = row_count;
  if v_n <> 1 then raise exception 'TEST_FAIL: el panel no pudo cambiar el arte de la fase'; end if;

  -- Nuestra puerta: padrón vacío con ok, y escanear avisa sin marcar nada.
  v_r := padron_puerta(v_ev1);
  if not (v_r->>'ok')::boolean or jsonb_array_length(v_r->'entradas') <> 0 then
    raise exception 'TEST_FAIL: el padrón de un espejo: %', v_r;
  end if;
  v_r := validar_entrada(v_ev1, v_code_a);
  if v_r->>'resultado' <> 'error' then raise exception 'TEST_FAIL: validar en un espejo: %', v_r; end if;
  v_r := marcar_filtro_entrada(v_ev1, v_code_a);
  if v_r->>'resultado' <> 'error' then raise exception 'TEST_FAIL: filtrar en un espejo: %', v_r; end if;

  -- Anular desde el panel anula también allá.
  v_r := anular_entrada(v_a, 'prueba de anulación hacia Puerta');

  -- Y el panel no ve ni llama nada del sync.
  begin
    perform puerta_tomar_envios('entrada', 1);
    v_ok := false;
  exception when insufficient_privilege then v_ok := true;
  end;
  if not v_ok then raise exception 'TEST_FAIL: authenticated ejecuta puerta_tomar_envios'; end if;
  begin
    perform 1 from puerta_envio limit 1;
    v_ok := false;
  exception when insufficient_privilege then v_ok := true;
  end;
  if not v_ok then raise exception 'TEST_FAIL: authenticated lee puerta_envio'; end if;

  reset role;
  perform set_config('request.jwt.claim.sub', '', true);

  if (select flyer_url from eventos where id = v_ev1) <> 'https://ejemplo.test/flyer.jpg'
     or (select nombre from eventos where id = v_ev1) <> 'Crush Ñandú'
     or (select evento_id from mesas where id = v_mesa) <> v_otro then
    raise exception 'TEST_FAIL: la guarda dejó pasar o frenó lo que no era';
  end if;
  if not exists (select 1 from puerta_envio where entrada_id = v_a and tipo = 'anular'
                  and estado = 'pendiente' and motivo = 'panel') then
    raise exception 'TEST_FAIL: anular en el panel no encoló la anulación';
  end if;
  -- Primero Puerta no contesta: la fila vuelve a la cola con espera, y
  -- mientras espera no se vuelve a tomar.
  v_lote := puerta_tomar_envios('anular', 200);
  select jsonb_agg(jsonb_build_object('id', (x->>'id')::bigint, 'resultado', 'error',
                                      'motivo', 'Puerta 503'))
    into v_res from jsonb_array_elements(v_lote) x where x->>'ref' = v_a::text;
  if jsonb_array_length(coalesce(v_res, '[]')) <> 1 then
    raise exception 'TEST_FAIL: la anulación no salió de la cola: %', v_lote;
  end if;
  v_r := puerta_registrar_envios(v_res);
  if (v_r->>'reintentos')::int <> 1
     or not exists (select 1 from puerta_envio where entrada_id = v_a and tipo = 'anular'
                     and estado = 'pendiente' and proximo_at > clock_timestamp()
                     and ultimo_error = 'Puerta 503') then
    raise exception 'TEST_FAIL: un error de Puerta no volvió a la cola con espera: %', v_r;
  end if;
  if exists (select 1 from jsonb_array_elements(puerta_tomar_envios('anular', 200)) x
              where x->>'ref' = v_a::text) then
    raise exception 'TEST_FAIL: se reintentó sin esperar';
  end if;
  update puerta_envio set proximo_at = clock_timestamp() where entrada_id = v_a and tipo = 'anular';
  v_lote := puerta_tomar_envios('anular', 200);
  select jsonb_agg(jsonb_build_object('id', (x->>'id')::bigint, 'resultado', 'anulada'))
    into v_res from jsonb_array_elements(v_lote) x where x->>'ref' = v_a::text;
  v_r := puerta_registrar_envios(v_res);
  if (v_r->>'hechos')::int <> 1 or (v_r->>'anuladas_aca')::int <> 0 then
    raise exception 'TEST_FAIL: registrar anulación: %', v_r;
  end if;

  -- ── 6. por fases, y los cambios de modo ──
  v_j2 := jsonb_build_object(
    'id', v_ev2, 'club_id', 'burtown', 'nombre', 'Aniversario BurTown', 'fecha', v_fecha,
    'hora_inicio', '22:00:00', 'hora_fin', '05:00:00', 'edad_min', 18,
    'precio_manilla', 60, 'venta_por_fases', true, 'manilla_desde', null,
    'manilla_hasta_ts', null, 'manilla_hasta', null, 'entrada_hasta', null,
    'estado', 'proximo', 'ticket_url', null, 'flyer_url', null, 'cut_rrpp', 15,
    'fases', jsonb_build_array(
      jsonb_build_object('id', v_fa, 'nombre', 'Hot Tickets', 'precio', 50, 'cupo', 30,
                         'desde', null, 'hasta', null, 'orden', 1, 'activo', true),
      jsonb_build_object('id', v_fb, 'nombre', 'Fase 1', 'precio', 70, 'cupo', null,
                         'desde', null, 'hasta', null, 'orden', 2, 'activo', true)));
  v_r := puerta_aplicar_eventos(jsonb_build_array(v_j1, v_j4, v_j2), v_hoy - 1);
  if (v_r->>'creados')::int <> 1 then raise exception 'TEST_FAIL: no creó el de fases: %', v_r; end if;
  select tipo_id into v_tipo from puerta_evento where evento_id = v_ev2;
  -- Sin corte de prepagadas en Puerta: corta al terminar la fiesta (05:00 del día siguiente).
  if not exists (select 1 from evento_fase where id = v_fa and evento_id = v_ev2 and activo and orden = 1
                  and hasta = (v_fecha + 1 + time '05:00') at time zone 'America/La_Paz')
     or not exists (select 1 from evento_fase where id = v_fb and activo and orden = 2)
     or not exists (select 1 from fase_precio where fase_id = v_fa and tipo_id = v_tipo and precio = 50 and cupo = 30)
     or not exists (select 1 from fase_precio where fase_id = v_fb and tipo_id = v_tipo and precio = 70 and cupo is null)
     or (select count(*) from evento_fase where evento_id = v_ev2) <> 2
     or fase_vigente(v_ev2) is distinct from v_fa then
    raise exception 'TEST_FAIL: las fases de Puerta no quedaron iguales';
  end if;

  -- Los relacionadores de Puerta vendieron 28 de las 30: acá quedan 2.
  v_fases := jsonb_build_array(
      jsonb_build_object('id', v_fa, 'nombre', 'Hot Tickets', 'precio', 50, 'cupo', 30,
                         'desde', null, 'hasta', null, 'orden', 1, 'activo', true, 'vendidas', 28),
      jsonb_build_object('id', v_fb, 'nombre', 'Fase 1', 'precio', 70, 'cupo', null,
                         'desde', null, 'hasta', null, 'orden', 2, 'activo', true, 'vendidas', 3));
  v_r := puerta_aplicar_eventos(jsonb_build_array(v_j1, v_j4, v_j2 || jsonb_build_object('fases', v_fases)), v_hoy - 1);
  if (select cupo from fase_precio where fase_id = v_fa) is distinct from 2
     or (select cupo from fase_precio where fase_id = v_fb) is not null
     or (select orden from evento_fase where id = v_fa) <> 1 then
    raise exception 'TEST_FAIL: el cupo con vendidas de Puerta: %', v_r;
  end if;
  -- Acá se vende 1 (pagado, todavía en la cola) y Puerta vendió una más:
  -- allá quedan 3, una es la nuestra en camino → acá se pueden vender 2.
  v_r := crear_orden(v_ev2, jsonb_build_array(jsonb_build_object('tipo_id', v_tipo, 'cantidad', 1)),
                     '{"nombre":"Comprador Fases","email":"fases@prueba.test"}'::jsonb);
  v_r := emitir_orden((v_r->>'orden')::uuid, 50, 'SIM-PRUEBA-PUERTA-3');
  v_fases := jsonb_set(v_fases, '{0,vendidas}', '27');
  v_r := puerta_aplicar_eventos(jsonb_build_array(v_j1, v_j4, v_j2 || jsonb_build_object('fases', v_fases)), v_hoy - 1);
  if (select cupo from fase_precio where fase_id = v_fa) is distinct from 3
     or disponibilidad_tipo(v_fa, v_tipo) <> 2 then
    raise exception 'TEST_FAIL: el cupo no descuenta lo que está en la cola: % / %',
      (select cupo from fase_precio where fase_id = v_fa), disponibilidad_tipo(v_fa, v_tipo);
  end if;

  -- Puerta apaga las fases: precio único.
  v_j2b := v_j2 || jsonb_build_object('venta_por_fases', false, 'fases', '[]'::jsonb);
  v_r := puerta_aplicar_eventos(jsonb_build_array(v_j1, v_j4, v_j2b), v_hoy - 1);
  select fase_online into v_online from puerta_evento where evento_id = v_ev2;
  if fase_vigente(v_ev2) is distinct from v_online
     or exists (select 1 from evento_fase where id in (v_fa, v_fb) and (activo or orden < 1000))
     or not exists (select 1 from fase_precio where fase_id = v_online and precio = 60) then
    raise exception 'TEST_FAIL: el paso a precio único quedó mal: %', v_r;
  end if;

  -- Vuelven las fases, Puerta avisa que la primera ya se llenó allá, y una
  -- tercera viene a Bs 0: esa no se vende.
  v_j2c := v_j2 || jsonb_build_object('fases', jsonb_build_array(
      jsonb_build_object('id', v_fa, 'nombre', 'Hot Tickets', 'precio', 50, 'cupo', 30,
                         'desde', null, 'hasta', null, 'orden', 1, 'activo', true, 'quedan', 0),
      jsonb_build_object('id', v_fb, 'nombre', 'Fase 1', 'precio', 70, 'cupo', null,
                         'desde', null, 'hasta', null, 'orden', 2, 'activo', true, 'quedan', null),
      jsonb_build_object('id', v_fc, 'nombre', 'Cortesía', 'precio', 0, 'cupo', null,
                         'desde', null, 'hasta', null, 'orden', 3, 'activo', true)));
  v_r := puerta_aplicar_eventos(jsonb_build_array(v_j1, v_j4, v_j2c), v_hoy - 1);
  if fase_vigente(v_ev2) is distinct from v_fb
     or exists (select 1 from evento_fase where id = v_online and activo)
     or exists (select 1 from evento_fase where id = v_fc and activo)
     or not (v_r->'sin_precio') @> to_jsonb(array[v_ev2::text]) then
    raise exception 'TEST_FAIL: la fase llena en Puerta o la de Bs 0 se venden acá: %', v_r;
  end if;

  -- ── 7. cierres ──
  -- Puerta deja de mandarlo: se cierra. Vuelve: se reabre.
  v_r := puerta_aplicar_eventos(jsonb_build_array(v_j1, v_j4), v_hoy - 1);
  if (select estado from eventos where id = v_ev2) <> 'cerrado'
     or (select cierre from puerta_evento where evento_id = v_ev2) <> 'ausente' then
    raise exception 'TEST_FAIL: el que dejó de venir no se cerró: %', v_r;
  end if;
  v_r := puerta_aplicar_eventos(jsonb_build_array(v_j1, v_j4, v_j2c), v_hoy - 1);
  if (select estado from eventos where id = v_ev2) <> 'publicado' then
    raise exception 'TEST_FAIL: el que volvió no se reabrió: %', v_r;
  end if;
  -- En Puerta lo pasan de boliche: acá no se muda, se saca de la venta.
  v_r := puerta_aplicar_eventos(jsonb_build_array(v_j1, v_j4 || '{"club_id":"burtown"}', v_j2c), v_hoy - 1);
  if (select estado from eventos where id = v_ev4) <> 'cerrado'
     or (select organizador_id from eventos where id = v_ev4) <> v_bowie then
    raise exception 'TEST_FAIL: el que cambió de boliche sigue a la venta: %', v_r;
  end if;
  -- Puerta lo cierra.
  v_r := puerta_aplicar_eventos(jsonb_build_array(v_j1 || '{"estado":"cerrado"}', v_j4, v_j2c), v_hoy - 1);
  if (select estado from eventos where id = v_ev1) <> 'cerrado'
     or (select cierre from puerta_evento where evento_id = v_ev1) <> 'puerta'
     or (select estado from eventos where id = v_ev4) <> 'publicado' then
    raise exception 'TEST_FAIL: el que cerró Puerta sigue abierto: %', v_r;
  end if;
  -- Sin respuesta de Puerta no se cierra nada.
  v_r := puerta_aplicar_eventos(null, v_hoy - 1);
  if (select estado from eventos where id = v_ev2) <> 'publicado' then
    raise exception 'TEST_FAIL: un corte de Puerta cerró espejos';
  end if;

  -- ── 8. la fecha de corte ──
  -- Se corre `desde` más allá de las fechas espejadas: no se espeja nada
  -- nuevo antes del corte, y lo que ya estaba sale de la venta.
  update puerta_config set desde = v_fecha + 30 where id;
  v_j3 := v_j1 || jsonb_build_object('id', v_ev3, 'nombre', 'Antes del corte');
  v_r := puerta_aplicar_eventos(jsonb_build_array(v_j3), v_fecha + 30);
  if exists (select 1 from eventos where id = v_ev3) then
    raise exception 'TEST_FAIL: se espejó una fecha anterior al corte: %', v_r;
  end if;
  if (select estado from eventos where id = v_ev2) <> 'cerrado'
     or (select cierre from puerta_evento where evento_id = v_ev2) <> 'corte'
     or (select estado from eventos where id = v_ev4) <> 'cerrado' then
    raise exception 'TEST_FAIL: correr el corte dejó espejos a la venta: %', v_r;
  end if;
  -- Vuelve el corte: Puerta las manda de nuevo y se reabren.
  update puerta_config set desde = v_hoy where id;
  v_r := puerta_aplicar_eventos(jsonb_build_array(v_j1, v_j4, v_j2c), v_hoy - 1);
  if (select estado from eventos where id = v_ev2) <> 'publicado'
     or (select estado from eventos where id = v_ev4) <> 'publicado' then
    raise exception 'TEST_FAIL: volver el corte no reabrió: %', v_r;
  end if;

  -- ── 9. el interruptor ──
  update puerta_config set activo = false where id;
  v_r := puerta_aplicar_eventos(null, v_hoy - 1);
  if not coalesce((v_r->>'apagado')::boolean, false)
     or (select estado from eventos where id = v_ev2) <> 'cerrado'
     or (select estado from eventos where id = v_ev4) <> 'cerrado'
     or (select cierre from puerta_evento where evento_id = v_ev2) <> 'apagado' then
    raise exception 'TEST_FAIL: apagar no sacó de la venta: %', v_r;
  end if;
  if puerta_sync_activo() then
    raise exception 'TEST_FAIL: el permiso del sync quedó prendido al final';
  end if;

  -- ── 10. permisos ──
  select string_agg(p.proname, ', ') into v_txt
    from pg_proc p
   where p.pronamespace = 'public'::regnamespace
     and (p.proname like 'puerta\_%' or p.proname = 'evento_espejo')
     and (has_function_privilege('anon', p.oid, 'execute')
          or has_function_privilege('authenticated', p.oid, 'execute'));
  if v_txt is not null then raise exception 'TEST_FAIL: funciones del espejo abiertas: %', v_txt; end if;
  select string_agg(distinct table_name || ':' || grantee, ', ') into v_txt
    from information_schema.role_table_grants
   where table_schema = 'public' and table_name like 'puerta\_%'
     and table_name <> 'puerta_bitacora' and grantee in ('anon', 'authenticated');
  if v_txt is not null then raise exception 'TEST_FAIL: tablas del espejo abiertas: %', v_txt; end if;
  select string_agg(f, ', ') into v_txt from chequeo_funciones_sin_guardia() f;
  if v_txt is not null then raise exception 'TEST_FAIL: funciones sin guardia: %', v_txt; end if;

  raise exception 'TEST_OK: espejo de Puerta — alta, imágenes, precio 0, página y cartelera, compra sin cargo, cola, precio forzado, estados, filtro de Seguridad, anuladas antes de salir, guarda del panel y mesas, puerta propia, fases y cupo compartido, cierres, cambio de boliche, corte e interruptor';
end $$;
