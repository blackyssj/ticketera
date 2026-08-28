-- Un rrpp NO puede tocar precios. Se prueba con la sesión simulada que usa
-- PostgREST: rol `authenticated` más el claim del usuario.
begin;

insert into organizadores (id, slug, nombre) values
  ('cccccccc-0000-4000-8000-000000000001', 'prueba-rol', 'Prueba');
insert into auth.users (id, email) values
  ('dddddddd-0000-4000-8000-000000000001', 'rrpp@ticketera.local');
insert into perfiles (id, organizador_id, nombre, rol) values
  ('dddddddd-0000-4000-8000-000000000001', 'cccccccc-0000-4000-8000-000000000001', 'Un Rrpp', 'rrpp');
insert into eventos (id, organizador_id, slug, nombre, fecha) values
  ('eeeeeeee-0000-4000-8000-000000000001', 'cccccccc-0000-4000-8000-000000000001',
   'prueba', 'Prueba', current_date + 10);
insert into tipo_entrada (id, organizador_id, evento_id, nombre) values
  ('ffffffff-0000-4000-8000-000000000001', 'cccccccc-0000-4000-8000-000000000001',
   'eeeeeeee-0000-4000-8000-000000000001', 'General');

do $$
declare v_n int;
begin
  set local role authenticated;
  perform set_config('request.jwt.claim.sub', 'dddddddd-0000-4000-8000-000000000001', true);

  begin
    update tipo_entrada set nombre = 'Hackeado'
     where id = 'ffffffff-0000-4000-8000-000000000001';
  exception when others then null;
  end;

  reset role;
  select count(*) into v_n from tipo_entrada
   where id = 'ffffffff-0000-4000-8000-000000000001' and nombre = 'Hackeado';
  if v_n > 0 then
    raise exception 'TEST_FAIL: un rrpp cambio el nombre de un tipo de entrada';
  end if;
  raise notice 'OK un rrpp no escribe el catalogo';
end $$;

-- publicar_evento()/listo_para_publicar() (0013): el rrpp de arriba no
-- alcanza porque puede_editar() exige admin/staff, así que este bloque
-- siembra un staff propio del mismo organizador y simula sesión con él
-- (mismo mecanismo: set local role authenticated + set_config del sub).
-- El tipo_entrada sembrado arriba (ffffffff...1) ya existe activo, así que
-- para reproducir el estado "sin fase NI precio" del brief (dos cosas
-- faltando, no una) se lo desactiva un momento y se reactiva antes de
-- darle fase y precio — así el chequeo de "al menos un tipo de entrada
-- activo" también queda ejercitado, no solo el de la fase.
do $$
declare v_ev    uuid := 'eeeeeeee-0000-4000-8000-000000000001';
        v_tipo  uuid := 'ffffffff-0000-4000-8000-000000000001';
        v_tipo2 uuid := 'ffffffff-0000-4000-8000-000000000002';
        v_staff uuid := 'dddddddd-0000-4000-8000-000000000002';
        v_fase  uuid; v_r jsonb;
begin
  insert into auth.users (id, email) values
    (v_staff, 'staff@ticketera.local');
  insert into perfiles (id, organizador_id, nombre, rol) values
    (v_staff, 'cccccccc-0000-4000-8000-000000000001', 'Un Staff', 'staff');

  set local role authenticated;
  perform set_config('request.jwt.claim.sub', v_staff::text, true);

  update tipo_entrada set activo = false where id = v_tipo;

  -- sin tipo de entrada activo, sin fase ni precio: no se publica y dice qué falta
  v_r := listo_para_publicar(v_ev);
  if (v_r->>'ok')::boolean is not false then
    raise exception 'TEST_FAIL: dijo que estaba listo sin fase ni precio';
  end if;
  if jsonb_array_length(v_r->'faltan') < 2 then
    raise exception 'TEST_FAIL: deberia listar las dos cosas que faltan, dijo %', v_r->'faltan';
  end if;

  begin
    perform publicar_evento(v_ev, true);
    raise exception 'TEST_FAIL: publico un evento sin fase ni precio';
  exception when others then
    if sqlerrm not like 'NO_PUBLICABLE:%' then raise; end if;
  end;

  -- con fase abierta y precio: publica
  update tipo_entrada set activo = true where id = v_tipo;
  insert into evento_fase (id, organizador_id, evento_id, nombre, desde, hasta)
  values (gen_random_uuid(), 'cccccccc-0000-4000-8000-000000000001', v_ev, 'F1',
          now() - interval '1 hour', now() + interval '10 days')
  returning id into v_fase;
  insert into fase_precio (organizador_id, fase_id, tipo_id, precio, cupo)
  values ('cccccccc-0000-4000-8000-000000000001', v_fase, v_tipo, 100, 50);

  v_r := listo_para_publicar(v_ev);
  if (v_r->>'ok')::boolean is not true then
    raise exception 'TEST_FAIL: con fase y precio deberia estar listo: %', v_r;
  end if;

  perform publicar_evento(v_ev, true);
  if (select estado from eventos where id = v_ev) <> 'publicado' then
    raise exception 'TEST_FAIL: no quedo publicado';
  end if;

  -- despublicar siempre se puede: es la salida de emergencia
  perform publicar_evento(v_ev, false);
  if (select estado from eventos where id = v_ev) <> 'borrador' then
    raise exception 'TEST_FAIL: no volvio a borrador';
  end if;

  -- "listo falso": el precio le queda colgado al tipo que se desactivó
  -- (nadie lo borra al desactivar un tipo_entrada) y el tipo que sigue
  -- activo no tiene ningún precio en la fase vigente. listo_para_publicar
  -- tiene que fijarse en QUÉ tipo tiene el precio, no solo en si existe
  -- algún precio en la fase — si no, dice "listo" y el único tipo visible
  -- no tiene con qué venderse.
  insert into tipo_entrada (id, organizador_id, evento_id, nombre) values
    (v_tipo2, 'cccccccc-0000-4000-8000-000000000001', v_ev, 'VIP');
  update tipo_entrada set activo = false where id = v_tipo;  -- el que tiene precio, se desactiva
  -- v_tipo2 queda activo y sin fila en fase_precio

  v_r := listo_para_publicar(v_ev);
  if (v_r->>'ok')::boolean is not false then
    raise exception 'TEST_FAIL: dijo que estaba listo con el precio colgado del tipo desactivado: %', v_r;
  end if;
  if not (v_r->'faltan' ? 'Ningún tipo de entrada tiene precio en la fase abierta') then
    raise exception 'TEST_FAIL: no explico que ningun tipo activo tiene precio en la fase abierta: %', v_r;
  end if;

  reset role;
  raise notice 'OK publicar exige fase abierta y precio';
end $$;

rollback;

-- El invariante 5 corre chequeo_policies_sin_rol() (0012). Este test NO
-- copia su patrón de texto: siembra una policy con mi_rol() y otra sin
-- ningún chequeo de rol, llama a la MISMA función, y verifica que devuelva
-- justo la segunda. Si el patrón real cambia, este test corre el cambio
-- real — no puede quedar en verde por revisar una copia vieja.
begin;

create policy "prueba invariante: con mi_rol" on eventos for update to authenticated
  using (mi_rol() = 'admin');
create policy "prueba invariante: sin chequeo" on eventos for update to authenticated
  using (true);

do $$
declare v_malas text;
begin
  select chequeo_policies_sin_rol() into v_malas;

  if v_malas like '%con mi_rol%' then
    raise exception 'TEST_FAIL: el invariante no reconoce mi_rol() como filtro de rol';
  end if;

  if v_malas is null or v_malas not like '%sin chequeo%' then
    raise exception 'TEST_FAIL: el invariante no atrapa una policy sin ningun chequeo de rol';
  end if;

  raise notice 'OK el invariante 5 reconoce mi_rol() y atrapa lo que no filtra por rol';
end $$;

rollback;

-- 0012 reemplaza siete policies que leían Y escribían con el mismo
-- `for all ... using (organizador_id = mi_organizador())`, sin ningún
-- chequeo de rol — el agujero original. `drop policy if exists <nombre>`
-- no falla si el nombre no coincide: si algún nombre estuviera mal escrito,
-- la policy vieja seguiría viva, se combinaría por OR con la nueva, y el
-- agujero seguiría abierto en esa tabla sin que ningún otro test lo note
-- (policies.sql solo prueba el comportamiento en tipo_entrada). Esto
-- verifica, tabla por tabla, que ninguno de los siete nombres viejos
-- sobrevive. No hace falta simular sesión: es una consulta directa a
-- pg_policies.
do $$
declare v_malas text;
begin
  select string_agg(tablename || '.' || policyname, ', ') into v_malas
  from pg_policies
  where schemaname = 'public'
    and (tablename, policyname) in (
      ('tipo_entrada', 'tipos: los míos'),
      ('evento_fase',  'fases: las mías'),
      ('fase_precio',  'precios: los míos'),
      ('mesas',        'mesas: las mías'),
      ('ordenes',      'ordenes: las de mi organizador'),
      ('orden_items',  'items: los de mi organizador'),
      ('entradas',     'entradas: las de mi organizador')
    );
  if v_malas is not null then
    raise exception 'TEST_FAIL: policies viejas de antes de 0012 todavía existen: %', v_malas;
  end if;
  raise notice 'OK las siete policies viejas de 0012 fueron reemplazadas, no duplicadas';
end $$;

-- ============================================================
-- 0017 — la carrera del `orden`, un `cerrado` que no se reabre solo, y
-- guardar_precios() atómico. Bloque propio con sus propias filas: no
-- reusa las de 0012/0013 arriba porque esas ya quedan en un estado
-- particular al final de sus propios bloques (con rollback, así que no
-- hay colisión de ids — es solo para no depender de ese estado).
-- ============================================================
begin;

insert into organizadores (id, slug, nombre) values
  ('01700017-0017-4017-8017-000000000001', 'prueba-0017', 'Prueba 0017');
insert into auth.users (id, email) values
  ('01700017-0017-4017-8017-000000000002', 'staff-0017@ticketera.local'),
  ('01700017-0017-4017-8017-000000000003', 'rrpp-0017@ticketera.local');
insert into perfiles (id, organizador_id, nombre, rol) values
  ('01700017-0017-4017-8017-000000000002', '01700017-0017-4017-8017-000000000001', 'Staff 0017', 'staff'),
  ('01700017-0017-4017-8017-000000000003', '01700017-0017-4017-8017-000000000001', 'Rrpp 0017', 'rrpp');
insert into eventos (id, organizador_id, slug, nombre, fecha) values
  ('01700017-0017-4017-8017-000000000004', '01700017-0017-4017-8017-000000000001', 'evento-a-0017', 'Evento A', current_date + 10),
  ('01700017-0017-4017-8017-000000000005', '01700017-0017-4017-8017-000000000001', 'evento-b-0017', 'Evento B', current_date + 10);
insert into tipo_entrada (id, organizador_id, evento_id, nombre) values
  ('01700017-0017-4017-8017-000000000006', '01700017-0017-4017-8017-000000000001', '01700017-0017-4017-8017-000000000004', 'General A'),
  ('01700017-0017-4017-8017-00000000000b', '01700017-0017-4017-8017-000000000001', '01700017-0017-4017-8017-000000000004', 'VIP A'),
  ('01700017-0017-4017-8017-000000000009', '01700017-0017-4017-8017-000000000001', '01700017-0017-4017-8017-000000000005', 'General B');
insert into evento_fase (id, organizador_id, evento_id, nombre, desde, hasta, orden) values
  ('01700017-0017-4017-8017-000000000007', '01700017-0017-4017-8017-000000000001', '01700017-0017-4017-8017-000000000004',
   'F1', now() - interval '1 hour', now() + interval '10 days', 0),
  ('01700017-0017-4017-8017-00000000000a', '01700017-0017-4017-8017-000000000001', '01700017-0017-4017-8017-000000000005',
   'F1-B', now() - interval '1 hour', now() + interval '10 days', 0);
insert into fase_precio (organizador_id, fase_id, tipo_id, precio, cupo) values
  ('01700017-0017-4017-8017-000000000001', '01700017-0017-4017-8017-000000000007',
   '01700017-0017-4017-8017-000000000006', 100, null),
  ('01700017-0017-4017-8017-000000000001', '01700017-0017-4017-8017-000000000007',
   '01700017-0017-4017-8017-00000000000b', 200, 30);

-- ── 1) unique(evento_id, orden): la base rechaza el empate ──
do $$
begin
  begin
    insert into evento_fase (id, organizador_id, evento_id, nombre, orden)
    values ('01700017-0017-4017-8017-000000000008', '01700017-0017-4017-8017-000000000001',
            '01700017-0017-4017-8017-000000000004', 'F1 duplicada', 0);
    raise exception 'TEST_FAIL: dejo insertar dos fases con el mismo orden en el mismo evento';
  exception
    when unique_violation then null;
  end;
  raise notice 'OK unique(evento_id, orden) rechaza el empate';
end $$;

-- ── 2) un evento cerrado no se reabre ni se despublica sin querer ──
update eventos set estado = 'cerrado' where id = '01700017-0017-4017-8017-000000000004';

do $$
begin
  set local role authenticated;
  perform set_config('request.jwt.claim.sub', '01700017-0017-4017-8017-000000000002', true);

  begin
    perform publicar_evento('01700017-0017-4017-8017-000000000004'::uuid, true);
    raise exception 'TEST_FAIL: reabrio a publicado un evento cerrado';
  exception when others then
    if sqlerrm not like 'Este evento está cerrado%' then raise; end if;
  end;

  begin
    perform publicar_evento('01700017-0017-4017-8017-000000000004'::uuid, false);
    raise exception 'TEST_FAIL: paso a borrador un evento cerrado';
  exception when others then
    if sqlerrm not like 'Este evento está cerrado%' then raise; end if;
  end;

  reset role;
  raise notice 'OK un evento cerrado no se publica ni se pasa a borrador desde publicar_evento()';
end $$;

do $$
begin
  if (select estado from eventos where id = '01700017-0017-4017-8017-000000000004') <> 'cerrado' then
    raise exception 'TEST_FAIL: el estado cerrado no se mantuvo';
  end if;
end $$;

update eventos set estado = 'borrador' where id = '01700017-0017-4017-8017-000000000004';

-- ── 3) guardar_precios(): atómico, valida pertenencia, exige rol ──
do $$
declare v_r jsonb; v_n int;
begin
  set local role authenticated;
  perform set_config('request.jwt.claim.sub', '01700017-0017-4017-8017-000000000002', true);

  -- guarda y borra en la misma llamada: sube el precio de TIPO A1 y, como
  -- TIPO A2 (VIP) no viene en la lista, su fila de precio desaparece.
  v_r := guardar_precios('01700017-0017-4017-8017-000000000004'::uuid,
    jsonb_build_array(jsonb_build_object(
      'fase_id', '01700017-0017-4017-8017-000000000007',
      'tipo_id', '01700017-0017-4017-8017-000000000006',
      'precio', 150, 'cupo', 50)));

  reset role;

  select count(*) into v_n from fase_precio where fase_id = '01700017-0017-4017-8017-000000000007';
  if v_n <> 1 then
    raise exception 'TEST_FAIL: deberia quedar una sola fila de precio en la fase, quedaron % (resultado %)', v_n, v_r;
  end if;
  if not exists (select 1 from fase_precio
                  where fase_id = '01700017-0017-4017-8017-000000000007'
                    and tipo_id = '01700017-0017-4017-8017-000000000006'
                    and precio = 150 and cupo = 50) then
    raise exception 'TEST_FAIL: el precio guardado no quedo como se mando: %', v_r;
  end if;
  raise notice 'OK guardar_precios guarda y borra en la misma llamada';
end $$;

-- una fase/tipo de otro evento se rechaza sin escribir NADA, ni siquiera
-- las filas válidas del mismo arreglo
do $$
begin
  set local role authenticated;
  perform set_config('request.jwt.claim.sub', '01700017-0017-4017-8017-000000000002', true);

  begin
    perform guardar_precios('01700017-0017-4017-8017-000000000004'::uuid,
      jsonb_build_array(
        jsonb_build_object('fase_id', '01700017-0017-4017-8017-000000000007',
                            'tipo_id', '01700017-0017-4017-8017-000000000006',
                            'precio', 999, 'cupo', null),
        jsonb_build_object('fase_id', '01700017-0017-4017-8017-00000000000a',
                            'tipo_id', '01700017-0017-4017-8017-000000000009',
                            'precio', 50, 'cupo', null)));
    raise exception 'TEST_FAIL: acepto una fase/tipo de otro evento';
  exception when others then
    if sqlerrm <> 'No encontramos esa fase o ese tipo en este evento' then raise; end if;
  end;

  reset role;

  if exists (select 1 from fase_precio
              where fase_id = '01700017-0017-4017-8017-000000000007'
                and tipo_id = '01700017-0017-4017-8017-000000000006'
                and precio = 999) then
    raise exception 'TEST_FAIL: escribio la fila valida del arreglo aunque la otra fuera de otro evento';
  end if;
  raise notice 'OK una fase/tipo de otro evento se rechaza sin escribir nada';
end $$;

-- un rrpp no puede llamarla
do $$
begin
  set local role authenticated;
  perform set_config('request.jwt.claim.sub', '01700017-0017-4017-8017-000000000003', true);

  begin
    perform guardar_precios('01700017-0017-4017-8017-000000000004'::uuid,
      jsonb_build_array(jsonb_build_object(
        'fase_id', '01700017-0017-4017-8017-000000000007',
        'tipo_id', '01700017-0017-4017-8017-000000000006',
        'precio', 1, 'cupo', null)));
    raise exception 'TEST_FAIL: un rrpp pudo llamar guardar_precios';
  exception when others then
    if sqlerrm <> 'Sin permiso' then raise; end if;
  end;

  reset role;
  raise notice 'OK un rrpp no puede llamar guardar_precios';
end $$;

-- ============================================================
-- 0024 — comision_de(): monto fijo, el acuerdo de la persona por encima
-- del default del evento, y el precio de la entrada nunca entra en la
-- cuenta. Bloque propio, fixtures propios (no reusa los de arriba: esos
-- ya se manipularon en sus propios pasos). Se reproduce el bug real de
-- Plataforma Puerta -la manilla subió de 60 a 70 y la comisión la siguió-
-- para confirmar que acá, con la comisión como dato separado, no pasa.
-- ============================================================
do $$
declare v_org   uuid := '02400024-0024-4024-8024-000000000001';
        v_rrpp  uuid := '02400024-0024-4024-8024-000000000002';
        v_ev    uuid := '02400024-0024-4024-8024-000000000003';
        v_tipo  uuid := '02400024-0024-4024-8024-000000000004';
        v_fase  uuid := '02400024-0024-4024-8024-000000000005';
begin
  insert into organizadores (id, slug, nombre) values
    (v_org, 'prueba-0024', 'Prueba 0024');
  insert into auth.users (id, email) values
    (v_rrpp, 'rrpp-0024@ticketera.local');
  insert into perfiles (id, organizador_id, nombre, rol) values
    (v_rrpp, v_org, 'Rrpp 0024', 'rrpp');
  insert into eventos (id, organizador_id, slug, nombre, fecha) values
    (v_ev, v_org, 'evento-0024', 'Evento 0024', current_date + 10);

  update eventos set comision_entrada = 15 where id = v_ev;

  -- sin acuerdo propio: gana el del evento
  update perfiles set comision_entrada = null where id = v_rrpp;
  if comision_de(v_rrpp, v_ev) <> 15 then
    raise exception 'TEST_FAIL: sin acuerdo propio deberia dar 15, dio %', comision_de(v_rrpp, v_ev);
  end if;

  -- con acuerdo propio: gana el de la persona
  update perfiles set comision_entrada = 25 where id = v_rrpp;
  if comision_de(v_rrpp, v_ev) <> 25 then
    raise exception 'TEST_FAIL: con acuerdo propio deberia dar 25, dio %', comision_de(v_rrpp, v_ev);
  end if;

  -- vuelve a depender del evento para lo que sigue
  update perfiles set comision_entrada = null where id = v_rrpp;

  -- el precio de la entrada NO entra en la cuenta: se sube de 60 a 70,
  -- calcada la subida real de la manilla en Plataforma Puerta, y la
  -- comision_de() tiene que quedarse exactamente donde estaba.
  insert into tipo_entrada (id, organizador_id, evento_id, nombre) values
    (v_tipo, v_org, v_ev, 'General');
  insert into evento_fase (id, organizador_id, evento_id, nombre, desde, hasta) values
    (v_fase, v_org, v_ev, 'F1', now() - interval '1 hour', now() + interval '10 days');
  insert into fase_precio (organizador_id, fase_id, tipo_id, precio, cupo) values
    (v_org, v_fase, v_tipo, 60, 50);

  if comision_de(v_rrpp, v_ev) <> 15 then
    raise exception 'TEST_FAIL: con la manilla a 60 deberia dar 15, dio %', comision_de(v_rrpp, v_ev);
  end if;

  update fase_precio set precio = 70 where fase_id = v_fase and tipo_id = v_tipo;
  if comision_de(v_rrpp, v_ev) <> 15 then
    raise exception 'TEST_FAIL: la comision se movio sola cuando subio el precio de la entrada, dio %', comision_de(v_rrpp, v_ev);
  end if;

  raise notice 'OK la comision es un monto fijo, con la de la persona por encima, y no se mueve con el precio';
end $$;

-- ============================================================
-- 0025 — la atribución del relacionador la resuelve el servidor
--
-- El slug de ?r= NO es único globalmente, solo por organizador (0024): dos
-- clientes distintos pueden cada uno tener su "nico". La cuenta real de
-- Nico (organizador amstel) ya tiene slug='nico' en esta base — este bloque
-- siembra OTRO organizador con OTRO relacionador que también se llama
-- 'nico', y confirma que el slug se repite sin chocar. Eso es lo que obliga
-- a crear-orden/index.ts a resolver siempre acotando por el organizador del
-- evento: resolver por slug solo, sin ese filtro, encontraría cualquiera de
-- los dos al azar.
-- ============================================================
do $$
declare v_otro uuid;
begin
  -- un relacionador de OTRO organizador no puede quedar atribuido acá
  insert into organizadores (id, slug, nombre)
  values ('cccccccc-0000-4000-8000-000000000009', 'otro-org', 'Otro');
  insert into auth.users (id, email) values
    ('dddddddd-0000-4000-8000-000000000009', 'ajeno@ticketera.local');
  insert into perfiles (id, organizador_id, nombre, rol, slug)
  values ('dddddddd-0000-4000-8000-000000000009',
          'cccccccc-0000-4000-8000-000000000009', 'Ajeno', 'rrpp', 'nico')
  returning id into v_otro;

  -- el mismo slug existe en los dos organizadores: eso tiene que poder pasar
  if (select count(*) from perfiles where slug = 'nico') < 2 then
    raise exception 'TEST_FAIL: el slug deberia poder repetirse entre organizadores';
  end if;
  raise notice 'OK el slug se repite entre organizadores y por eso hay que resolverlo con el del evento';
end $$;

-- ============================================================
-- 0026 — mis_ventas() y ventas_por_rrpp()
--
-- Tres cosas se prueban acá, y las tres son errores que ya pasaron:
--
-- 1) El aislamiento. Cada relacionador ve lo suyo y NADA más, y eso se
--    decide adentro de la función con auth.uid() — no con un parámetro
--    p_perfil que el navegador podría cambiar por el del compañero.
--    Se simula sesión con el mismo mecanismo que el resto del archivo:
--    `set local role authenticated` + set_config del claim sub.
--
-- 2) La comisión NO se mueve con el precio de la entrada. Se venden las
--    entradas a 100, se verifica la comisión, se sube el precio a 300 y
--    la comisión tiene que quedar exactamente donde estaba. Es el bug de
--    Plataforma Puerta (la manilla subió de 60 a 70 y la comisión la
--    siguió sola) llevado al reporte, no solo a comision_de().
--
-- 3) Las entradas se cuentan de `entradas`, no de órdenes. Una de las
--    órdenes de A es un combo de 2 manillas: es UNA orden, UN item con
--    cantidad 1, y DOS entradas. Contar órdenes daría 1 donde hay 2, que
--    es el mismo error del cupo.
--
-- Los datos se siembran por el camino real (crear_orden con p_rrpp +
-- emitir_orden), no con inserts a mano: así el test también cubre que la
-- atribución que escribe crear-orden es la que después lee el reporte.
-- ============================================================
do $$
declare v_org    uuid := '02600026-0026-4026-8026-000000000001';
        v_a      uuid := '02600026-0026-4026-8026-000000000002';  -- relacionador A
        v_b      uuid := '02600026-0026-4026-8026-000000000003';  -- relacionador B
        v_staff  uuid := '02600026-0026-4026-8026-000000000004';
        v_sin    uuid := '02600026-0026-4026-8026-000000000005';  -- relacionador sin ventas
        v_ev     uuid := '02600026-0026-4026-8026-000000000006';
        v_ev2    uuid := '02600026-0026-4026-8026-000000000007';
        v_tipo   uuid := '02600026-0026-4026-8026-000000000008';
        v_combo  uuid := '02600026-0026-4026-8026-000000000009';
        v_fase   uuid := '02600026-0026-4026-8026-00000000000a';
        v_tipo2  uuid := '02600026-0026-4026-8026-00000000000b';
        v_fase2  uuid := '02600026-0026-4026-8026-00000000000c';
        -- otro tenant, para el corte por mi_organizador()
        v_org2   uuid := '02600026-0026-4026-8026-00000000000d';
        v_c      uuid := '02600026-0026-4026-8026-00000000000e';
        v_ev3    uuid := '02600026-0026-4026-8026-00000000000f';
        v_tipo3  uuid := '02600026-0026-4026-8026-000000000010';
        v_fase3  uuid := '02600026-0026-4026-8026-000000000011';
        v_o1 uuid; v_o2 uuid; v_o3 uuid; v_o4 uuid; v_o5 uuid; v_o6 uuid; v_o7 uuid;
        v_r jsonb; v_f jsonb;
begin
  insert into organizadores (id, slug, nombre) values
    (v_org,  'prueba-0026',  'Prueba 0026'),
    (v_org2, 'prueba-0026b', 'Prueba 0026 otro');
  insert into auth.users (id, email) values
    (v_a,     'rrpp-a-0026@ticketera.local'),
    (v_b,     'rrpp-b-0026@ticketera.local'),
    (v_staff, 'staff-0026@ticketera.local'),
    (v_sin,   'rrpp-sin-0026@ticketera.local'),
    (v_c,     'rrpp-c-0026@ticketera.local');
  insert into perfiles (id, organizador_id, nombre, rol, slug, comision_entrada) values
    (v_a,     v_org,  'Ana',    'rrpp',  'ana',    null),
    (v_b,     v_org,  'Beto',   'rrpp',  'beto',   20),   -- acuerdo propio
    (v_staff, v_org,  'Staff',  'staff', null,     null),
    (v_sin,   v_org,  'Sin Ventas', 'rrpp', 'sinventas', null),
    (v_c,     v_org2, 'Ceci',   'rrpp',  'ceci',   null);

  insert into eventos (id, organizador_id, slug, nombre, fecha, estado) values
    (v_ev,  v_org,  'evento-0026-a', 'Evento 0026 A', current_date + 10, 'publicado'),
    (v_ev2, v_org,  'evento-0026-b', 'Evento 0026 B', current_date + 20, 'publicado'),
    (v_ev3, v_org2, 'evento-0026-c', 'Evento 0026 C', current_date + 10, 'publicado');
  -- comisión por defecto del evento: 15 Bs por entrada
  update eventos set comision_entrada = 15 where id in (v_ev, v_ev2, v_ev3);

  insert into tipo_entrada (id, organizador_id, evento_id, nombre, manillas) values
    (v_tipo,  v_org,  v_ev,  'General', 1),
    (v_combo, v_org,  v_ev,  'Combo 2', 2),   -- una unidad = dos manillas = dos entradas
    (v_tipo2, v_org,  v_ev2, 'General B', 1),
    (v_tipo3, v_org2, v_ev3, 'General C', 1);
  insert into evento_fase (id, organizador_id, evento_id, nombre, desde, hasta) values
    (v_fase,  v_org,  v_ev,  'F1', now() - interval '1 hour', now() + interval '10 days'),
    (v_fase2, v_org,  v_ev2, 'F1', now() - interval '1 hour', now() + interval '10 days'),
    (v_fase3, v_org2, v_ev3, 'F1', now() - interval '1 hour', now() + interval '10 days');
  insert into fase_precio (organizador_id, fase_id, tipo_id, precio, cupo) values
    (v_org,  v_fase,  v_tipo,  100, null),
    (v_org,  v_fase,  v_combo, 200, null),
    (v_org,  v_fase2, v_tipo2,  80, null),
    (v_org2, v_fase3, v_tipo3, 100, null);

  -- ── ventas ──────────────────────────────────────────────
  -- A: 3 generales (300) + un combo de 2 manillas (200) en el evento A
  v_o1 := (crear_orden(v_ev, jsonb_build_array(jsonb_build_object('tipo_id', v_tipo, 'cantidad', 3)),
                       '{}'::jsonb, null::uuid, null::text, v_a)->>'orden')::uuid;
  perform emitir_orden(v_o1);
  v_o2 := (crear_orden(v_ev, jsonb_build_array(jsonb_build_object('tipo_id', v_combo, 'cantidad', 1)),
                       '{}'::jsonb, null::uuid, null::text, v_a)->>'orden')::uuid;
  perform emitir_orden(v_o2);
  -- una de las cinco se anula: no cuenta ni como entrada ni como comisión
  update entradas set estado = 'anulada'
   where id = (select id from entradas where orden_id = v_o1 order by created_at, id limit 1);

  -- B: 2 generales (200) en el evento A
  v_o3 := (crear_orden(v_ev, jsonb_build_array(jsonb_build_object('tipo_id', v_tipo, 'cantidad', 2)),
                       '{}'::jsonb, null::uuid, null::text, v_b)->>'orden')::uuid;
  perform emitir_orden(v_o3);

  -- ruido que NO tiene que aparecer: una orden de A que quedó pendiente
  -- (nadie pagó) y una venta pública sin relacionador
  v_o4 := (crear_orden(v_ev, jsonb_build_array(jsonb_build_object('tipo_id', v_tipo, 'cantidad', 1)),
                       '{}'::jsonb, null::uuid, null::text, v_a)->>'orden')::uuid;
  v_o5 := (crear_orden(v_ev, jsonb_build_array(jsonb_build_object('tipo_id', v_tipo, 'cantidad', 1)),
                       '{}'::jsonb, null::uuid, null::text, null::uuid)->>'orden')::uuid;
  perform emitir_orden(v_o5);

  -- A también vendió una en el evento B, para el caso p_evento = null
  v_o6 := (crear_orden(v_ev2, jsonb_build_array(jsonb_build_object('tipo_id', v_tipo2, 'cantidad', 1)),
                       '{}'::jsonb, null::uuid, null::text, v_a)->>'orden')::uuid;
  perform emitir_orden(v_o6);

  -- otro tenant: C vendió lo suyo en su propio evento
  v_o7 := (crear_orden(v_ev3, jsonb_build_array(jsonb_build_object('tipo_id', v_tipo3, 'cantidad', 4)),
                       '{}'::jsonb, null::uuid, null::text, v_c)->>'orden')::uuid;
  perform emitir_orden(v_o7);

  -- ── 1) A ve lo suyo y solo lo suyo ──────────────────────
  set local role authenticated;
  perform set_config('request.jwt.claim.sub', v_a::text, true);

  v_r := mis_ventas(v_ev);
  if jsonb_array_length(v_r) <> 1 then
    raise exception 'TEST_FAIL: A deberia tener una fila en el evento A, tiene %: %', jsonb_array_length(v_r), v_r;
  end if;
  v_f := v_r->0;
  if (v_f->>'entradas')::int <> 4 then
    raise exception 'TEST_FAIL: A vendio 5 entradas y una se anulo: deberian ser 4, dio % (%)', v_f->>'entradas', v_f;
  end if;
  if (v_f->>'recaudado')::numeric <> 500 then
    raise exception 'TEST_FAIL: A recaudo 500 (300 + 200), dio %', v_f->>'recaudado';
  end if;
  if (v_f->>'comision_unitaria')::numeric <> 15 then
    raise exception 'TEST_FAIL: A no tiene acuerdo propio, deberia cobrar los 15 del evento, dio %', v_f->>'comision_unitaria';
  end if;
  if (v_f->>'comision')::numeric <> 60 then
    raise exception 'TEST_FAIL: la comision de A deberia ser 4 x 15 = 60, dio %', v_f->>'comision';
  end if;
  if v_r::text like '%Beto%' or v_r::text like '%' || v_b::text || '%' then
    raise exception 'TEST_FAIL: mis_ventas de A menciona a B: %', v_r;
  end if;

  -- sin parámetro: los dos eventos donde vendió, el de más comisión primero
  v_r := mis_ventas();
  if jsonb_array_length(v_r) <> 2 then
    raise exception 'TEST_FAIL: A vendio en dos eventos, mis_ventas() devolvio %: %', jsonb_array_length(v_r), v_r;
  end if;
  if (v_r->0->>'evento_id')::uuid <> v_ev then
    raise exception 'TEST_FAIL: deberia ordenar por comision descendente, vino primero %', v_r->0;
  end if;
  if (v_r->0->>'evento_nombre') <> 'Evento 0026 A' then
    raise exception 'TEST_FAIL: falta el nombre del evento: %', v_r->0;
  end if;
  if (v_r->0->>'evento_fecha') is null then
    raise exception 'TEST_FAIL: falta la fecha del evento: %', v_r->0;
  end if;
  if (v_r->1->>'entradas')::int <> 1 or (v_r->1->>'comision')::numeric <> 15 then
    raise exception 'TEST_FAIL: en el evento B, A vendio 1 y le tocan 15: %', v_r->1;
  end if;

  -- ── 2) B ve lo suyo, con SU acuerdo ─────────────────────
  perform set_config('request.jwt.claim.sub', v_b::text, true);
  v_r := mis_ventas(v_ev);
  if jsonb_array_length(v_r) <> 1 then
    raise exception 'TEST_FAIL: B deberia tener una fila, tiene %: %', jsonb_array_length(v_r), v_r;
  end if;
  v_f := v_r->0;
  if (v_f->>'entradas')::int <> 2 then
    raise exception 'TEST_FAIL: B vendio 2 entradas, dio %', v_f->>'entradas';
  end if;
  if (v_f->>'comision')::numeric <> 40 then
    raise exception 'TEST_FAIL: B tiene acuerdo propio de 20: 2 x 20 = 40, dio %', v_f->>'comision';
  end if;
  if v_r::text like '%Ana%' or (v_f->>'recaudado')::numeric <> 200 then
    raise exception 'TEST_FAIL: B ve algo que no es suyo: %', v_r;
  end if;

  -- un relacionador sin una sola venta no ve un arreglo con basura, ve []
  perform set_config('request.jwt.claim.sub', v_sin::text, true);
  if mis_ventas() <> '[]'::jsonb then
    raise exception 'TEST_FAIL: un relacionador sin ventas deberia ver [], vio %', mis_ventas();
  end if;

  -- ── 3) un rrpp no puede ver el ranking de todos ─────────
  perform set_config('request.jwt.claim.sub', v_a::text, true);
  begin
    perform ventas_por_rrpp(v_ev);
    raise exception 'TEST_FAIL: un rrpp pudo llamar ventas_por_rrpp';
  exception when others then
    if sqlerrm <> 'Sin permiso' then raise; end if;
  end;

  -- ── 4) el staff sí, y ve a los dos, ordenados ───────────
  perform set_config('request.jwt.claim.sub', v_staff::text, true);
  v_r := ventas_por_rrpp(v_ev);
  if jsonb_array_length(v_r) <> 2 then
    raise exception 'TEST_FAIL: en el evento A vendieron dos relacionadores, vinieron %: %', jsonb_array_length(v_r), v_r;
  end if;
  if (v_r->0->>'perfil_id')::uuid <> v_a or (v_r->1->>'perfil_id')::uuid <> v_b then
    raise exception 'TEST_FAIL: deberia venir A (60) antes que B (40): %', v_r;
  end if;
  if (v_r->0->>'nombre') <> 'Ana' or (v_r->0->>'slug') <> 'ana' then
    raise exception 'TEST_FAIL: falta nombre o slug de la persona: %', v_r->0;
  end if;
  if (v_r->0->>'comision')::numeric <> 60 or (v_r->1->>'comision')::numeric <> 40 then
    raise exception 'TEST_FAIL: las comisiones del desglose no cuadran: %', v_r;
  end if;
  if v_r::text like '%Sin Ventas%' then
    raise exception 'TEST_FAIL: un relacionador sin ventas no deberia aparecer: %', v_r;
  end if;

  -- ── 5) multi-tenant: el evento del otro organizador no existe acá ──
  v_r := ventas_por_rrpp(v_ev3);
  if v_r <> '[]'::jsonb then
    raise exception 'TEST_FAIL: el staff de un organizador vio las ventas de OTRO organizador: %', v_r;
  end if;

  -- ── 6) sube el precio de la entrada: la comision NO se mueve ──
  reset role;
  update fase_precio set precio = 300 where fase_id = v_fase and tipo_id = v_tipo;

  set local role authenticated;
  perform set_config('request.jwt.claim.sub', v_a::text, true);
  v_f := mis_ventas(v_ev)->0;
  if (v_f->>'comision')::numeric <> 60 then
    raise exception 'TEST_FAIL: la comision se movio sola cuando subio el precio de la entrada: dio % en vez de 60', v_f->>'comision';
  end if;
  if (v_f->>'entradas')::int <> 4 then
    raise exception 'TEST_FAIL: cambio la cuenta de entradas al cambiar el precio: %', v_f;
  end if;
  if (v_f->>'recaudado')::numeric <> 500 then
    raise exception 'TEST_FAIL: lo recaudado se congela en la orden, no sigue al precio nuevo: dio %', v_f->>'recaudado';
  end if;

  reset role;
  raise notice 'OK cada relacionador ve solo lo suyo y la comision no sigue al precio';
end $$;

-- ============================================================
-- 0031 — el portero, probado por lo que NO puede
--
-- El portero trabaja toda la noche desde un teléfono prestado en la puerta
-- de un boliche. Si ese teléfono queda sobre la barra con la sesión
-- abierta, lo que importa no es lo que el portero sabe hacer sino lo que
-- la base le deja hacer a quien lo agarre. Por eso el test empieza por lo
-- que tiene que rebotar y recién al final comprueba lo único que sí puede.
--
-- Las tres escrituras (tipo_entrada, fase_precio, eventos) no tiran error:
-- la policy no matchea y el update toca cero filas, silencioso. Por eso no
-- alcanza con que no explote — hay que ir a mirar la fila después, con el
-- rol ya reseteado, y ver que sigue diciendo lo mismo.
--
-- `ordenes` es la que más importa de las lecturas negadas: ahí viven el
-- correo, el teléfono y el total del comprador. El portero necesita saber
-- si la manilla es buena, no quién la pagó ni cuánto.
-- ============================================================
do $$
declare v_org   uuid := '03100031-0031-4031-8031-000000000001';
        v_org2  uuid := '03100031-0031-4031-8031-000000000002';  -- el otro tenant
        v_port  uuid := '03100031-0031-4031-8031-000000000003';
        v_ev    uuid := '03100031-0031-4031-8031-000000000004';
        v_ev2   uuid := '03100031-0031-4031-8031-000000000005';
        v_tipo  uuid := '03100031-0031-4031-8031-000000000006';
        v_fase  uuid := '03100031-0031-4031-8031-000000000007';
        v_ord   uuid := '03100031-0031-4031-8031-000000000008';
        v_ent   uuid := '03100031-0031-4031-8031-000000000009';
        v_ent2  uuid := '03100031-0031-4031-8031-00000000000a';
        v_n int;
begin
  insert into organizadores (id, slug, nombre) values
    (v_org,  'prueba-0031',  'Prueba 0031'),
    (v_org2, 'prueba-0031b', 'Prueba 0031 otro');
  insert into auth.users (id, email) values (v_port, 'portero-0031@ticketera.local');

  -- Acá falla todo antes de la migración: perfiles_rol_check todavía no
  -- conoce 'portero'.
  insert into perfiles (id, organizador_id, nombre, rol) values
    (v_port, v_org, 'Un Portero', 'portero');

  insert into eventos (id, organizador_id, slug, nombre, fecha, estado) values
    (v_ev,  v_org,  'evento-0031',  'Evento 0031',  current_date + 10, 'publicado'),
    (v_ev2, v_org2, 'evento-0031b', 'Evento 0031 B', current_date + 10, 'publicado');
  insert into tipo_entrada (id, organizador_id, evento_id, nombre) values
    (v_tipo, v_org, v_ev, 'General');
  insert into evento_fase (id, organizador_id, evento_id, nombre, desde, hasta) values
    (v_fase, v_org, v_ev, 'F1', now() - interval '1 hour', now() + interval '10 days');
  insert into fase_precio (organizador_id, fase_id, tipo_id, precio, cupo) values
    (v_org, v_fase, v_tipo, 100, null);

  -- una orden con los datos del comprador, que es lo que el portero no tiene
  -- por qué ver
  insert into ordenes (id, organizador_id, evento_id, estado, expira_at,
                       comprador_nombre, comprador_email, comprador_telefono,
                       subtotal, fee, total)
  values (v_ord, v_org, v_ev, 'pagada', now() + interval '1 day',
          'Comprador', 'comprador@ejemplo.com', '70000000', 100, 7, 107);

  -- una entrada propia y una del otro tenant, para el corte de organizador
  insert into entradas (id, organizador_id, evento_id, orden_id, code, canal,
                        tipo_id, fase_id, cliente, precio) values
    (v_ent, v_org, v_ev, v_ord, 'PORTERO000AA', 'publico', v_tipo, v_fase, 'Comprador', 100);
  insert into entradas (id, organizador_id, evento_id, code, canal, precio) values
    (v_ent2, v_org2, v_ev2, 'PORTERO000BB', 'publico', 100);

  set local role authenticated;
  perform set_config('request.jwt.claim.sub', v_port::text, true);

  -- ── 1) no escribe el catálogo ni el evento ──────────────
  begin
    update tipo_entrada set nombre = 'Hackeado' where id = v_tipo;
  exception when others then null;
  end;
  begin
    update fase_precio set precio = 1 where fase_id = v_fase and tipo_id = v_tipo;
  exception when others then null;
  end;
  begin
    update eventos set nombre = 'Hackeado' where id = v_ev;
  exception when others then null;
  end;

  -- ── 2) no lee las órdenes ───────────────────────────────
  select count(*) into v_n from ordenes where id = v_ord;
  if v_n <> 0 then
    raise exception 'TEST_FAIL: el portero leyo una orden — ahi estan el correo, el telefono y el total';
  end if;

  -- ── 3) sí lee las entradas de SU organizador ────────────
  select count(*) into v_n from entradas where id = v_ent;
  if v_n <> 1 then
    raise exception 'TEST_FAIL: el portero no puede leer las entradas de su organizador, que es lo unico que necesita';
  end if;

  -- ── 4) y ninguna otra ───────────────────────────────────
  select count(*) into v_n from entradas where id = v_ent2;
  if v_n <> 0 then
    raise exception 'TEST_FAIL: el portero leyo una entrada de OTRO organizador';
  end if;

  -- ── 5) es_portero() se reconoce a sí mismo, puede_editar() lo rechaza ──
  if not es_portero() then
    raise exception 'TEST_FAIL: es_portero() dijo que no para un perfil con rol portero';
  end if;
  if puede_editar() then
    raise exception 'TEST_FAIL: puede_editar() dejo pasar al portero';
  end if;

  reset role;

  -- Las escrituras de arriba no tiraron error: tocaron cero filas. Se
  -- comprueba mirando la fila, no atrapando la excepción que no hubo.
  if exists (select 1 from tipo_entrada where id = v_tipo and nombre = 'Hackeado') then
    raise exception 'TEST_FAIL: el portero cambio el nombre de un tipo de entrada';
  end if;
  if exists (select 1 from fase_precio where fase_id = v_fase and tipo_id = v_tipo and precio = 1) then
    raise exception 'TEST_FAIL: el portero cambio un precio';
  end if;
  if exists (select 1 from eventos where id = v_ev and nombre = 'Hackeado') then
    raise exception 'TEST_FAIL: el portero cambio el nombre del evento';
  end if;

  raise notice 'OK el portero lee las entradas de su organizador y nada mas';
end $$;

-- ============================================================
-- 0032 — validar, rechazar y deshacer
--
-- Este bloque prueba los ESTADOS. La carrera de verdad no se puede probar
-- acá adentro: dos sesiones no se ven los datos hasta que alguien
-- commitea, y este archivo termina en rollback a propósito. Vive aparte,
-- en supabase/tests/carrera-puerta.py, con dos sesiones reales y un
-- pg_sleep entre el update y el commit.
--
-- Lo que sí se prueba acá, que es lo que se discute en la puerta:
--
-- 1) Validar dos veces da 'valida' y después 'usada' CON la hora del
--    primer ingreso. Sin esa hora no hay con qué contestarle a alguien
--    que jura que no entró.
-- 2) La fila queda con UN solo used_at. El segundo escaneo no lo pisa:
--    si lo pisara, la hora del primer ingreso se perdería justo cuando
--    hace falta.
-- 3) `anulada` se responde distinto de `no_existe`. Son la misma cara para
--    quien está afuera pero no para el portero: una existió y alguien la
--    dio de baja, la otra nunca existió. Con la primera hay a quién
--    llamar.
-- 4) El modo filtro no consume: la entrada queda como estaba.
-- 5) Deshacer la devuelve a 'valida' y le borra la hora, porque en la
--    puerta se escanea de más.
-- 6) La entrada de otro organizador es 'no_existe', y sigue intacta. Es
--    el caso que la RLS no cubre sola: las tres funciones son security
--    definer y se saltean las policies, así que el corte de tenant tiene
--    que estar escrito adentro del where.
-- ============================================================
do $$
declare v_org   uuid := '03200032-0032-4032-8032-000000000001';
        v_org2  uuid := '03200032-0032-4032-8032-000000000002';
        v_port  uuid := '03200032-0032-4032-8032-000000000003';
        v_staff uuid := '03200032-0032-4032-8032-000000000004';
        v_rrpp  uuid := '03200032-0032-4032-8032-000000000005';
        v_ev    uuid := '03200032-0032-4032-8032-000000000006';
        v_ev2   uuid := '03200032-0032-4032-8032-000000000007';
        v_tipo  uuid := '03200032-0032-4032-8032-000000000008';
        v_fase  uuid := '03200032-0032-4032-8032-000000000009';
        v_ok    uuid := '03200032-0032-4032-8032-00000000000a';
        v_anu   uuid := '03200032-0032-4032-8032-00000000000b';
        v_aje   uuid := '03200032-0032-4032-8032-00000000000c';
        v_otra  uuid := '03200032-0032-4032-8032-00000000000d';
        c_ok  text := 'BCDFGH234567';
        c_anu text := 'JKLMNP234567';
        c_aje text := 'QRSTVW234567';
        c_otra text := 'WXZBCD234567';
        v_r jsonb; v_primera timestamptz; v_n int;
begin
  insert into organizadores (id, slug, nombre) values
    (v_org,  'prueba-0032',  'Prueba 0032'),
    (v_org2, 'prueba-0032b', 'Prueba 0032 otro');
  insert into auth.users (id, email) values
    (v_port,  'portero-0032@ticketera.local'),
    (v_staff, 'staff-0032@ticketera.local'),
    (v_rrpp,  'rrpp-0032@ticketera.local');
  insert into perfiles (id, organizador_id, nombre, rol) values
    (v_port,  v_org, 'Portero 0032', 'portero'),
    (v_staff, v_org, 'Staff 0032',   'staff'),
    (v_rrpp,  v_org, 'Rrpp 0032',    'rrpp');
  insert into eventos (id, organizador_id, slug, nombre, fecha, estado) values
    (v_ev,  v_org,  'evento-0032',  'Evento 0032',   current_date + 10, 'publicado'),
    (v_ev2, v_org2, 'evento-0032b', 'Evento 0032 B', current_date + 10, 'publicado');
  insert into tipo_entrada (id, organizador_id, evento_id, nombre) values
    (v_tipo, v_org, v_ev, 'General');
  insert into evento_fase (id, organizador_id, evento_id, nombre, desde, hasta) values
    (v_fase, v_org, v_ev, 'F1', now() - interval '1 hour', now() + interval '10 days');

  insert into entradas (id, organizador_id, evento_id, code, canal, tipo_id, fase_id,
                        cliente, precio, estado) values
    (v_ok,   v_org,  v_ev,  c_ok,   'publico', v_tipo, v_fase, 'Ana Perez',  100, 'valida'),
    (v_anu,  v_org,  v_ev,  c_anu,  'publico', v_tipo, v_fase, 'Beto Anulado', 100, 'anulada'),
    (v_otra, v_org,  v_ev,  c_otra, 'rrpp',    v_tipo, v_fase, 'Cami Filtro', 100, 'valida');
  -- misma combinación de code en OTRO organizador: el unique es por evento,
  -- así que esto es legal y es justo el caso peligroso
  insert into entradas (id, organizador_id, evento_id, code, canal, precio, estado) values
    (v_aje, v_org2, v_ev2, c_aje, 'publico', 100, 'valida');

  set local role authenticated;
  perform set_config('request.jwt.claim.sub', v_port::text, true);

  -- ── 1) primer escaneo: valida ───────────────────────────
  -- de paso en minúsculas y con espacios: el QR se lee con la cámara y lo
  -- que llega no siempre viene limpio
  v_r := validar_entrada(v_ev, '  bcdfgh234567  ');
  if v_r->>'resultado' <> 'valida' then
    raise exception 'TEST_FAIL: el primer escaneo deberia dar valida, dio %', v_r;
  end if;
  if v_r->>'cliente' <> 'Ana Perez' then
    raise exception 'TEST_FAIL: falta el nombre de quien entra: %', v_r;
  end if;
  select used_at into v_primera from entradas where id = v_ok;
  if v_primera is null then
    raise exception 'TEST_FAIL: no quedo la hora de ingreso';
  end if;

  -- ── 2) segundo escaneo: usada, con la hora del primero ──
  v_r := validar_entrada(v_ev, c_ok);
  if v_r->>'resultado' <> 'usada' then
    raise exception 'TEST_FAIL: el segundo escaneo deberia dar usada, dio %', v_r;
  end if;
  if (v_r->>'used_at')::timestamptz <> v_primera then
    raise exception 'TEST_FAIL: la respuesta tiene que traer la hora del PRIMER ingreso (%), trajo %',
      v_primera, v_r->>'used_at';
  end if;
  select count(*) into v_n from entradas
   where id = v_ok and used_at = v_primera and estado = 'usada';
  if v_n <> 1 then
    raise exception 'TEST_FAIL: el segundo escaneo piso el used_at del primero';
  end if;
  if (select portero_id from entradas where id = v_ok) <> v_port then
    raise exception 'TEST_FAIL: no quedo registrado quien la marco';
  end if;

  -- ── 3) deshacer: vuelve a valida y sin hora ─────────────
  v_r := descheckin_entrada(v_ev, c_ok);
  if v_r->>'resultado' <> 'valida' then
    raise exception 'TEST_FAIL: deshacer deberia devolverla a valida, dio %', v_r;
  end if;
  select count(*) into v_n from entradas
   where id = v_ok and estado = 'valida' and used_at is null and portero_id is null;
  if v_n <> 1 then
    raise exception 'TEST_FAIL: deshacer dejo la fila a medio camino';
  end if;

  -- deshacer una que no está usada no inventa nada
  v_r := descheckin_entrada(v_ev, c_ok);
  if v_r->>'resultado' = 'usada' then
    raise exception 'TEST_FAIL: deshacer una entrada valida no deberia decir usada: %', v_r;
  end if;

  -- ── 4) modo filtro: rechaza sin consumir ────────────────
  v_r := marcar_filtro_entrada(v_ev, c_otra);
  if (v_r->>'filtro')::boolean is not true then
    raise exception 'TEST_FAIL: el modo filtro deberia decir que filtro: %', v_r;
  end if;
  select count(*) into v_n from entradas
   where id = v_otra and estado = 'valida' and used_at is null;
  if v_n <> 1 then
    raise exception 'TEST_FAIL: el modo filtro consumio la entrada — tenia que quedar valida';
  end if;

  -- ── 5) anulada NO es no_existe ──────────────────────────
  v_r := validar_entrada(v_ev, c_anu);
  if v_r->>'resultado' <> 'anulada' then
    raise exception 'TEST_FAIL: una anulada tiene que decir anulada, dijo %', v_r;
  end if;
  v_r := validar_entrada(v_ev, 'ZZZZZZZZZZZZ');
  if v_r->>'resultado' <> 'no_existe' then
    raise exception 'TEST_FAIL: un code inventado tiene que decir no_existe, dijo %', v_r;
  end if;

  -- ── 6) la entrada de otro organizador no existe, y sigue intacta ──
  v_r := validar_entrada(v_ev2, c_aje);
  if v_r->>'resultado' <> 'no_existe' then
    raise exception 'TEST_FAIL: el portero de un organizador vio la entrada de OTRO: %', v_r;
  end if;
  -- Este count va con el rol reseteado a propósito: leído desde la sesión
  -- del portero daría cero por la RLS y el test pasaría sin haber mirado
  -- nada. Lo que hay que comprobar es que la fila del otro tenant sigue
  -- entera, y para eso hay que poder verla.
  reset role;
  select count(*) into v_n from entradas where id = v_aje and estado = 'valida' and used_at is null;
  if v_n <> 1 then
    raise exception 'TEST_FAIL: el portero de un organizador CONSUMIO la entrada de otro';
  end if;
  set local role authenticated;

  -- ── 7) un rrpp no valida nada ───────────────────────────
  perform set_config('request.jwt.claim.sub', v_rrpp::text, true);
  begin
    perform validar_entrada(v_ev, c_otra);
    raise exception 'TEST_FAIL: un rrpp pudo validar una entrada';
  exception when others then
    if sqlerrm <> 'Sin permiso' then raise; end if;
  end;
  begin
    perform descheckin_entrada(v_ev, c_otra);
    raise exception 'TEST_FAIL: un rrpp pudo deshacer un ingreso';
  exception when others then
    if sqlerrm <> 'Sin permiso' then raise; end if;
  end;

  -- ── 8) el staff sí: puede_editar() también abre la puerta ──
  perform set_config('request.jwt.claim.sub', v_staff::text, true);
  v_r := validar_entrada(v_ev, c_otra);
  if v_r->>'resultado' <> 'valida' then
    raise exception 'TEST_FAIL: un staff tendria que poder validar, dio %', v_r;
  end if;

  reset role;
  raise notice 'OK validar consume una sola vez, filtro no consume, deshacer devuelve y anulada no es no_existe';
end $$;

rollback;
