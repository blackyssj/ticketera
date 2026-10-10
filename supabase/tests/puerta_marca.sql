-- La marca arriba y la noche de Puerta (0104), contra la base real.
--
-- Un solo bloque que termina SIEMPRE en una excepción: 'TEST_OK …' si todo
-- anduvo, 'TEST_FAIL …' (o el error que sea) si no. No queda nada escrito.
-- Se corre DESPUÉS de aplicar 0104:
--
--     python3 scripts/sql.py supabase/tests/puerta_marca.sql
--
-- La salida esperada es un FALLO con el texto "TEST_OK: …".
--
-- Llama a puerta_espejar_evento de a un evento y NO a puerta_aplicar_eventos:
-- esa cierra todo espejo que no venga en la lista, y con Crush y MADNESS a
-- la venta el bloque les tomaría la fila mientras dura. Tampoco toca
-- puerta_config: las fechas de prueba (dentro de 6 días) ya quedan después
-- del corte.
do $$
declare
  v_hoy    date := (now() at time zone 'America/La_Paz')::date;
  v_fecha  date := (now() at time zone 'America/La_Paz')::date + 6;
  v_ev1    uuid := gen_random_uuid();   -- Bowie, precio único, con club y listas
  v_ev2    uuid := gen_random_uuid();   -- BurTown, de un Puerta sin v5.9 (sin club ni listas)
  v_ev3    uuid := gen_random_uuid();   -- BurTown, por fases
  v_otro   uuid := gen_random_uuid();   -- Bowie, cargado acá: NO es espejo
  v_fa     uuid := gen_random_uuid();
  v_fb     uuid := gen_random_uuid();
  v_bowie  uuid; v_burtown uuid;
  v_club   jsonb; v_j1 jsonb; v_j2 jsonb; v_j3 jsonb; v_r jsonb;
  v_e      eventos;
  v_s1     text; v_s2 text; v_s3 text; v_txt text; v_ok boolean;
  v_tipo   uuid; v_fase uuid;
begin
  -- ── 0. lo que dejó la migración ──
  select id into v_bowie from organizadores where slug = 'bowie' and titulo_marca;
  select id into v_burtown from organizadores where slug = 'burtown' and titulo_marca;
  if v_bowie is null or v_burtown is null then
    raise exception 'TEST_FAIL: bowie y burtown no tienen titulo_marca';
  end if;
  if exists (select 1 from information_schema.columns
              where table_schema = 'public' and table_name = 'eventos'
                and column_name in ('free_cover', 'maps_url')
              having count(*) <> 2) then
    raise exception 'TEST_FAIL: faltan eventos.free_cover / eventos.maps_url';
  end if;

  -- ── 1. un evento con el club y las listas, como manda Puerta v5.9 ──
  v_club := jsonb_build_object(
    'nombre', 'Bowie', 'lugar', 'Bowie Club', 'direccion', 'Av. San Martín 123, Equipetrol',
    'lat', -17.7712, 'lng', -63.1956, 'maps_url', 'https://maps.app.goo.gl/abcDEF123');
  v_j1 := jsonb_build_object(
    'id', v_ev1, 'club_id', 'bowie', 'nombre', 'Prueba Marca ' || left(v_ev1::text, 6),
    'fecha', v_fecha, 'hora_inicio', '21:00:00', 'hora_fin', '05:00:00', 'edad_min', 21,
    'precio_manilla', 60, 'venta_por_fases', false, 'manilla_desde', null,
    'manilla_hasta_ts', to_jsonb((v_fecha + time '23:30') at time zone 'America/La_Paz'),
    'manilla_hasta', null, 'entrada_hasta', null, 'estado', 'proximo',
    'ticket_url', 'https://kdkjmqrbiszmkcprinir.supabase.co/storage/v1/object/public/disenos/prueba.jpg?v=1',
    'flyer_url', null, 'cut_rrpp', 15, 'fases', '[]'::jsonb,
    'club', v_club,
    -- v5.9 ya no lo manda; si viniera, no se lee (allá no corta nada).
    'lista_hasta', '23:00:00',
    'listas', jsonb_build_array(
      jsonb_build_object('nombre', 'Invitados', 'orden', 0, 'ingreso_hasta', '23:50:00',
                         'registro_hasta_local', to_char(v_fecha, 'YYYY-MM-DD') || ' 21:00'),
      jsonb_build_object('nombre', 'Free Cover Mujeres', 'orden', 2, 'ingreso_hasta', null,
                         'registro_hasta_local', null),
      jsonb_build_object('nombre', 'FREE pase VIP', 'orden', 1, 'ingreso_hasta', '00:30:00',
                         'registro_hasta_local', to_char(v_fecha, 'YYYY-MM-DD') || ' 22:00'),
      jsonb_build_object('nombre', 'Compra en Puerta', 'orden', 1, 'ingreso_hasta', '03:00:00')));

  v_txt := puerta_espejar_evento(v_j1, false);
  if v_txt <> 'creado' then raise exception 'TEST_FAIL: no se creó el espejo: %', v_txt; end if;
  if puerta_sync_activo() then raise exception 'TEST_FAIL: el permiso del sync quedó prendido'; end if;

  select * into v_e from eventos where id = v_ev1;
  v_s1 := v_e.slug;
  if v_e.lugar <> 'Bowie Club' or v_e.direccion <> 'Av. San Martín 123, Equipetrol'
     or v_e.lat <> -17.7712 or v_e.lng <> -63.1956
     or v_e.maps_url <> 'https://maps.app.goo.gl/abcDEF123'
     or v_e.hora_fin <> '05:00' or v_e.edad_min <> 21 then
    raise exception 'TEST_FAIL: la ubicación o el horario no vinieron de Puerta: %', to_jsonb(v_e);
  end if;
  -- Solo las que dicen free, en el orden de Puerta, con las horas de cada
  -- una y sin el lista_hasta del evento.
  if v_e.free_cover is distinct from jsonb_build_array(
       jsonb_build_object('nombre', 'FREE pase VIP', 'ingreso_hasta', '00:30',
                          'registro_hasta', to_char(v_fecha, 'YYYY-MM-DD') || ' 22:00'),
       jsonb_build_object('nombre', 'Free Cover Mujeres', 'ingreso_hasta', null,
                          'registro_hasta', null)) then
    raise exception 'TEST_FAIL: el free cover quedó mal: %', v_e.free_cover;
  end if;

  -- La página: la marca, la noche y la entrada de Puerta.
  v_r := evento_publico('bowie', v_s1);
  if v_r ? 'falta'
     or (v_r->'organizador'->>'titulo_marca')::boolean is not true
     or (v_r->'evento'->>'entrada_puerta')::boolean is not true
     or v_r->'evento'->'free_cover' is distinct from to_jsonb(v_e.free_cover)
     or v_r->'evento'->>'hora_fin' <> '05:00:00'
     or v_r->'evento'->>'maps_url' <> 'https://maps.app.goo.gl/abcDEF123'
     or v_r->'evento'->>'direccion' <> 'Av. San Martín 123, Equipetrol' then
    raise exception 'TEST_FAIL: la página no devuelve lo nuevo: %', v_r;
  end if;
  -- Precio único: la fase 'Online' la inventa el espejo, en Puerta no existe
  -- y su entrada no lleva sello.
  if v_r->'fase'->>'nombre' <> 'Online' or v_r->'fase'->'sello' <> 'null'::jsonb then
    raise exception 'TEST_FAIL: la fase Online lleva sello: %', v_r->'fase';
  end if;
  select x into v_r from jsonb_array_elements(cartelera_publica()) x where x->>'id' = v_ev1::text;
  if v_r is null or (v_r->'organizadores'->>'titulo_marca')::boolean is not true then
    raise exception 'TEST_FAIL: la cartelera no dice que el título es la marca: %', v_r;
  end if;

  -- La misma versión otra vez: igual, sin tocar nada.
  v_txt := puerta_espejar_evento(v_j1, false);
  if v_txt <> 'igual' then raise exception 'TEST_FAIL: reescribió sin cambios: %', v_txt; end if;

  -- ── 2. el panel corrige el lugar y Puerta no se lo pisa ──
  -- (como postgres, sin el permiso del sync: la guarda deja tocar el lugar)
  update eventos set lugar = 'Bowie (corregido)' where id = v_ev1;
  v_j1 := v_j1 || jsonb_build_object('hora_inicio', '22:00:00');
  v_txt := puerta_espejar_evento(v_j1, false);
  if v_txt <> 'actualizado' then raise exception 'TEST_FAIL: no aplicó el cambio de hora: %', v_txt; end if;
  select * into v_e from eventos where id = v_ev1;
  if v_e.lugar <> 'Bowie (corregido)' or v_e.hora_inicio <> '22:00' then
    raise exception 'TEST_FAIL: un cambio de hora pisó el lugar corregido: %', to_jsonb(v_e);
  end if;
  -- Cambió el club en Puerta: ahora sí manda Puerta.
  v_club := v_club || jsonb_build_object('lugar', 'Bowie Equipetrol', 'lat', -17.7701, 'lng', -63.1950);
  v_j1 := v_j1 || jsonb_build_object('club', v_club);
  v_txt := puerta_espejar_evento(v_j1, false);
  select * into v_e from eventos where id = v_ev1;
  if v_e.lugar <> 'Bowie Equipetrol' or v_e.lat <> -17.7701 or v_e.lng <> -63.1950
     or v_e.direccion <> 'Av. San Martín 123, Equipetrol' then
    raise exception 'TEST_FAIL: un cambio del club en Puerta no llegó: %', to_jsonb(v_e);
  end if;

  -- ── 3. el free cover es de Puerta: el panel no lo toca ──
  begin
    update eventos set free_cover = '[]'::jsonb where id = v_ev1;
    v_ok := false;
  exception when others then v_ok := sqlerrm like 'ESPEJO_PUERTA%';
  end;
  if not v_ok then raise exception 'TEST_FAIL: el panel cambió el free cover de un espejo'; end if;

  -- ── 4. datos raros: se ignoran sin frenar el evento ──
  v_j1 := v_j1 || jsonb_build_object(
    'precio_manilla', 70,
    'club', v_club || jsonb_build_object('lat', 'abc', 'maps_url', 'javascript:alert(1)'),
    'listas', jsonb_build_array('Free suelto', 42,
      jsonb_build_object('nombre', 'Free X', 'orden', 'primero', 'ingreso_hasta', '25:99',
                         -- la cruda en UTC: un ::timestamp la publicaría como hora de acá
                         'registro_hasta_local', to_char(v_fecha + 1, 'YYYY-MM-DD') || 'T02:00:00+00:00')));
  v_txt := puerta_espejar_evento(v_j1, false);
  if v_txt not like 'actualizado%' then raise exception 'TEST_FAIL: un dato raro frenó el espejo: %', v_txt; end if;
  select * into v_e from eventos where id = v_ev1;
  if v_e.lat <> -17.7701 or v_e.maps_url <> 'https://maps.app.goo.gl/abcDEF123'
     or v_e.free_cover is distinct from jsonb_build_array(
          jsonb_build_object('nombre', 'Free X', 'ingreso_hasta', null, 'registro_hasta', null))
     or not exists (select 1 from fase_precio fp join puerta_evento pe on pe.fase_online = fp.fase_id
                     where pe.evento_id = v_ev1 and fp.precio = 70) then
    raise exception 'TEST_FAIL: los datos raros no se ignoraron bien: %', to_jsonb(v_e);
  end if;
  -- Un link de mapa que no es de Google tampoco entra.
  if puerta_maps('https://evil.example/maps') is not null
     or puerta_maps('https://www.google.com/maps/place/Bowie/@-17.77,-63.19,17z') is null
     or puerta_maps('https://maps.google.com/?q=-17.77,-63.19') is null
     or puerta_maps('https://maps.app.goo.gl/x"onmouseover=alert(1)') is not null then
    raise exception 'TEST_FAIL: puerta_maps acepta o rechaza lo que no debe';
  end if;
  -- El cierre de la lista: la hora de Bolivia que arma Puerta, nunca una con zona.
  if puerta_momento('2026-10-10 22:00') is distinct from '2026-10-10 22:00'
     or puerta_momento('2026-10-10T22:00:00') is distinct from '2026-10-10 22:00'
     or puerta_momento('2026-10-11T02:00:00+00:00') is not null
     or puerta_momento('2026-10-11 02:00:00+00') is not null
     or puerta_momento('2026-10-11T02:00Z') is not null
     or puerta_momento('2026-13-40 25:00') is not null
     or puerta_momento('mañana') is not null or puerta_momento(null) is not null then
    raise exception 'TEST_FAIL: puerta_momento acepta o rechaza lo que no debe';
  end if;

  -- Sin `listas` (un Puerta viejo): el free cover queda como estaba.
  v_j1 := (v_j1 - 'listas') || jsonb_build_object('precio_manilla', 80);
  v_txt := puerta_espejar_evento(v_j1, false);
  if (select free_cover from eventos where id = v_ev1) is distinct from jsonb_build_array(
       jsonb_build_object('nombre', 'Free X', 'ingreso_hasta', null, 'registro_hasta', null)) then
    raise exception 'TEST_FAIL: sin listas se borró el free cover';
  end if;
  -- Con la lista vacía: allá sacaron el free cover, acá no se anuncia más.
  v_j1 := v_j1 || jsonb_build_object('listas', '[]'::jsonb);
  v_txt := puerta_espejar_evento(v_j1, false);
  if (select free_cover from eventos where id = v_ev1) is not null then
    raise exception 'TEST_FAIL: quedó un free cover que Puerta ya no tiene';
  end if;

  -- ── 5. un Puerta sin v5.9: todo como en 0103 ──
  v_j2 := jsonb_build_object(
    'id', v_ev2, 'club_id', 'burtown', 'nombre', 'Prueba Vieja ' || left(v_ev2::text, 6),
    'fecha', v_fecha, 'hora_inicio', '21:00:00', 'hora_fin', '06:00:00', 'edad_min', 18,
    'precio_manilla', 50, 'venta_por_fases', false, 'manilla_desde', null,
    'manilla_hasta_ts', null, 'manilla_hasta', null, 'entrada_hasta', null,
    'estado', 'proximo', 'ticket_url', null, 'flyer_url', null, 'cut_rrpp', 15,
    'fases', '[]'::jsonb);
  v_txt := puerta_espejar_evento(v_j2, false);
  select * into v_e from eventos where id = v_ev2;
  v_s2 := v_e.slug;
  if v_txt <> 'creado' or v_e.lugar <> 'BurTown' or v_e.direccion is not null
     or v_e.lat is not null or v_e.maps_url is not null or v_e.free_cover is not null then
    raise exception 'TEST_FAIL: sin club ni listas el espejo no quedó como en 0103: % %', v_txt, to_jsonb(v_e);
  end if;

  -- El club que vio la función vieja (antes de 0104) no cuenta como visto:
  -- 0104 lo saca de `datos`. Con él adentro, el mismo club no se aplicaría.
  update puerta_evento set datos = datos || jsonb_build_object('club', v_club), hash = null
   where evento_id = v_ev2;
  v_txt := puerta_espejar_evento(v_j2 || jsonb_build_object('club', v_club), false);
  if (select lugar from eventos where id = v_ev2) <> 'BurTown' then
    raise exception 'TEST_FAIL: la regla de "cambió desde la última vez" no anda';
  end if;
  update puerta_evento set datos = datos - 'club', hash = null where evento_id = v_ev2;
  v_txt := puerta_espejar_evento(v_j2 || jsonb_build_object('club', v_club), false);
  if (select lugar from eventos where id = v_ev2) <> 'Bowie Equipetrol' then
    raise exception 'TEST_FAIL: sin el club viejo en datos la ubicación no llegó';
  end if;

  -- ── 6. por fases: el sello es el nombre de la fase de Puerta ──
  v_j3 := jsonb_build_object(
    'id', v_ev3, 'club_id', 'burtown', 'nombre', 'Prueba Fases ' || left(v_ev3::text, 6),
    'fecha', v_fecha, 'hora_inicio', '22:00:00', 'hora_fin', '05:00:00', 'edad_min', 18,
    'precio_manilla', 60, 'venta_por_fases', true, 'manilla_desde', null,
    'manilla_hasta_ts', null, 'manilla_hasta', null, 'entrada_hasta', null,
    'estado', 'proximo', 'ticket_url', null, 'flyer_url', null, 'cut_rrpp', 15,
    'fases', jsonb_build_array(
      jsonb_build_object('id', v_fa, 'nombre', 'Hot Tickets', 'precio', 50, 'cupo', null,
                         'desde', null, 'hasta', null, 'orden', 1, 'activo', true),
      jsonb_build_object('id', v_fb, 'nombre', 'Fase 1', 'precio', 70, 'cupo', null,
                         'desde', null, 'hasta', null, 'orden', 2, 'activo', true)));
  v_txt := puerta_espejar_evento(v_j3, false);
  select slug into v_s3 from eventos where id = v_ev3;
  v_r := evento_publico('burtown', v_s3);
  if v_txt <> 'creado' or v_r ? 'falta' or v_r->'fase'->>'sello' <> 'Hot Tickets'
     or (v_r->'evento'->>'entrada_puerta')::boolean is not true then
    raise exception 'TEST_FAIL: la fase de Puerta no lleva sello: % %', v_txt, v_r->'fase';
  end if;

  -- ── 7. un evento de Bowie cargado acá: la marca sí, la entrada de Puerta no ──
  insert into eventos (id, organizador_id, slug, nombre, fecha, estado)
  values (v_otro, v_bowie, 'prueba-no-espejo-' || left(replace(v_otro::text, '-', ''), 8),
          'Prueba no espejo', v_fecha, 'publicado');
  insert into tipo_entrada (organizador_id, evento_id, nombre, manillas, orden, activo, categoria, en_cartelera)
  values (v_bowie, v_otro, 'General', 1, 0, true, 'entrada', true) returning id into v_tipo;
  insert into evento_fase (organizador_id, evento_id, nombre, orden, activo)
  values (v_bowie, v_otro, 'Preventa', 0, true) returning id into v_fase;
  insert into fase_precio (organizador_id, fase_id, tipo_id, precio, cupo)
  values (v_bowie, v_fase, v_tipo, 40, null);
  v_r := evento_publico('bowie', 'prueba-no-espejo-' || left(replace(v_otro::text, '-', ''), 8));
  if v_r ? 'falta' or (v_r->'organizador'->>'titulo_marca')::boolean is not true
     or (v_r->'evento'->>'entrada_puerta')::boolean is not false
     or v_r->'fase'->'sello' <> 'null'::jsonb then
    raise exception 'TEST_FAIL: un evento que no es espejo se dibujaría como Puerta: %', v_r;
  end if;

  -- ── 8. permisos ──
  select string_agg(p.oid::regprocedure::text, ', ') into v_txt
    from pg_proc p
   where p.pronamespace = 'public'::regnamespace
     and p.proname in ('puerta_hora', 'puerta_numero', 'puerta_momento', 'puerta_maps', 'puerta_espejar_evento',
                       'puerta_guarda', 'evento_publico', 'cartelera_publica')
     and (has_function_privilege('anon', p.oid, 'execute')
          or has_function_privilege('authenticated', p.oid, 'execute'));
  if v_txt is not null then raise exception 'TEST_FAIL: funciones abiertas: %', v_txt; end if;
  -- Una sola firma de cada una: un create or replace con otros parámetros
  -- deja la vieja viva al lado.
  select string_agg(proname, ', ') into v_txt from (
    select proname from pg_proc
     where pronamespace = 'public'::regnamespace
       and proname in ('puerta_espejar_evento', 'evento_publico', 'cartelera_publica')
     group by proname having count(*) > 1) x;
  if v_txt is not null then raise exception 'TEST_FAIL: firmas duplicadas: %', v_txt; end if;
  select string_agg(f, ', ') into v_txt from chequeo_funciones_sin_guardia() f;
  if v_txt is not null then raise exception 'TEST_FAIL: funciones sin guardia: %', v_txt; end if;

  raise exception 'TEST_OK: marca arriba — club y listas de Puerta, free cover filtrado y ordenado, página y cartelera con la marca, lugar corregido en el panel que no se pisa, free cover guardado, datos raros ignorados, Puerta sin v5.9, club visto antes de 0104, sello de fase, evento propio de Bowie, permisos';
end $$;
