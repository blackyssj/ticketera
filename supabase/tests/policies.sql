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
-- 0033 — el tablero, la lista de compradores y el plano
--
-- Seis cosas que tienen que quedar probadas, no argumentadas:
--
-- 1) Un rrpp que llama resumen_evento() recibe 'Sin permiso'. NO una
--    lista vacía: un vacío se lee como "no hay ventas" y quien lo vea va
--    a pensar que el evento no vendió nada, en vez de que no le tocaba
--    mirar.
-- 2) Un rrpp que pide compradores_evento() ve SOLO sus órdenes. Se
--    siembran dos relacionadores con ventas de los dos, y el test falla
--    si aparece un nombre ajeno — no si "vienen menos filas".
-- 3) Un rrpp ve TODAS las mesas con su estado (necesita saber qué queda
--    libre para vender) pero sin el nombre de las que tiene otro.
-- 4) Un p_evento de otro organizador no devuelve nada, con las tres.
-- 5) Las cuentas cierran: un combo de 10 manillas vendido una vez es UNA
--    unidad y DIEZ manillas. Es el error que ya mordió en el cupo (0018)
--    y acá se mide en las dos direcciones a la vez.
-- 6) Una orden en revision_manual y una vencida salen como cifras
--    propias, sin sumarse a lo pagado.
--
-- El fee del organizador de prueba es 10% para que `recaudado` (3300) y
-- `total` (3630) sean números DISTINTOS: si la función devolviera el
-- total en vez del subtotal, el test lo tiene que notar. Con fee 0 los
-- dos serían 3300 y el error pasaría de largo.
--
-- Como en el bloque de 0026, las ventas se siembran por el camino real
-- (crear_orden + emitir_orden), no con inserts a mano: así se prueba que
-- lo que escribe el checkout es lo que después lee el tablero.
-- ============================================================
do $$
declare v_org   uuid := '00330033-0033-4033-8033-000000000001';
        v_org2  uuid := '00330033-0033-4033-8033-000000000002';
        v_staff uuid := '00330033-0033-4033-8033-000000000003';
        v_a     uuid := '00330033-0033-4033-8033-000000000004';  -- relacionador A
        v_b     uuid := '00330033-0033-4033-8033-000000000005';  -- relacionador B
        v_ev    uuid := '00330033-0033-4033-8033-000000000006';
        v_tipo  uuid := '00330033-0033-4033-8033-000000000007';  -- entrada suelta
        v_combo uuid := '00330033-0033-4033-8033-000000000008';  -- combo de 10 manillas
        v_fase  uuid := '00330033-0033-4033-8033-000000000009';
        v_m1    uuid := '00330033-0033-4033-8033-00000000000a';
        v_m2    uuid := '00330033-0033-4033-8033-00000000000b';
        v_m3    uuid := '00330033-0033-4033-8033-00000000000c';
        -- otro tenant, para el corte por mi_organizador()
        v_staff2 uuid := '00330033-0033-4033-8033-00000000000d';
        v_ev3    uuid := '00330033-0033-4033-8033-00000000000e';
        v_tipo3  uuid := '00330033-0033-4033-8033-00000000000f';
        v_fase3  uuid := '00330033-0033-4033-8033-000000000010';
        v_o1 uuid; v_o2 uuid; v_o3 uuid; v_o4 uuid;
        v_o5 uuid; v_o6 uuid; v_o7 uuid;
        v_r jsonb; v_f jsonb; v_p jsonb; v_n int;
begin
  -- ── el escenario ────────────────────────────────────────
  insert into organizadores (id, slug, nombre, fee_pct, fee_fijo_transaccion, fee_piso) values
    (v_org,  'prueba-0033',  'Prueba 0033',       0.1000, 0, 0),
    (v_org2, 'prueba-0033b', 'Prueba 0033 otro',  0.1000, 0, 0);
  insert into auth.users (id, email) values
    (v_staff,  'staff-0033@ticketera.local'),
    (v_a,      'rrpp-a-0033@ticketera.local'),
    (v_b,      'rrpp-b-0033@ticketera.local'),
    (v_staff2, 'staff2-0033@ticketera.local');
  insert into perfiles (id, organizador_id, nombre, rol, slug) values
    (v_staff,  v_org,  'Staff 0033', 'staff', null),
    (v_a,      v_org,  'Ana 0033',   'rrpp',  'ana-0033'),
    (v_b,      v_org,  'Beto 0033',  'rrpp',  'beto-0033'),
    (v_staff2, v_org2, 'Staff Otro', 'staff', null);

  insert into eventos (id, organizador_id, slug, nombre, fecha, estado) values
    (v_ev,  v_org,  'evento-0033',  'Evento 0033',       current_date + 10, 'publicado'),
    (v_ev3, v_org2, 'evento-0033c', 'Evento 0033 otro',  current_date + 10, 'publicado');

  insert into tipo_entrada (id, organizador_id, evento_id, nombre, categoria, manillas, orden) values
    (v_tipo,  v_org,  v_ev,  'General 0033', 'entrada',  1, 1),
    (v_combo, v_org,  v_ev,  'Combo 10',     'mesa',    10, 2),
    (v_tipo3, v_org2, v_ev3, 'General Otro', 'entrada',  1, 1);
  insert into evento_fase (id, organizador_id, evento_id, nombre, desde, hasta) values
    (v_fase,  v_org,  v_ev,  'F1', now() - interval '1 hour', now() + interval '10 days'),
    (v_fase3, v_org2, v_ev3, 'F1', now() - interval '1 hour', now() + interval '10 days');
  insert into fase_precio (organizador_id, fase_id, tipo_id, precio, cupo) values
    (v_org,  v_fase,  v_tipo,   100, 50),
    (v_org,  v_fase,  v_combo, 1000,  5),   -- cupo en UNIDADES, no en manillas
    (v_org2, v_fase3, v_tipo3,  100, 50);

  insert into mesas (id, organizador_id, evento_id, planta, etiqueta, categoria, x, y, w, precio, manillas) values
    (v_m1, v_org, v_ev, 'baja', 'T1', 'mesa',   10, 10, 8, 1000, 10),
    (v_m2, v_org, v_ev, 'baja', 'T2', 'mesa',   20, 10, 8, 1000, 10),
    (v_m3, v_org, v_ev, 'alta', 'T3', 'lounge', 30, 10, 8, 1200, 12);

  -- ── las ventas, por el camino real ──────────────────────
  -- A: un combo (1 unidad, 10 manillas, 1000)
  v_o1 := (crear_orden(v_ev, jsonb_build_array(jsonb_build_object('tipo_id', v_combo, 'cantidad', 1)),
                       jsonb_build_object('nombre', 'Cliente A1', 'telefono', '70000001'),
                       null::uuid, null::text, v_a)->>'orden')::uuid;
  perform emitir_orden(v_o1);
  -- A: dos generales (2 unidades, 2 manillas, 200)
  v_o2 := (crear_orden(v_ev, jsonb_build_array(jsonb_build_object('tipo_id', v_tipo, 'cantidad', 2)),
                       jsonb_build_object('nombre', 'Cliente A2', 'telefono', '70000002'),
                       null::uuid, null::text, v_a)->>'orden')::uuid;
  perform emitir_orden(v_o2);
  -- B: un combo (1 unidad, 10 manillas, 1000)
  v_o3 := (crear_orden(v_ev, jsonb_build_array(jsonb_build_object('tipo_id', v_combo, 'cantidad', 1)),
                       jsonb_build_object('nombre', 'Cliente B1', 'telefono', '70000003'),
                       null::uuid, null::text, v_b)->>'orden')::uuid;
  perform emitir_orden(v_o3);
  -- venta pública, sin relacionador (1 unidad, 1 manilla, 100)
  v_o4 := (crear_orden(v_ev, jsonb_build_array(jsonb_build_object('tipo_id', v_tipo, 'cantidad', 1)),
                       jsonb_build_object('nombre', 'Cliente Publico', 'telefono', '70000004'),
                       null::uuid, null::text, null::uuid)->>'orden')::uuid;
  perform emitir_orden(v_o4);
  -- A: otro combo que queda PAGADO y SIN MESA ASIGNADA (el número que
  -- hay que llevar a cero antes de que abra la puerta)
  v_o7 := (crear_orden(v_ev, jsonb_build_array(jsonb_build_object('tipo_id', v_combo, 'cantidad', 1)),
                       jsonb_build_object('nombre', 'Cliente A3', 'telefono', '70000007'),
                       null::uuid, null::text, v_a)->>'orden')::uuid;
  perform emitir_orden(v_o7);

  -- la pasarela cobró un monto distinto al esperado: revision_manual
  v_o5 := (crear_orden(v_ev, jsonb_build_array(jsonb_build_object('tipo_id', v_tipo, 'cantidad', 1)),
                       jsonb_build_object('nombre', 'Cliente Revision', 'telefono', '70000005'),
                       null::uuid, null::text, v_a)->>'orden')::uuid;
  perform emitir_orden(v_o5, 1::numeric, 'ref-monto-raro');

  -- retuvo cupo y nunca pagó: vencida
  v_o6 := (crear_orden(v_ev, jsonb_build_array(jsonb_build_object('tipo_id', v_tipo, 'cantidad', 1)),
                       jsonb_build_object('nombre', 'Cliente Vencido', 'telefono', '70000006'),
                       null::uuid, null::text, v_b)->>'orden')::uuid;
  update ordenes set expira_at = now() - interval '1 minute' where id = v_o6;
  perform emitir_orden(v_o6);

  -- tres manillas del combo de A ya entraron, y una general de A se anuló
  update entradas set estado = 'usada', used_at = now()
   where id in (select id from entradas where orden_id = v_o1 order by id limit 3);
  update entradas set estado = 'anulada'
   where id = (select id from entradas where orden_id = v_o2 order by id limit 1);

  -- Las mesas se asignan por las DOS puntas a propósito: T1 por
  -- ordenes.mesa_asignada_id (lo que escribe el administrador al repartir
  -- combos) y T2 por mesas.orden_id (lo que escribe crear_orden cuando se
  -- compra una chapa concreta). Si el plano mirara una sola, una de las
  -- dos aparecería libre teniendo dueño.
  update ordenes set mesa_asignada_id = v_m1 where id = v_o1;
  update mesas set orden_id = v_o3, estado = 'pagada' where id = v_m2;

  -- ── 1) el rrpp no entra al tablero ──────────────────────
  set local role authenticated;
  perform set_config('request.jwt.claim.sub', v_a::text, true);
  begin
    perform resumen_evento(v_ev);
    raise exception 'TEST_FAIL: un rrpp pudo llamar resumen_evento';
  exception when others then
    -- Tiene que ser 'Sin permiso' y no un vacío disfrazado de respuesta.
    if sqlerrm <> 'Sin permiso' then raise; end if;
  end;

  -- ── 5) y 6) las cuentas del tablero, con el staff ───────
  perform set_config('request.jwt.claim.sub', v_staff::text, true);
  v_r := resumen_evento(v_ev);
  if v_r = '{}'::jsonb then
    raise exception 'TEST_FAIL: el staff no vio nada de su propio evento';
  end if;

  -- lo vendido: 5 órdenes pagadas, 33 filas en entradas (1 anulada),
  -- 6 unidades y 3300 de subtotal
  v_f := v_r->'vendido';
  if (v_f->>'ordenes')::int <> 5 then
    raise exception 'TEST_FAIL: 5 ordenes pagadas, dio %: %', v_f->>'ordenes', v_f;
  end if;
  if (v_f->>'manillas')::int <> 32 then
    raise exception 'TEST_FAIL: 32 manillas vivas (33 emitidas menos 1 anulada), dio %: %', v_f->>'manillas', v_f;
  end if;
  if (v_f->>'manillas_usadas')::int <> 3 then
    raise exception 'TEST_FAIL: 3 manillas usadas, dio %: %', v_f->>'manillas_usadas', v_f;
  end if;
  if (v_f->>'manillas_anuladas')::int <> 1 then
    raise exception 'TEST_FAIL: las anuladas van aparte y es 1, dio %: %', v_f->>'manillas_anuladas', v_f;
  end if;
  if (v_f->>'unidades')::int <> 6 then
    raise exception 'TEST_FAIL: 6 unidades vendidas (3 combos + 3 generales), dio %: %', v_f->>'unidades', v_f;
  end if;
  -- Lo recaudado es el SUBTOTAL. Si devolviera el total daría 3630, y si
  -- sumara entradas.precio daría 30.300 por los combos solos.
  if (v_f->>'recaudado')::numeric <> 3300 then
    raise exception 'TEST_FAIL: recaudado es sum(ordenes.subtotal) = 3300, dio %: %', v_f->>'recaudado', v_f;
  end if;
  if (v_f->>'fee')::numeric <> 330 or (v_f->>'total')::numeric <> 3630 then
    raise exception 'TEST_FAIL: el fee (330) y el total (3630) van aparte del recaudado: %', v_f;
  end if;

  -- ── 5) el combo: UNA unidad por venta, DIEZ manillas ────
  select p into v_p from jsonb_array_elements(v_r->'productos') p
   where (p->>'tipo_id')::uuid = v_combo;
  if v_p is null then
    raise exception 'TEST_FAIL: el combo no aparece en productos: %', v_r->'productos';
  end if;
  if (v_p->>'unidades')::int <> 3 then
    raise exception 'TEST_FAIL: se vendieron 3 combos (3 unidades), dio %: %', v_p->>'unidades', v_p;
  end if;
  if (v_p->>'manillas')::int <> 30 then
    raise exception 'TEST_FAIL: 3 combos de 10 son 30 manillas, dio %: %', v_p->>'manillas', v_p;
  end if;
  if (v_p->>'manillas_por_unidad')::int <> 10 then
    raise exception 'TEST_FAIL: el combo emite 10 manillas por unidad: %', v_p;
  end if;
  -- El cupo se mide en unidades (0018): 5 menos 3 vendidas son 2. Si se
  -- midiera en manillas daría 0 o negativo, que es el bug de Branca Lounge.
  if (v_p->>'cupo')::int <> 5 or (v_p->>'quedan')::int <> 2 then
    raise exception 'TEST_FAIL: cupo 5 en unidades, quedan 2: dio cupo % quedan %', v_p->>'cupo', v_p->>'quedan';
  end if;
  if (v_p->>'recaudado')::numeric <> 3000 then
    raise exception 'TEST_FAIL: 3 combos a 1000 son 3000, dio %', v_p->>'recaudado';
  end if;
  if (v_p->>'manillas_usadas')::int <> 3 then
    raise exception 'TEST_FAIL: 3 manillas del combo ya entraron, dio %', v_p->>'manillas_usadas';
  end if;

  -- la entrada suelta, para que el combo no sea el único caso mirado
  select p into v_p from jsonb_array_elements(v_r->'productos') p
   where (p->>'tipo_id')::uuid = v_tipo;
  if (v_p->>'unidades')::int <> 3 or (v_p->>'manillas')::int <> 2
     or (v_p->>'manillas_anuladas')::int <> 1 then
    raise exception 'TEST_FAIL: la general vendio 3 unidades, quedan 2 manillas vivas y 1 anulada: %', v_p;
  end if;

  -- ── por canal ───────────────────────────────────────────
  select c into v_f from jsonb_array_elements(v_r->'canales') c where c->>'canal' = 'rrpp';
  if (v_f->>'manillas')::int <> 31 then
    raise exception 'TEST_FAIL: por rrpp entraron 31 manillas vivas, dio %: %', v_f->>'manillas', v_f;
  end if;
  select c into v_f from jsonb_array_elements(v_r->'canales') c where c->>'canal' = 'publico';
  if (v_f->>'manillas')::int <> 1 then
    raise exception 'TEST_FAIL: por publico entro 1 manilla, dio %: %', v_f->>'manillas', v_f;
  end if;
  -- los cuatro canales salen siempre, aunque no hayan vendido nada
  if jsonb_array_length(v_r->'canales') <> 4 then
    raise exception 'TEST_FAIL: los cuatro canales salen siempre: %', v_r->'canales';
  end if;

  -- ── la puerta ───────────────────────────────────────────
  v_f := v_r->'puerta';
  if (v_f->>'emitidas')::int <> 32 or (v_f->>'usadas')::int <> 3
     or (v_f->>'faltan')::int <> 29 then
    raise exception 'TEST_FAIL: la puerta lleva 3 de 32 y faltan 29: %', v_f;
  end if;

  -- ── las mesas ───────────────────────────────────────────
  -- T1 asignada por ordenes.mesa_asignada_id, T2 por mesas.orden_id,
  -- T3 libre. Las dos puntas cuentan.
  v_f := v_r->'mesas';
  if (v_f->>'total')::int <> 3 or (v_f->>'asignadas')::int <> 2
     or (v_f->>'libres')::int <> 1 then
    raise exception 'TEST_FAIL: 3 mesas, 2 asignadas (una por cada punta) y 1 libre: %', v_f;
  end if;

  -- ── 6) revision_manual y vencida, como cifras propias ───
  v_f := v_r->'alertas';
  if (v_f->'revision_manual'->>'ordenes')::int <> 1 then
    raise exception 'TEST_FAIL: hay 1 orden en revision manual: %', v_f;
  end if;
  if (v_f->'revision_manual'->>'monto')::numeric <> 110 then
    raise exception 'TEST_FAIL: la orden en revision manual vale 110: %', v_f;
  end if;
  if (v_f->'vencidas'->>'ordenes')::int <> 1 or (v_f->'vencidas'->>'monto')::numeric <> 110 then
    raise exception 'TEST_FAIL: hay 1 orden vencida por 110: %', v_f;
  end if;
  -- y ninguna de las dos se coló en lo pagado
  if (v_r->'vendido'->>'recaudado')::numeric <> 3300 then
    raise exception 'TEST_FAIL: revision_manual o vencida se sumaron a lo recaudado: %', v_r->'vendido';
  end if;
  -- el combo pagado que nadie ubicó todavía
  if (v_f->'mesas_sin_asignar'->>'ordenes')::int <> 1
     or (v_f->'mesas_sin_asignar'->>'manillas')::int <> 10 then
    raise exception 'TEST_FAIL: falta ubicar 1 compra de mesa de 10 manillas: %', v_f;
  end if;
  -- en una base sana nadie entra con una manilla que nadie pagó
  if (v_f->>'manillas_sin_orden_pagada')::int <> 0 then
    raise exception 'TEST_FAIL: hay manillas vivas sin orden pagada: %', v_f;
  end if;

  -- los cinco estados salen siempre, con su plata
  select s into v_f from jsonb_array_elements(v_r->'estados') s where s->>'estado' = 'pagada';
  if (v_f->>'ordenes')::int <> 5 or (v_f->>'subtotal')::numeric <> 3300 then
    raise exception 'TEST_FAIL: 5 ordenes pagadas por 3300 de subtotal: %', v_f;
  end if;
  select s into v_f from jsonb_array_elements(v_r->'estados') s where s->>'estado' = 'revision_manual';
  if (v_f->>'ordenes')::int <> 1 then
    raise exception 'TEST_FAIL: revision_manual tiene que tener su propia fila: %', v_r->'estados';
  end if;
  if jsonb_array_length(v_r->'estados') <> 5 then
    raise exception 'TEST_FAIL: los cinco estados salen siempre: %', v_r->'estados';
  end if;

  -- ── 2) el rrpp ve SOLO sus compradores ──────────────────
  perform set_config('request.jwt.claim.sub', v_a::text, true);
  v_r := compradores_evento(v_ev, false);
  if jsonb_array_length(v_r) <> 3 then
    raise exception 'TEST_FAIL: A vendio 3 ordenes pagadas, vinieron %: %', jsonb_array_length(v_r), v_r;
  end if;
  -- Lo que importa no es que vengan 3 filas sino que no venga NINGÚN
  -- nombre ajeno: si mañana la función devolviera de más, esto grita.
  if v_r::text like '%Cliente B1%' or v_r::text like '%Cliente Publico%'
     or v_r::text like '%Beto 0033%' then
    raise exception 'TEST_FAIL: compradores_evento le mostro a A un cliente ajeno: %', v_r;
  end if;
  -- p_solo_mios = false no puede ampliar lo que ve un relacionador
  if compradores_evento(v_ev, false) <> compradores_evento(v_ev, true) then
    raise exception 'TEST_FAIL: p_solo_mios cambio lo que ve un rrpp';
  end if;

  -- 5) la misma cuenta, por orden: el combo de A es UNA unidad y DIEZ manillas
  select o into v_f from jsonb_array_elements(v_r) o where (o->>'orden_id')::uuid = v_o1;
  if (v_f->>'unidades')::int <> 1 or (v_f->>'manillas')::int <> 10 then
    raise exception 'TEST_FAIL: un combo de 10 es 1 unidad y 10 manillas, dio % y %: %',
      v_f->>'unidades', v_f->>'manillas', v_f;
  end if;
  if (v_f->>'pagado')::numeric <> 1000 then
    raise exception 'TEST_FAIL: el combo se pago 1000 (subtotal), dio %: %', v_f->>'pagado', v_f;
  end if;
  if (v_f->>'mesa_etiqueta') <> 'T1' then
    raise exception 'TEST_FAIL: la orden de A tiene la mesa T1 asignada: %', v_f;
  end if;
  if (v_f->>'comprador') <> 'Cliente A1' or (v_f->>'telefono') <> '70000001' then
    raise exception 'TEST_FAIL: faltan nombre o telefono del comprador: %', v_f;
  end if;

  -- B ve lo suyo, y tampoco ve lo de A
  perform set_config('request.jwt.claim.sub', v_b::text, true);
  v_r := compradores_evento(v_ev, false);
  if jsonb_array_length(v_r) <> 1 then
    raise exception 'TEST_FAIL: B tiene 1 orden pagada (la vencida no cuenta), vinieron %: %',
      jsonb_array_length(v_r), v_r;
  end if;
  if v_r::text like '%Cliente A%' then
    raise exception 'TEST_FAIL: B esta viendo clientes de A: %', v_r;
  end if;

  -- el staff ve las cinco, y p_solo_mios le sirve para recortar
  perform set_config('request.jwt.claim.sub', v_staff::text, true);
  if jsonb_array_length(compradores_evento(v_ev, false)) <> 5 then
    raise exception 'TEST_FAIL: el staff deberia ver las 5 ordenes pagadas: %',
      compradores_evento(v_ev, false);
  end if;
  if compradores_evento(v_ev, true) <> '[]'::jsonb then
    raise exception 'TEST_FAIL: el staff no vendio nada, con p_solo_mios deberia ver []: %',
      compradores_evento(v_ev, true);
  end if;

  -- ── 3) el plano: todas las mesas, los nombres no ────────
  perform set_config('request.jwt.claim.sub', v_a::text, true);
  v_r := mesas_evento(v_ev);
  if jsonb_array_length(v_r) <> 3 then
    raise exception 'TEST_FAIL: el rrpp tiene que ver las 3 mesas, vio %: %', jsonb_array_length(v_r), v_r;
  end if;

  -- T1 la vendió A: ve el nombre
  select m into v_f from jsonb_array_elements(v_r) m where m->>'etiqueta' = 'T1';
  if (v_f->>'ocupada')::boolean is not true then
    raise exception 'TEST_FAIL: T1 esta asignada a la orden de A: %', v_f;
  end if;
  if (v_f->>'comprador') <> 'Cliente A1' then
    raise exception 'TEST_FAIL: A vendio T1, tiene que ver el nombre: %', v_f;
  end if;
  if (v_f->>'mia')::boolean is not true then
    raise exception 'TEST_FAIL: T1 es de A: %', v_f;
  end if;

  -- T2 la vendió B: ocupada, pero sin nombre
  select m into v_f from jsonb_array_elements(v_r) m where m->>'etiqueta' = 'T2';
  if (v_f->>'ocupada')::boolean is not true then
    raise exception 'TEST_FAIL: T2 esta tomada por la orden de B: %', v_f;
  end if;
  if v_f->>'comprador' is not null then
    raise exception 'TEST_FAIL: A no tiene por que ver quien tiene la mesa de B: %', v_f;
  end if;
  if v_f->>'orden_id' is not null or v_f->>'rrpp_nombre' is not null then
    raise exception 'TEST_FAIL: se filtro la orden o el relacionador ajeno: %', v_f;
  end if;
  if (v_f->>'mia')::boolean is not false then
    raise exception 'TEST_FAIL: T2 no es de A: %', v_f;
  end if;
  -- pero sí necesita ver los datos del plano para vender
  if v_f->>'x' is null or v_f->>'y' is null or v_f->>'w' is null
     or v_f->>'precio' is null or v_f->>'manillas' is null then
    raise exception 'TEST_FAIL: al rrpp le falta el plano de la mesa: %', v_f;
  end if;

  -- T3 libre, y ningun nombre ajeno en toda la respuesta
  select m into v_f from jsonb_array_elements(v_r) m where m->>'etiqueta' = 'T3';
  if (v_f->>'ocupada')::boolean is not false then
    raise exception 'TEST_FAIL: T3 esta libre: %', v_f;
  end if;
  if v_r::text like '%Cliente B1%' or v_r::text like '%Beto 0033%' then
    raise exception 'TEST_FAIL: el plano le filtro a A un nombre ajeno: %', v_r;
  end if;

  -- el staff sí ve los dos nombres
  perform set_config('request.jwt.claim.sub', v_staff::text, true);
  v_r := mesas_evento(v_ev);
  if v_r::text not like '%Cliente A1%' or v_r::text not like '%Cliente B1%' then
    raise exception 'TEST_FAIL: el staff tiene que ver los dos compradores: %', v_r;
  end if;

  -- ── 4) el evento de otro organizador no existe acá ──────
  -- Con el staff (que sí puede editar lo suyo) y con el rrpp: en los dos
  -- casos, nada. Que sea el MISMO vacío que "no existe" es a propósito:
  -- si el ajeno diera un error distinto, serviría para adivinar qué uuids
  -- existen en la base del vecino.
  if resumen_evento(v_ev3)      <> '{}'::jsonb then
    raise exception 'TEST_FAIL: el staff vio el tablero de OTRO organizador: %', resumen_evento(v_ev3);
  end if;
  if compradores_evento(v_ev3)  <> '[]'::jsonb then
    raise exception 'TEST_FAIL: el staff vio los compradores de OTRO organizador: %', compradores_evento(v_ev3);
  end if;
  if mesas_evento(v_ev3)        <> '[]'::jsonb then
    raise exception 'TEST_FAIL: el staff vio el plano de OTRO organizador: %', mesas_evento(v_ev3);
  end if;

  perform set_config('request.jwt.claim.sub', v_a::text, true);
  if compradores_evento(v_ev3) <> '[]'::jsonb or mesas_evento(v_ev3) <> '[]'::jsonb then
    raise exception 'TEST_FAIL: un rrpp vio algo de OTRO organizador';
  end if;

  -- y al revés: el staff del otro tenant tampoco entra a este evento
  perform set_config('request.jwt.claim.sub', v_staff2::text, true);
  if resumen_evento(v_ev) <> '{}'::jsonb or compradores_evento(v_ev) <> '[]'::jsonb
     or mesas_evento(v_ev) <> '[]'::jsonb then
    raise exception 'TEST_FAIL: el staff del otro tenant vio este evento';
  end if;

  reset role;
  raise notice 'OK el tablero cuenta unidades y manillas por separado, y cada rol ve lo suyo';
end $$;

rollback;
