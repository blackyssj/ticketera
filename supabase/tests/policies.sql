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
-- 0029 — asignar_mesa() / liberar_mesa()
--
-- La prueba que importa es la de dos órdenes peleando por una mesa. Acá
-- corre secuencial, dentro de una sola sesión: la segunda asignación tiene
-- que fallar con una frase que se entienda y la mesa tiene que quedar con
-- la primera. Eso verifica el resultado del candado, no el candado.
--
-- El candado de verdad —dos sesiones a la vez— no se puede montar desde
-- este archivo: scripts/sql.py manda el .sql entero en un POST a la API de
-- gestión, o sea UNA conexión y UNA transacción por corrida, y no hay
-- forma de dejarla abierta mientras arranca otra. Dos corridas en paralelo
-- tampoco alcanzan: la segunda sesión no vería los datos sembrados por la
-- primera hasta que los commitee, y este archivo no commitea nada contra
-- la base real. Queda dicho acá para que nadie lo lea como "ya está
-- probado".
--
-- Lo que sí queda cubierto: la condición vive adentro del `update` (0029),
-- que es lo que hace que las dos sesiones se serialicen sobre la fila y la
-- segunda re-evalúe el where; y el índice único parcial sobre
-- ordenes.mesa_asignada_id, que se prueba abajo a mano y atrapa el empate
-- incluso si alguien esquiva la función.
--
-- El resto: el reparto es del equipo y NINGÚN relacionador asigna —ni
-- siquiera las mesas de las órdenes que vendió él—, reasignar libera la
-- mesa vieja, y una mesa de otro evento o de otro tenant se rechaza.
-- ============================================================
do $$
declare v_org   uuid := '02900029-0029-4029-8029-000000000001';
        v_org2  uuid := '02900029-0029-4029-8029-000000000002';   -- otro tenant
        v_a     uuid := '02900029-0029-4029-8029-000000000003';   -- relacionador A
        v_b     uuid := '02900029-0029-4029-8029-000000000004';   -- relacionador B
        v_staff uuid := '02900029-0029-4029-8029-000000000005';
        v_otro  uuid := '02900029-0029-4029-8029-000000000006';   -- staff del OTRO tenant
        v_ev    uuid := '02900029-0029-4029-8029-000000000007';
        v_ev2   uuid := '02900029-0029-4029-8029-000000000008';   -- mismo tenant, otro evento
        v_ev3   uuid := '02900029-0029-4029-8029-000000000009';   -- evento del otro tenant
        v_tipo  uuid := '02900029-0029-4029-8029-00000000000a';
        v_tipo3 uuid := '02900029-0029-4029-8029-00000000000b';
        v_fase  uuid := '02900029-0029-4029-8029-00000000000c';
        v_fase3 uuid := '02900029-0029-4029-8029-00000000000d';
        v_m1    uuid := '02900029-0029-4029-8029-000000000011';   -- M1, evento A
        v_m2    uuid := '02900029-0029-4029-8029-000000000012';   -- M2, evento A
        v_m3    uuid := '02900029-0029-4029-8029-000000000013';   -- M3, evento A
        v_mx    uuid := '02900029-0029-4029-8029-000000000014';   -- del evento B
        v_mz    uuid := '02900029-0029-4029-8029-000000000015';   -- del otro tenant
        v_o1 uuid; v_o2 uuid; v_o3 uuid;
        v_r jsonb; v_est text; v_ord uuid; v_asig uuid;
begin
  insert into organizadores (id, slug, nombre) values
    (v_org,  'prueba-0029',  'Prueba 0029'),
    (v_org2, 'prueba-0029b', 'Prueba 0029 otro');
  insert into auth.users (id, email) values
    (v_a,     'rrpp-a-0029@ticketera.local'),
    (v_b,     'rrpp-b-0029@ticketera.local'),
    (v_staff, 'staff-0029@ticketera.local'),
    (v_otro,  'staff-otro-0029@ticketera.local');
  insert into perfiles (id, organizador_id, nombre, rol, slug) values
    (v_a,     v_org,  'Ana',        'rrpp',  'ana-0029'),
    (v_b,     v_org,  'Beto',       'rrpp',  'beto-0029'),
    (v_staff, v_org,  'Staff',      'staff', null),
    (v_otro,  v_org2, 'Staff Otro', 'staff', null);

  insert into eventos (id, organizador_id, slug, nombre, fecha, estado) values
    (v_ev,  v_org,  'evento-0029-a', 'Evento 0029 A', current_date + 10, 'publicado'),
    (v_ev2, v_org,  'evento-0029-b', 'Evento 0029 B', current_date + 20, 'publicado'),
    (v_ev3, v_org2, 'evento-0029-c', 'Evento 0029 C', current_date + 10, 'publicado');
  -- el combo se vende como producto (0015): el comprador paga esto, no una
  -- chapa del plano. La mesa física se la da el equipo después, que es de
  -- lo que va toda esta prueba.
  insert into tipo_entrada (id, organizador_id, evento_id, nombre, categoria, manillas) values
    (v_tipo,  v_org,  v_ev,  'Combo Sabados', 'mesa', 8),
    (v_tipo3, v_org2, v_ev3, 'General C',     'entrada', 1);
  insert into evento_fase (id, organizador_id, evento_id, nombre, desde, hasta) values
    (v_fase,  v_org,  v_ev,  'F1', now() - interval '1 hour', now() + interval '10 days'),
    (v_fase3, v_org2, v_ev3, 'F1', now() - interval '1 hour', now() + interval '10 days');
  insert into fase_precio (organizador_id, fase_id, tipo_id, precio, cupo) values
    (v_org,  v_fase,  v_tipo,  1200, null),
    (v_org2, v_fase3, v_tipo3,  100, null);

  -- las mesas físicas: tres del evento A, una del evento B del mismo
  -- organizador y una del otro tenant
  insert into mesas (id, organizador_id, evento_id, etiqueta, x, y, w, precio, manillas) values
    (v_m1, v_org,  v_ev,  'M1', 10, 10, 5, 1200, 8),
    (v_m2, v_org,  v_ev,  'M2', 20, 10, 5, 1200, 8),
    (v_m3, v_org,  v_ev,  'M3', 30, 10, 5, 1200, 8),
    (v_mx, v_org,  v_ev2, 'X1', 10, 10, 5, 1200, 8),
    (v_mz, v_org2, v_ev3, 'Z1', 10, 10, 5, 1200, 8);

  -- dos ventas pagadas, cada una de su relacionador, por el camino real
  v_o1 := (crear_orden(v_ev, jsonb_build_array(jsonb_build_object('tipo_id', v_tipo, 'cantidad', 1)),
                       '{"nombre":"Juan Perez"}'::jsonb, null::uuid, null::text, v_a)->>'orden')::uuid;
  perform emitir_orden(v_o1);
  v_o2 := (crear_orden(v_ev, jsonb_build_array(jsonb_build_object('tipo_id', v_tipo, 'cantidad', 1)),
                       '{"nombre":"Sofia Rojas"}'::jsonb, null::uuid, null::text, v_b)->>'orden')::uuid;
  perform emitir_orden(v_o2);
  -- una tercera que quedó pendiente: con ella se ve que la mesa queda
  -- 'reservada' y no 'pagada' cuando todavía nadie pagó
  v_o3 := (crear_orden(v_ev, jsonb_build_array(jsonb_build_object('tipo_id', v_tipo, 'cantidad', 1)),
                       '{"nombre":"Pendiente"}'::jsonb, null::uuid, null::text, v_a)->>'orden')::uuid;

  -- ── 1) el reparto es del equipo: ningun relacionador asigna ──
  -- Ni siquiera la mesa de una orden que vendió él. Dos personas
  -- repartiendo el mismo salón es como dos grupos terminan parados frente
  -- a la misma mesa, y eso no se arregla con un update.
  set local role authenticated;
  perform set_config('request.jwt.claim.sub', v_a::text, true);
  begin
    perform asignar_mesa(v_o1, v_m1);   -- v_o1 la vendio A: da igual
    raise exception 'TEST_FAIL: un relacionador asigno la mesa de su propia venta';
  exception when others then
    if sqlerrm <> 'Sin permiso' then raise; end if;
  end;
  begin
    perform liberar_mesa(v_o1);
    raise exception 'TEST_FAIL: un relacionador libero la mesa de su propia venta';
  exception when others then
    if sqlerrm <> 'Sin permiso' then raise; end if;
  end;
  -- y menos todavia una orden de otro
  perform set_config('request.jwt.claim.sub', v_b::text, true);
  begin
    perform asignar_mesa(v_o1, v_m1);
    raise exception 'TEST_FAIL: un relacionador asigno la mesa de una venta ajena';
  exception when others then
    if sqlerrm <> 'Sin permiso' then raise; end if;
  end;

  reset role;
  select orden_id, estado into v_ord, v_est from mesas where id = v_m1;
  if v_ord is not null or v_est <> 'disponible' then
    raise exception 'TEST_FAIL: el intento sin permiso igual toco la mesa: % (%)', v_ord, v_est;
  end if;
  raise notice 'OK el relacionador vende el combo pero no reparte el salon';

  -- el staff del otro tenant tampoco, aunque puede_editar() le diga que si
  set local role authenticated;
  perform set_config('request.jwt.claim.sub', v_otro::text, true);
  begin
    perform asignar_mesa(v_o1, v_m1);
    raise exception 'TEST_FAIL: el staff de otro organizador acomodo una orden ajena';
  exception when others then
    if sqlerrm <> 'Sin permiso' then raise; end if;
  end;
  raise notice 'OK puede_editar() no alcanza sin el corte de organizador';

  -- ── 2) dos ordenes, una mesa ────────────────────────────
  perform set_config('request.jwt.claim.sub', v_staff::text, true);

  v_r := asignar_mesa(v_o1, v_m1);
  if (v_r->>'ok')::boolean is not true then
    raise exception 'TEST_FAIL: el staff no pudo asignar una mesa libre: %', v_r;
  end if;
  if (v_r->>'etiqueta') <> 'M1' then
    raise exception 'TEST_FAIL: deberia devolver la etiqueta de la mesa: %', v_r;
  end if;
  if (v_r->>'estado') <> 'pagada' then
    raise exception 'TEST_FAIL: la orden esta pagada, la mesa deberia quedar pagada: %', v_r;
  end if;

  -- la segunda orden pide la misma mesa: rebota, y con una frase que se
  -- entienda parado frente al cliente
  v_r := asignar_mesa(v_o2, v_m1);
  if (v_r->>'ok')::boolean is not false then
    raise exception 'TEST_FAIL: reasigno una mesa ya tomada sin liberarla: %', v_r;
  end if;
  if (v_r->>'codigo') <> 'MESA_TOMADA' then
    raise exception 'TEST_FAIL: el codigo deberia ser MESA_TOMADA, dio %', v_r;
  end if;
  -- el mensaje se muestra tal cual: tiene que decir CUAL mesa y DE QUIEN
  if (v_r->>'motivo') not like '%M1%' or (v_r->>'motivo') not like '%Juan Perez%' then
    raise exception 'TEST_FAIL: el motivo no dice cual mesa ni a quien esta asignada: %', v_r->>'motivo';
  end if;

  reset role;
  select orden_id, estado into v_ord, v_est from mesas where id = v_m1;
  if v_ord <> v_o1 or v_est <> 'pagada' then
    raise exception 'TEST_FAIL: la mesa tenia que quedar con la primera orden, quedo con % (%)', v_ord, v_est;
  end if;
  select mesa_asignada_id into v_asig from ordenes where id = v_o2;
  if v_asig is not null then
    raise exception 'TEST_FAIL: la orden que perdio quedo con mesa_asignada_id = %', v_asig;
  end if;
  raise notice 'OK dos ordenes por una mesa: gana la primera y la segunda se entera por que';

  -- ── 3) reasignar libera la mesa anterior ───────────────
  set local role authenticated;
  perform set_config('request.jwt.claim.sub', v_staff::text, true);
  v_r := asignar_mesa(v_o1, v_m2);
  if (v_r->>'ok')::boolean is not true then
    raise exception 'TEST_FAIL: no se pudo cambiar de mesa al cliente: %', v_r;
  end if;
  if (v_r->>'mesa_liberada')::uuid <> v_m1 then
    raise exception 'TEST_FAIL: deberia avisar que solto la M1: %', v_r;
  end if;

  reset role;
  select orden_id, estado into v_ord, v_est from mesas where id = v_m1;
  if v_ord is not null or v_est <> 'disponible' then
    raise exception 'TEST_FAIL: la M1 quedo ocupada por una orden que ya se sento en otra: % (%)', v_ord, v_est;
  end if;
  select orden_id into v_ord from mesas where id = v_m2;
  select mesa_asignada_id into v_asig from ordenes where id = v_o1;
  if v_ord <> v_o1 or v_asig <> v_m2 then
    raise exception 'TEST_FAIL: los dos lados no quedaron de acuerdo: mesa.orden_id=% orden.mesa=%', v_ord, v_asig;
  end if;

  -- repetir la misma asignacion no rompe ni miente: avisa que ya estaba
  set local role authenticated;
  perform set_config('request.jwt.claim.sub', v_staff::text, true);
  v_r := asignar_mesa(v_o1, v_m2);
  if (v_r->>'ok')::boolean is not true or (v_r->>'repetida')::boolean is not true then
    raise exception 'TEST_FAIL: reasignar la misma mesa a la misma orden deberia ser repetida: %', v_r;
  end if;
  raise notice 'OK cambiar de mesa libera la anterior y no deja mesas muertas';

  -- ── 4) una mesa de otro evento se rechaza ──────────────
  v_r := asignar_mesa(v_o1, v_mx);
  if (v_r->>'ok')::boolean is not false or (v_r->>'codigo') <> 'MESA_DE_OTRO_EVENTO' then
    raise exception 'TEST_FAIL: acepto una mesa de otro evento: %', v_r;
  end if;

  -- y una de otro organizador se contesta como inexistente: confirmar la
  -- etiqueta ya seria contarle a un tenant que tiene el otro
  v_r := asignar_mesa(v_o1, v_mz);
  if (v_r->>'ok')::boolean is not false or (v_r->>'codigo') <> 'MESA_INEXISTENTE' then
    raise exception 'TEST_FAIL: una mesa de otro tenant no deberia ni reconocerse: %', v_r;
  end if;
  if (v_r::text) like '%Z1%' then
    raise exception 'TEST_FAIL: filtro la etiqueta de una mesa de otro organizador: %', v_r;
  end if;

  reset role;
  select orden_id into v_ord from mesas where id = v_mz;
  if v_ord is not null then
    raise exception 'TEST_FAIL: escribio en una mesa de otro tenant';
  end if;
  raise notice 'OK una mesa de otro evento o de otro tenant no se asigna';

  -- ── 5) orden pendiente: la mesa queda reservada, no pagada ──
  set local role authenticated;
  perform set_config('request.jwt.claim.sub', v_staff::text, true);
  v_r := asignar_mesa(v_o3, v_m3);
  if (v_r->>'ok')::boolean is not true or (v_r->>'estado') <> 'reservada' then
    raise exception 'TEST_FAIL: sobre una orden pendiente la mesa deberia quedar reservada: %', v_r;
  end if;

  -- ── 6) liberar: la misma historia al reves ─────────────
  v_r := liberar_mesa(v_o1);
  if (v_r->>'ok')::boolean is not true or (v_r->>'libero')::boolean is not true then
    raise exception 'TEST_FAIL: no se pudo liberar la mesa de la orden: %', v_r;
  end if;
  reset role;
  select orden_id, estado into v_ord, v_est from mesas where id = v_m2;
  select mesa_asignada_id into v_asig from ordenes where id = v_o1;
  if v_ord is not null or v_est <> 'disponible' or v_asig is not null then
    raise exception 'TEST_FAIL: liberar dejo los dos lados a medias: mesa=%/% orden=%', v_ord, v_est, v_asig;
  end if;

  -- liberada la M2, recien ahora se le puede dar a la otra orden
  set local role authenticated;
  perform set_config('request.jwt.claim.sub', v_staff::text, true);
  v_r := asignar_mesa(v_o2, v_m2);
  if (v_r->>'ok')::boolean is not true then
    raise exception 'TEST_FAIL: la mesa liberada no se pudo reasignar: %', v_r;
  end if;
  reset role;
  raise notice 'OK liberar devuelve la mesa al ruedo y pide el mismo permiso que asignar';

  -- ── 7) el candado de la tabla, no el de la funcion ─────
  -- Si alguien esquiva asignar_mesa() y escribe ordenes a mano —el staff
  -- puede, la policy `ordenes escribir` se lo permite— el indice unico
  -- parcial tiene que atrapar el empate igual. v_o3 tiene la M3; darle
  -- ademas la M2, que ya es de v_o2, tiene que rebotar.
  begin
    update ordenes set mesa_asignada_id = v_m2 where id = v_o3;
    raise exception 'TEST_FAIL: dos ordenes quedaron con la misma mesa_asignada_id';
  exception when unique_violation then null;
  end;
  raise notice 'OK el indice unico impide dos ordenes con la misma mesa aunque se esquive la funcion';
end $$;

rollback;
