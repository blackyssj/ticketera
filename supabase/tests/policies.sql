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

-- ============================================================
-- 0034 — la bitácora de la puerta
--
-- El agujero que este bloque cuida es uno solo y es de adentro: hasta 0034,
-- deshacer borraba `used_at` y `portero_id` de la fila, así que una entrada
-- que pasó diez personas —validar, deshacer, validar, deshacer— quedaba
-- idéntica a una que entró una sola vez. La prueba central no es que exista
-- una fila `deshecha`: es que ESA fila conserve el valor exacto que se borró.
-- Una bitácora que anota "alguien deshizo algo" sin decir qué había ahí no
-- sirve para reclamarle nada a nadie, y pasaría un test que solo cuente filas.
--
-- Lo demás que se prueba acá:
--
-- 1) Validar deja `validada` con el portero que escaneó.
-- 2) Deshacer deja `deshecha` CON el used_at y el portero_id que la entrada
--    tenía antes de que se los borraran — se comparan los valores.
-- 3) Validar de nuevo deja `reingreso`, distinguible de la primera validación
--    sin tener que reconstruir la secuencia.
-- 4) El modo filtro deja `rechazada` y la entrada sigue 'valida'.
-- 5) Un `authenticated` no puede hacer update ni delete sobre la bitácora.
--    Se prueban los dos y el test falla si alguno pasa.
-- 6) Un portero de otro organizador no ve ni una fila de este. El cero
--    significa algo porque antes se le hace anotar una fila propia: si la RLS
--    estuviera rota al revés y le escondiera todo, también se nota.
-- 7) Un portero llamando a bitacora_puerta() sin p_entrada ve solo lo suyo,
--    no lo del otro portero del mismo evento; el staff ve los dos.
--
-- Las filas se leen con el rol reseteado a propósito cuando lo que se
-- verifica es el contenido: leídas desde la sesión del portero, la RLS ya
-- filtró y un test que cuenta sobre lo filtrado se aprueba solo.
-- ============================================================
do $$
declare v_org   uuid := '03400034-0034-4034-8034-000000000001';
        v_org2  uuid := '03400034-0034-4034-8034-000000000002';
        v_p1    uuid := '03400034-0034-4034-8034-000000000003';  -- portero uno
        v_p2    uuid := '03400034-0034-4034-8034-000000000004';  -- portero dos, mismo org
        v_staff uuid := '03400034-0034-4034-8034-000000000005';
        v_rrpp  uuid := '03400034-0034-4034-8034-000000000006';
        v_pb    uuid := '03400034-0034-4034-8034-000000000007';  -- portero del otro org
        v_ev    uuid := '03400034-0034-4034-8034-000000000008';
        v_ev2   uuid := '03400034-0034-4034-8034-000000000009';
        v_tipo  uuid := '03400034-0034-4034-8034-00000000000a';
        v_fase  uuid := '03400034-0034-4034-8034-00000000000b';
        v_e1    uuid := '03400034-0034-4034-8034-00000000000c';  -- validar/deshacer/reingreso
        v_e2    uuid := '03400034-0034-4034-8034-00000000000d';  -- filtro
        v_e3    uuid := '03400034-0034-4034-8034-00000000000e';  -- la del portero dos
        v_e4    uuid := '03400034-0034-4034-8034-00000000000f';  -- la del otro organizador
        c_uno    text := 'BCDFGH340034';
        c_dos    text := 'JKLMNP340034';
        c_tres   text := 'QRSTVW340034';
        c_cuatro text := 'WXZBCD340034';
        v_r jsonb; v_n int; v_bit uuid; v_paso boolean;
        v_used timestamptz; v_port uuid;
        v_used_previo timestamptz; v_portero_previo uuid; v_estado_previo text;
        v_accion text; v_actor uuid;
begin
  insert into organizadores (id, slug, nombre) values
    (v_org,  'prueba-0034',  'Prueba 0034'),
    (v_org2, 'prueba-0034b', 'Prueba 0034 otro');
  insert into auth.users (id, email) values
    (v_p1,    'portero1-0034@ticketera.local'),
    (v_p2,    'portero2-0034@ticketera.local'),
    (v_staff, 'staff-0034@ticketera.local'),
    (v_rrpp,  'rrpp-0034@ticketera.local'),
    (v_pb,    'porterob-0034@ticketera.local');
  insert into perfiles (id, organizador_id, nombre, rol) values
    (v_p1,    v_org,  'Portero Uno',  'portero'),
    (v_p2,    v_org,  'Portero Dos',  'portero'),
    (v_staff, v_org,  'Staff 0034',   'staff'),
    (v_rrpp,  v_org,  'Rrpp 0034',    'rrpp'),
    (v_pb,    v_org2, 'Portero Ajeno','portero');
  insert into eventos (id, organizador_id, slug, nombre, fecha, estado) values
    (v_ev,  v_org,  'evento-0034',  'Evento 0034',   current_date + 10, 'publicado'),
    (v_ev2, v_org2, 'evento-0034b', 'Evento 0034 B', current_date + 10, 'publicado');
  insert into tipo_entrada (id, organizador_id, evento_id, nombre) values
    (v_tipo, v_org, v_ev, 'General');
  insert into evento_fase (id, organizador_id, evento_id, nombre, desde, hasta) values
    (v_fase, v_org, v_ev, 'F1', now() - interval '1 hour', now() + interval '10 days');
  insert into entradas (id, organizador_id, evento_id, code, canal, tipo_id, fase_id,
                        cliente, precio, estado) values
    (v_e1, v_org, v_ev, c_uno,  'publico', v_tipo, v_fase, 'Ana Perez',   100, 'valida'),
    (v_e2, v_org, v_ev, c_dos,  'publico', v_tipo, v_fase, 'Beto Filtro', 100, 'valida'),
    (v_e3, v_org, v_ev, c_tres, 'publico', v_tipo, v_fase, 'Cami Otra',   100, 'valida');
  insert into entradas (id, organizador_id, evento_id, code, canal, precio, estado) values
    (v_e4, v_org2, v_ev2, c_cuatro, 'publico', 100, 'valida');

  -- ── 1) validar deja su fila, con el portero que escaneó ──
  set local role authenticated;
  perform set_config('request.jwt.claim.sub', v_p1::text, true);
  v_r := validar_entrada(v_ev, c_uno);
  if v_r->>'resultado' <> 'valida' then
    raise exception 'TEST_FAIL: el primer escaneo deberia dar valida, dio %', v_r;
  end if;

  reset role;
  select count(*) into v_n from puerta_bitacora where entrada_id = v_e1;
  if v_n <> 1 then
    raise exception 'TEST_FAIL: validar tenia que dejar UNA fila en la bitacora, dejo %', v_n;
  end if;
  select accion, actor_id, estado_previo into v_accion, v_actor, v_estado_previo
    from puerta_bitacora where entrada_id = v_e1;
  if v_accion <> 'validada' then
    raise exception 'TEST_FAIL: la accion tenia que ser validada, es %', v_accion;
  end if;
  if v_actor <> v_p1 then
    raise exception 'TEST_FAIL: la bitacora no anoto al portero que escaneo (esperaba %, anoto %)',
      v_p1, v_actor;
  end if;
  if v_estado_previo <> 'valida' then
    raise exception 'TEST_FAIL: el estado previo de una validacion tenia que ser valida, es %', v_estado_previo;
  end if;

  -- La huella que la entrada tiene AHORA, que es la que deshacer va a borrar.
  select used_at, portero_id into v_used, v_port from entradas where id = v_e1;
  if v_used is null or v_port <> v_p1 then
    raise exception 'TEST_FAIL: la entrada no quedo con su hora y su portero: % / %', v_used, v_port;
  end if;

  -- ── 2) deshacer conserva la huella que borra ─────────────
  -- La prueba que importa de toda la tarea. No alcanza con que la fila
  -- exista: tiene que traer el valor exacto que desapareció de `entradas`.
  set local role authenticated;
  perform set_config('request.jwt.claim.sub', v_p1::text, true);
  v_r := descheckin_entrada(v_ev, c_uno);
  if v_r->>'resultado' <> 'valida' then
    raise exception 'TEST_FAIL: deshacer deberia devolverla a valida, dio %', v_r;
  end if;

  reset role;
  select count(*) into v_n from puerta_bitacora where entrada_id = v_e1 and accion = 'deshecha';
  if v_n <> 1 then
    raise exception 'TEST_FAIL: deshacer no dejo su fila en la bitacora (encontre %)', v_n;
  end if;
  select used_at_previo, portero_previo, actor_id, estado_previo
    into v_used_previo, v_portero_previo, v_actor, v_estado_previo
    from puerta_bitacora where entrada_id = v_e1 and accion = 'deshecha';
  if v_used_previo is distinct from v_used then
    raise exception 'TEST_FAIL: la fila deshecha perdio la hora del ingreso que borro (esperaba %, guardo %)',
      v_used, v_used_previo;
  end if;
  if v_portero_previo is distinct from v_port then
    raise exception 'TEST_FAIL: la fila deshecha perdio al portero que habia marcado el ingreso (esperaba %, guardo %)',
      v_port, v_portero_previo;
  end if;
  if v_actor <> v_p1 then
    raise exception 'TEST_FAIL: la bitacora no anoto quien deshizo';
  end if;
  if v_estado_previo <> 'usada' then
    raise exception 'TEST_FAIL: el estado previo de un deshacer tenia que ser usada, es %', v_estado_previo;
  end if;
  -- y la entrada, efectivamente, ya no los tiene: por eso la copia importa
  if exists (select 1 from entradas
              where id = v_e1 and (used_at is not null or portero_id is not null)) then
    raise exception 'TEST_FAIL: deshacer dejo la fila a medio camino — el test de arriba no probaria nada';
  end if;

  -- ── 3) validar de nuevo: reingreso, no otra validada ─────
  -- Lo valida el OTRO portero a propósito: la fila tiene que decir quién la
  -- dejó entrar la segunda vez, no repetir al de la primera.
  set local role authenticated;
  perform set_config('request.jwt.claim.sub', v_p2::text, true);
  v_r := validar_entrada(v_ev, c_uno);
  if v_r->>'resultado' <> 'valida' then
    raise exception 'TEST_FAIL: despues de deshacer tendria que poder validarse de nuevo, dio %', v_r;
  end if;

  reset role;
  select count(*) into v_n from puerta_bitacora
   where entrada_id = v_e1 and accion = 'reingreso' and actor_id = v_p2;
  if v_n <> 1 then
    raise exception 'TEST_FAIL: la segunda validacion tenia que quedar como reingreso del portero dos (encontre %)', v_n;
  end if;
  select count(*) into v_n from puerta_bitacora where entrada_id = v_e1 and accion = 'validada';
  if v_n <> 1 then
    raise exception 'TEST_FAIL: el reingreso se anoto tambien como validada — dejan de distinguirse';
  end if;
  select count(*) into v_n from puerta_bitacora where entrada_id = v_e1;
  if v_n <> 3 then
    raise exception 'TEST_FAIL: validar+deshacer+validar tenian que dejar 3 filas, dejaron %', v_n;
  end if;

  -- ── 4) el filtro deja su fila y no consume ───────────────
  set local role authenticated;
  perform set_config('request.jwt.claim.sub', v_p1::text, true);
  v_r := marcar_filtro_entrada(v_ev, c_dos);
  if (v_r->>'filtro')::boolean is not true then
    raise exception 'TEST_FAIL: el modo filtro deberia decir que filtro: %', v_r;
  end if;

  reset role;
  select count(*) into v_n from puerta_bitacora
   where entrada_id = v_e2 and accion = 'rechazada' and actor_id = v_p1
     and estado_previo = 'valida';
  if v_n <> 1 then
    raise exception 'TEST_FAIL: el rechazo del modo filtro no quedo escrito (encontre %)', v_n;
  end if;
  select count(*) into v_n from entradas
   where id = v_e2 and estado = 'valida' and used_at is null;
  if v_n <> 1 then
    raise exception 'TEST_FAIL: anotar el rechazo consumio la entrada — tenia que quedar valida';
  end if;

  -- un code que no existe no ensucia la bitacora: no hay entrada a la cual
  -- colgarle la fila
  set local role authenticated;
  perform set_config('request.jwt.claim.sub', v_p1::text, true);
  v_r := marcar_filtro_entrada(v_ev, 'ZZZZZZZZZZZZ');
  if v_r->>'resultado' <> 'no_existe' then
    raise exception 'TEST_FAIL: un code inventado tiene que decir no_existe, dijo %', v_r;
  end if;
  reset role;
  select count(*) into v_n from puerta_bitacora where organizador_id = v_org;
  if v_n <> 4 then
    raise exception 'TEST_FAIL: un code inventado dejo fila en la bitacora (van %, tenian que ser 4)', v_n;
  end if;

  -- el portero dos suma una fila propia, para que el aislamiento de (7)
  -- tenga de qué distinguirse
  set local role authenticated;
  perform set_config('request.jwt.claim.sub', v_p2::text, true);
  perform validar_entrada(v_ev, c_tres);

  -- ── 5) la bitacora no se edita ni se borra ───────────────
  reset role;
  select id into v_bit from puerta_bitacora where entrada_id = v_e1 and accion = 'validada';

  set local role authenticated;
  perform set_config('request.jwt.claim.sub', v_p1::text, true);

  v_paso := true;
  begin
    update puerta_bitacora set accion = 'rechazada' where id = v_bit;
  exception when others then v_paso := false;
  end;
  if v_paso then
    raise exception 'TEST_FAIL: un authenticated hizo UPDATE sobre la bitacora';
  end if;

  v_paso := true;
  begin
    delete from puerta_bitacora where id = v_bit;
  exception when others then v_paso := false;
  end;
  if v_paso then
    raise exception 'TEST_FAIL: un authenticated hizo DELETE sobre la bitacora';
  end if;

  reset role;
  if not exists (select 1 from puerta_bitacora where id = v_bit and accion = 'validada') then
    raise exception 'TEST_FAIL: la fila de la bitacora cambio o desaparecio';
  end if;

  -- ── 6) el portero de otro organizador no ve ni una fila ──
  set local role authenticated;
  perform set_config('request.jwt.claim.sub', v_pb::text, true);
  -- primero lo suyo, para que el cero de abajo signifique "la RLS lo corta" y
  -- no "la tabla estaba vacia para todos"
  v_r := validar_entrada(v_ev2, c_cuatro);
  if v_r->>'resultado' <> 'valida' then
    raise exception 'TEST_FAIL: el portero del otro organizador no pudo validar lo suyo: %', v_r;
  end if;
  select count(*) into v_n from puerta_bitacora where organizador_id = v_org;
  if v_n <> 0 then
    raise exception 'TEST_FAIL: un portero de otro organizador vio % filas de la bitacora ajena', v_n;
  end if;
  select count(*) into v_n from puerta_bitacora;
  if v_n <> 1 then
    raise exception 'TEST_FAIL: el portero ajeno tendria que ver exactamente la suya, ve %', v_n;
  end if;
  -- y por la funcion, preguntando derecho por el evento ajeno, tampoco
  v_r := bitacora_puerta(v_ev);
  if (v_r->>'total')::int <> 0 or jsonb_array_length(v_r->'filas') <> 0 then
    raise exception 'TEST_FAIL: bitacora_puerta() le mostro el evento de otro organizador: %', v_r;
  end if;

  -- ── 7) un portero no audita a los otros porteros ─────────
  perform set_config('request.jwt.claim.sub', v_p1::text, true);
  v_r := bitacora_puerta(v_ev);
  if v_r->>'alcance' <> 'mios' then
    raise exception 'TEST_FAIL: sin puede_editar() el alcance tenia que decir mios, dijo %', v_r->>'alcance';
  end if;
  if (v_r->>'total')::int <> 3 then
    raise exception 'TEST_FAIL: el portero uno hizo 3 cosas y la funcion contó %: %',
      v_r->>'total', v_r;
  end if;
  if exists (select 1 from jsonb_array_elements(v_r->'filas') f
              where (f->>'actor_id')::uuid <> v_p1) then
    raise exception 'TEST_FAIL: un portero vio en bitacora_puerta() lo que hizo otro portero: %', v_r;
  end if;

  -- el staff sí la lee entera
  perform set_config('request.jwt.claim.sub', v_staff::text, true);
  v_r := bitacora_puerta(v_ev);
  if v_r->>'alcance' <> 'evento' then
    raise exception 'TEST_FAIL: con puede_editar() el alcance tenia que decir evento, dijo %', v_r->>'alcance';
  end if;
  if (v_r->>'total')::int <> 5 then
    raise exception 'TEST_FAIL: el resumen del admin tenia que ver las 5 filas del evento, vio %', v_r->>'total';
  end if;
  if (v_r->>'cortada')::boolean is not false or (v_r->>'tope')::int is null then
    raise exception 'TEST_FAIL: la respuesta tiene que declarar tope y si corto: %', v_r;
  end if;

  -- la historia de UNA entrada, lo mas nuevo primero, y con la huella adentro
  v_r := bitacora_puerta(v_ev, v_e1);
  if (v_r->>'total')::int <> 3 then
    raise exception 'TEST_FAIL: la historia de la entrada tenia 3 filas, trajo %', v_r->>'total';
  end if;
  if v_r->'filas'->0->>'accion' <> 'reingreso' then
    raise exception 'TEST_FAIL: lo mas nuevo tenia que venir primero, vino %', v_r->'filas'->0->>'accion';
  end if;
  if not exists (select 1 from jsonb_array_elements(v_r->'filas') f
                  where f->>'accion' = 'deshecha'
                    and (f->>'used_at_previo')::timestamptz = v_used
                    and (f->>'portero_previo')::uuid = v_port) then
    raise exception 'TEST_FAIL: la lectura no expone la huella que deshacer borro: %', v_r;
  end if;

  -- un rrpp no la lee: no trabaja la puerta
  perform set_config('request.jwt.claim.sub', v_rrpp::text, true);
  begin
    perform bitacora_puerta(v_ev);
    raise exception 'TEST_FAIL: un rrpp pudo leer la bitacora de la puerta';
  exception when others then
    if sqlerrm <> 'Sin permiso' then raise; end if;
  end;

  -- ── 8) a mano no se puede firmar con el nombre de otro ───
  -- La policy de insert existe porque el grant de insert existe. Lo que tiene
  -- que garantizar es que una fila escrita a mano quede firmada por quien la
  -- escribió: si se pudiera anotar a nombre del compañero, la bitácora
  -- serviría para acusarlo en vez de para auditarlo.
  perform set_config('request.jwt.claim.sub', v_p1::text, true);
  v_paso := true;
  begin
    insert into puerta_bitacora (organizador_id, evento_id, entrada_id, accion,
                                 actor_id, estado_previo)
    values (v_org, v_ev, v_e2, 'validada', v_p2, 'valida');
  exception when others then v_paso := false;
  end;
  if v_paso then
    raise exception 'TEST_FAIL: se pudo anotar una fila de la bitacora a nombre de otro portero';
  end if;

  reset role;
  raise notice 'OK deshacer deja huella: la bitacora guarda used_at y portero previos, distingue reingreso, y no se edita ni se borra';
end $$;

-- ============================================================
-- 0038 — anular, cortesías y resolver una revisión manual
--
-- Lo que este bloque cuida es que tres operaciones que mueven plata y
-- gente que entra no se puedan hacer a medias ni en silencio. Diez cosas
-- quedan probadas, no argumentadas:
--
-- 1) Anular una orden anula sus entradas y le DEVUELVE EL CUPO al tipo.
--    Se compara el número de disponibilidad_tipo() antes y después, no
--    que la fila cambió: el cupo es una resta con cuatro términos (0038)
--    y "la orden dice anulada" no prueba que la resta haya cambiado.
-- 2) Anular sin motivo rebota. Vacío Y solo espacios: el segundo es el
--    que pasa cuando alguien apura la pantalla con la barra espaciadora.
-- 3) Una orden con una manilla ya 'usada' NO se anula por el camino
--    normal, y el error dice cuántas entraron. Después sí, con el
--    parámetro explícito, y ahí queda anotado cuántas se incluyeron.
-- 4) Anular libera la mesa asignada y la deja disponible de verdad.
-- 5) Una cortesía sale con canal cortesia, precio 0, sin orden, a nombre
--    de quien se dijo — y BAJA EL CUPO. Se prueban los dos casos de la
--    conversión a unidades: la entrada suelta (1 manilla = 1 unidad) y el
--    combo de 10 (3 manillas regaladas = 1 unidad, porque esa mesa ya no
--    se vende).
-- 6) Pasarse del tope rebota y el error dice cuál es el tope.
-- 7) Una revisión manual confirmada emite sus entradas; otra anulada
--    queda sin ninguna. La confirmada TOMA cupo (pasa a pagada) y la
--    anulada no lo toca: una orden en revisión nunca lo estuvo
--    reteniendo, así que "devolver el cupo" acá es no quedárselo.
-- 8) Un rrpp recibe 'Sin permiso' en las cinco funciones nuevas (y en la
--    lectura de la bitácora). Un admin DE OTRO ORGANIZADOR, también: es
--    el que pasa puede_editar() y por eso el corte que importa es el de
--    mi_organizador() adentro de cada función.
-- 9) El registro conserva el motivo y quién lo hizo, y no se puede
--    editar ni borrar desde una sesión autenticada.
--
-- Las filas se leen con el rol reseteado cuando lo que se verifica es el
-- contenido: leídas desde la sesión que las escribió, la RLS ya filtró y
-- un test que cuenta sobre lo filtrado se aprueba solo.
-- ============================================================
do $$
declare v_org    uuid := '00380038-0038-4038-8038-000000000001';
        v_org2   uuid := '00380038-0038-4038-8038-000000000002';
        v_admin  uuid := '00380038-0038-4038-8038-000000000003';
        v_rrpp   uuid := '00380038-0038-4038-8038-000000000004';
        v_admin2 uuid := '00380038-0038-4038-8038-000000000005';
        v_ev     uuid := '00380038-0038-4038-8038-000000000006';
        v_ev2    uuid := '00380038-0038-4038-8038-000000000007';
        v_gen    uuid := '00380038-0038-4038-8038-000000000008';
        v_combo  uuid := '00380038-0038-4038-8038-000000000009';
        v_fase   uuid := '00380038-0038-4038-8038-00000000000a';
        v_m1     uuid := '00380038-0038-4038-8038-00000000000b';
        v_gen2   uuid := '00380038-0038-4038-8038-00000000000c';
        v_fase2  uuid := '00380038-0038-4038-8038-00000000000d';
        v_o1 uuid; v_o2 uuid; v_o3 uuid; v_o4 uuid;
        v_o5 uuid; v_o6 uuid; v_o7 uuid; v_o8 uuid;
        v_e_perm uuid; v_e_suelta uuid; v_e_cort uuid;
        v_antes int; v_desp int; v_n int; v_r jsonb; v_b admin_bitacora;
        v_actor uuid; v_sql text; v_paso boolean;
begin
  -- ── el escenario ────────────────────────────────────────
  insert into organizadores (id, slug, nombre, fee_pct, fee_fijo_transaccion, fee_piso) values
    (v_org,  'prueba-0038',  'Prueba 0038',      0.1000, 0, 0),
    (v_org2, 'prueba-0038b', 'Prueba 0038 otro', 0.1000, 0, 0);
  insert into auth.users (id, email) values
    (v_admin,  'admin-0038@ticketera.local'),
    (v_rrpp,   'rrpp-0038@ticketera.local'),
    (v_admin2, 'admin2-0038@ticketera.local');
  insert into perfiles (id, organizador_id, nombre, rol, slug) values
    (v_admin,  v_org,  'Admin 0038',   'admin', null),
    (v_rrpp,   v_org,  'Rrpp 0038',    'rrpp',  'rrpp-0038'),
    (v_admin2, v_org2, 'Admin de otro','admin', null);

  insert into eventos (id, organizador_id, slug, nombre, fecha, estado) values
    (v_ev,  v_org,  'evento-0038',  'Evento 0038',      current_date + 10, 'publicado'),
    (v_ev2, v_org2, 'evento-0038b', 'Evento 0038 otro', current_date + 10, 'publicado');

  insert into tipo_entrada (id, organizador_id, evento_id, nombre, categoria, manillas, orden) values
    (v_gen,   v_org,  v_ev,  'General 0038', 'entrada',  1, 1),
    (v_combo, v_org,  v_ev,  'Combo 10',     'mesa',    10, 2),
    (v_gen2,  v_org2, v_ev2, 'General Otro', 'entrada',  1, 1);
  insert into evento_fase (id, organizador_id, evento_id, nombre, desde, hasta) values
    (v_fase,  v_org,  v_ev,  'F1', now() - interval '1 hour', now() + interval '10 days'),
    (v_fase2, v_org2, v_ev2, 'F1', now() - interval '1 hour', now() + interval '10 days');
  insert into fase_precio (organizador_id, fase_id, tipo_id, precio, cupo) values
    (v_org,  v_fase,  v_gen,    100, 20),
    (v_org,  v_fase,  v_combo, 1000,  5),
    (v_org2, v_fase2, v_gen2,   100, 20);

  insert into mesas (id, organizador_id, evento_id, planta, etiqueta, categoria, x, y, w, precio, manillas) values
    (v_m1, v_org, v_ev, 'baja', 'T1', 'mesa', 10, 10, 8, 1000, 10);

  -- Las ventas por el camino real (crear_orden + emitir_orden), como en
  -- 0033: así se prueba que lo que escribe el checkout es lo que después
  -- anula esta migración. Va con el rol de la conexión —emitir_orden no
  -- tiene grant a authenticated, la llaman las Edge Functions.
  v_o1 := (crear_orden(v_ev, jsonb_build_array(jsonb_build_object('tipo_id', v_gen, 'cantidad', 3)),
                       jsonb_build_object('nombre', 'Cliente Uno', 'telefono', '70000001'),
                       null::uuid, null::text, null::uuid)->>'orden')::uuid;
  perform emitir_orden(v_o1);
  v_o2 := (crear_orden(v_ev, jsonb_build_array(jsonb_build_object('tipo_id', v_gen, 'cantidad', 2)),
                       jsonb_build_object('nombre', 'Cliente Dos', 'telefono', '70000002'),
                       null::uuid, null::text, null::uuid)->>'orden')::uuid;
  perform emitir_orden(v_o2);
  v_o3 := (crear_orden(v_ev, jsonb_build_array(jsonb_build_object('tipo_id', v_combo, 'cantidad', 1)),
                       jsonb_build_object('nombre', 'Cliente Mesa', 'telefono', '70000003'),
                       null::uuid, null::text, null::uuid)->>'orden')::uuid;
  perform emitir_orden(v_o3);
  v_o6 := (crear_orden(v_ev, jsonb_build_array(jsonb_build_object('tipo_id', v_gen, 'cantidad', 2)),
                       jsonb_build_object('nombre', 'Cliente Seis', 'telefono', '70000006'),
                       null::uuid, null::text, null::uuid)->>'orden')::uuid;
  perform emitir_orden(v_o6);
  v_o8 := (crear_orden(v_ev, jsonb_build_array(jsonb_build_object('tipo_id', v_gen, 'cantidad', 1)),
                       jsonb_build_object('nombre', 'Cliente Ocho', 'telefono', '70000008'),
                       null::uuid, null::text, null::uuid)->>'orden')::uuid;
  perform emitir_orden(v_o8);

  -- Tres que la pasarela cobró por un monto distinto: quedan en revisión
  -- manual y SIN una sola entrada emitida, que es lo que hace que este
  -- caso sea el más delicado del sistema.
  v_o4 := (crear_orden(v_ev, jsonb_build_array(jsonb_build_object('tipo_id', v_gen, 'cantidad', 1)),
                       jsonb_build_object('nombre', 'Cliente Revision', 'telefono', '70000004'),
                       null::uuid, null::text, null::uuid)->>'orden')::uuid;
  perform emitir_orden(v_o4, 1::numeric, 'ref-cobro-raro-4');
  v_o5 := (crear_orden(v_ev, jsonb_build_array(jsonb_build_object('tipo_id', v_gen, 'cantidad', 1)),
                       jsonb_build_object('nombre', 'Cliente Revision Dos', 'telefono', '70000005'),
                       null::uuid, null::text, null::uuid)->>'orden')::uuid;
  perform emitir_orden(v_o5, 1::numeric, 'ref-cobro-raro-5');
  v_o7 := (crear_orden(v_ev, jsonb_build_array(jsonb_build_object('tipo_id', v_gen, 'cantidad', 1)),
                       jsonb_build_object('nombre', 'Cliente Revision Tres', 'telefono', '70000007'),
                       null::uuid, null::text, null::uuid)->>'orden')::uuid;
  perform emitir_orden(v_o7, 1::numeric, 'ref-cobro-raro-7');

  if (select estado from ordenes where id = v_o4) <> 'revision_manual' then
    raise exception 'TEST_FAIL: la orden cobrada por otro monto no quedo en revision_manual';
  end if;
  if (select monto_cobrado from ordenes where id = v_o4) <> 1 then
    raise exception 'TEST_FAIL: no se guardo lo que la pasarela dijo haber cobrado';
  end if;

  -- una manilla de la orden dos ya entró al evento
  update entradas set estado = 'usada', used_at = now(), portero_id = v_admin
   where id = (select id from entradas where orden_id = v_o2 order by id limit 1);

  select id into v_e_perm from entradas where orden_id = v_o8 order by id limit 1;

  -- ── la sesión del administrador ─────────────────────────
  set local role authenticated;
  perform set_config('request.jwt.claim.sub', v_admin::text, true);

  -- la mesa se reparte por el camino real
  v_r := asignar_mesa(v_o3, v_m1);
  if (v_r->>'ok')::boolean is not true then
    raise exception 'TEST_FAIL: no se pudo sembrar la mesa asignada: %', v_r;
  end if;

  -- ── 2) sin motivo no se anula ───────────────────────────
  -- Los dos casos: el vacío y el que trae solo espacios. El segundo es el
  -- que llega de una pantalla apurada, y `not null` no lo atrapa.
  v_paso := true;
  begin
    perform anular_orden(v_o1, '');
  exception when others then
    v_paso := false;
    if sqlerrm not like 'MOTIVO_REQUERIDO:%' then
      raise exception 'TEST_FAIL: motivo vacio dijo "%" en vez de MOTIVO_REQUERIDO', sqlerrm;
    end if;
  end;
  if v_paso then raise exception 'TEST_FAIL: se anulo una orden sin motivo'; end if;

  v_paso := true;
  begin
    perform anular_orden(v_o1, '     ');
  exception when others then
    v_paso := false;
    if sqlerrm not like 'MOTIVO_REQUERIDO:%' then
      raise exception 'TEST_FAIL: motivo en blanco dijo "%" en vez de MOTIVO_REQUERIDO', sqlerrm;
    end if;
  end;
  if v_paso then raise exception 'TEST_FAIL: se anulo una orden con un motivo de puros espacios'; end if;

  v_paso := true;
  begin
    perform anular_entrada(v_e_perm, '   ');
  exception when others then
    v_paso := false;
    if sqlerrm not like 'MOTIVO_REQUERIDO:%' then
      raise exception 'TEST_FAIL: anular_entrada sin motivo dijo "%"', sqlerrm;
    end if;
  end;
  if v_paso then raise exception 'TEST_FAIL: se anulo una manilla sin motivo'; end if;

  -- ── 1) anular devuelve el cupo ──────────────────────────
  v_antes := disponibilidad_tipo(v_fase, v_gen);
  v_r := anular_orden(v_o1, 'pago doble: se le cobro dos veces la misma compra');
  v_desp := disponibilidad_tipo(v_fase, v_gen);
  if (v_r->>'ok')::boolean is not true or (v_r->>'entradas_anuladas')::int <> 3 then
    raise exception 'TEST_FAIL: anular la orden de 3 manillas devolvio %', v_r;
  end if;
  if v_desp <> v_antes + 3 then
    raise exception 'TEST_FAIL: el cupo tenia que pasar de % a %, quedo en %', v_antes, v_antes + 3, v_desp;
  end if;
  if (select estado from ordenes where id = v_o1) <> 'anulada' then
    raise exception 'TEST_FAIL: la orden no quedo anulada';
  end if;
  select count(*) into v_n from entradas where orden_id = v_o1 and estado <> 'anulada';
  if v_n <> 0 then
    raise exception 'TEST_FAIL: quedaron % manillas vivas de una orden anulada', v_n;
  end if;

  -- Anularla de nuevo no vuelve a devolver cupo ni escribe otra fila: el
  -- cupo se libera por el estado de la orden, no por una resta propia, y
  -- una segunda pasada no puede duplicar nada.
  v_antes := disponibilidad_tipo(v_fase, v_gen);
  v_r := anular_orden(v_o1, 'la aprieto dos veces');
  if (v_r->>'ya_estaba')::boolean is not true then
    raise exception 'TEST_FAIL: anular dos veces la misma orden no aviso que ya estaba: %', v_r;
  end if;
  if disponibilidad_tipo(v_fase, v_gen) <> v_antes then
    raise exception 'TEST_FAIL: anular dos veces devolvio el cupo dos veces';
  end if;

  -- ── 3) una manilla que ya entró frena la anulación ──────
  v_paso := true;
  begin
    perform anular_orden(v_o2, 'contracargo del banco');
  exception when others then
    v_paso := false;
    if sqlerrm not like 'HAY_USADAS:%' then
      raise exception 'TEST_FAIL: con una manilla usada dijo "%" en vez de HAY_USADAS', sqlerrm;
    end if;
    -- El error tiene que decir CUÁNTAS entraron: sin el número, el que lo
    -- lee no tiene con qué decidir si sigue.
    if sqlerrm not like '%1 de esta compra ya entró%' then
      raise exception 'TEST_FAIL: el error no dice cuantas entraron: "%"', sqlerrm;
    end if;
  end;
  if v_paso then raise exception 'TEST_FAIL: se anulo una orden con una manilla ya usada'; end if;

  -- nada se tocó: la negativa no puede dejar la orden a medio anular
  if (select estado from ordenes where id = v_o2) <> 'pagada' then
    raise exception 'TEST_FAIL: la orden que rebotó quedo tocada';
  end if;
  select count(*) into v_n from entradas where orden_id = v_o2 and estado = 'anulada';
  if v_n <> 0 then raise exception 'TEST_FAIL: la negativa igual anulo % manillas', v_n; end if;

  -- con el parámetro explícito sí, y queda escrito cuántas ya habían entrado
  v_r := anular_orden(v_o2, 'contracargo del banco: la tarjeta era robada', true);
  if (v_r->>'entradas_anuladas')::int <> 2 or (v_r->>'usadas_incluidas')::int <> 1 then
    raise exception 'TEST_FAIL: la anulacion forzada devolvio %', v_r;
  end if;
  -- El ingreso sigue escrito en la fila aunque la manilla esté anulada:
  -- esa persona entró y la base no lo olvida.
  select count(*) into v_n from entradas
   where orden_id = v_o2 and estado = 'anulada' and used_at is not null;
  if v_n <> 1 then
    raise exception 'TEST_FAIL: la manilla usada perdio su used_at al anularse';
  end if;

  -- ── 4) anular libera la mesa ────────────────────────────
  if (select orden_id from mesas where id = v_m1) is distinct from v_o3 then
    raise exception 'TEST_FAIL: la mesa no quedo sembrada con su orden';
  end if;
  v_r := anular_orden(v_o3, 'el cliente se arrepintio antes del evento');
  if (v_r->>'mesa_liberada')::boolean is not true then
    raise exception 'TEST_FAIL: anular no dijo que libero la mesa: %', v_r;
  end if;
  if (select orden_id from mesas where id = v_m1) is not null
     or (select estado from mesas where id = v_m1) <> 'disponible' then
    raise exception 'TEST_FAIL: la mesa quedo tomada por una orden anulada';
  end if;
  if (select mesa_asignada_id from ordenes where id = v_o3) is not null then
    raise exception 'TEST_FAIL: la orden anulada sigue apuntando a una mesa';
  end if;

  -- ── 5) las cortesías ────────────────────────────────────
  v_antes := disponibilidad_tipo(v_fase, v_gen);
  v_r := emitir_cortesias(v_ev, v_gen, 4, 'Radio Line', 'cuatro para la radio que transmite');
  v_desp := disponibilidad_tipo(v_fase, v_gen);
  if jsonb_array_length(v_r->'codes') <> 4 then
    raise exception 'TEST_FAIL: se pidieron 4 cortesias y volvieron %', v_r->'codes';
  end if;
  select count(*) into v_n from entradas
   where evento_id = v_ev and canal = 'cortesia' and precio = 0 and orden_id is null
     and cliente = 'Radio Line' and fase_id = v_fase and tipo_id = v_gen;
  if v_n <> 4 then
    raise exception 'TEST_FAIL: las cortesias no salieron como cortesias: % filas', v_n;
  end if;
  if v_desp <> v_antes - 4 then
    raise exception 'TEST_FAIL: 4 cortesias tenian que bajar el cupo de % a %, quedo en %',
      v_antes, v_antes - 4, v_desp;
  end if;

  -- El combo: 3 manillas regaladas de un producto que emite 10 por unidad
  -- son UNA unidad de cupo. Redondear para abajo sería vender esa mesa
  -- otra vez con tres personas ya sentadas.
  v_antes := disponibilidad_tipo(v_fase, v_combo);
  perform emitir_cortesias(v_ev, v_combo, 3, 'El DJ', 'la mesa del dj y su gente');
  v_desp := disponibilidad_tipo(v_fase, v_combo);
  if v_desp <> v_antes - 1 then
    raise exception 'TEST_FAIL: 3 manillas de un combo de 10 son 1 unidad: % -> %', v_antes, v_desp;
  end if;

  -- anular una cortesía SÍ devuelve su lugar: no tiene orden que la sostenga
  select id into v_e_cort from entradas
   where evento_id = v_ev and canal = 'cortesia' and cliente = 'Radio Line' order by id limit 1;
  v_antes := disponibilidad_tipo(v_fase, v_gen);
  v_r := anular_entrada(v_e_cort, 'esa manilla se le mando dos veces al mismo periodista');
  if (v_r->>'devuelve_cupo')::boolean is not true then
    raise exception 'TEST_FAIL: anular una cortesia no dijo que devuelve cupo: %', v_r;
  end if;
  if disponibilidad_tipo(v_fase, v_gen) <> v_antes + 1 then
    raise exception 'TEST_FAIL: anular una cortesia no devolvio su lugar';
  end if;

  -- anular una manilla de una orden pagada NO devuelve cupo: la unidad se
  -- vendió y se cobró; lo que se perdió es una manilla, no una venta
  select id into v_e_suelta from entradas where orden_id = v_o6 order by id limit 1;
  v_antes := disponibilidad_tipo(v_fase, v_gen);
  v_r := anular_entrada(v_e_suelta, 'manilla perdida, se le emite otra a mano');
  if (v_r->>'devuelve_cupo')::boolean is not false then
    raise exception 'TEST_FAIL: una manilla de una orden pagada no devuelve cupo: %', v_r;
  end if;
  if disponibilidad_tipo(v_fase, v_gen) <> v_antes then
    raise exception 'TEST_FAIL: anular una manilla suelta devolvio cupo que sigue vendido';
  end if;
  if (select estado from entradas where id = v_e_suelta) <> 'anulada'
     or (select estado from ordenes where id = v_o6) <> 'pagada' then
    raise exception 'TEST_FAIL: anular la manilla tenia que dejar la compra en pie';
  end if;

  -- ── 6) el tope de cortesías ─────────────────────────────
  v_paso := true;
  begin
    perform emitir_cortesias(v_ev, v_gen, 51, 'Todos', 'un dedo apoyado en el cero');
  exception when others then
    v_paso := false;
    if sqlerrm not like 'TOPE_CORTESIAS:%' then
      raise exception 'TEST_FAIL: pasarse del tope dijo "%"', sqlerrm;
    end if;
    -- El tope va DICHO en el error: si no, se descubre probando.
    if sqlerrm not like '%50%' then
      raise exception 'TEST_FAIL: el error del tope no dice cual es el tope: "%"', sqlerrm;
    end if;
  end;
  if v_paso then raise exception 'TEST_FAIL: se emitieron 51 cortesias de una'; end if;

  select count(*) into v_n from entradas where evento_id = v_ev and cliente = 'Todos';
  if v_n <> 0 then raise exception 'TEST_FAIL: el rebote del tope igual emitio % filas', v_n; end if;

  -- ── 7) la revisión manual ───────────────────────────────
  -- Confirmar emite, y al pasar la orden a pagada TOMA el cupo que estaba
  -- disponible: una orden en revisión no lo retenía.
  select count(*) into v_n from entradas where orden_id = v_o4;
  if v_n <> 0 then raise exception 'TEST_FAIL: una orden en revision no deberia tener entradas'; end if;

  v_antes := disponibilidad_tipo(v_fase, v_gen);
  v_r := resolver_revision(v_o4, 'confirmar', 'la pasarela cobro 1 Bs de menos por redondeo, se acepta');
  v_desp := disponibilidad_tipo(v_fase, v_gen);
  if (v_r->>'ok')::boolean is not true or (v_r->>'entradas')::int <> 1 then
    raise exception 'TEST_FAIL: confirmar la revision devolvio %', v_r;
  end if;
  if (select estado from ordenes where id = v_o4) <> 'pagada' then
    raise exception 'TEST_FAIL: la revision confirmada no quedo pagada';
  end if;
  select count(*) into v_n from entradas where orden_id = v_o4 and estado = 'valida';
  if v_n <> 1 then raise exception 'TEST_FAIL: la revision confirmada emitio % manillas', v_n; end if;
  if v_desp <> v_antes - 1 then
    raise exception 'TEST_FAIL: confirmar tenia que tomar 1 de cupo: % -> %', v_antes, v_desp;
  end if;

  -- Anular la otra: sin entradas, y el cupo que iba a ocupar queda libre.
  v_antes := disponibilidad_tipo(v_fase, v_gen);
  v_r := resolver_revision(v_o5, 'anular', 'la pasarela cobro 1 Bs, no hay pago que confirmar');
  v_desp := disponibilidad_tipo(v_fase, v_gen);
  if (v_r->>'ok')::boolean is not true or (v_r->>'decision') <> 'anular' then
    raise exception 'TEST_FAIL: anular la revision devolvio %', v_r;
  end if;
  if (select estado from ordenes where id = v_o5) <> 'anulada' then
    raise exception 'TEST_FAIL: la revision anulada no quedo anulada';
  end if;
  select count(*) into v_n from entradas where orden_id = v_o5;
  if v_n <> 0 then raise exception 'TEST_FAIL: la revision anulada emitio % entradas', v_n; end if;
  if v_desp <> v_antes then
    raise exception 'TEST_FAIL: anular una revision no puede mover el cupo: % -> %', v_antes, v_desp;
  end if;

  -- y ya no se puede volver a resolver: no está en revisión
  v_paso := true;
  begin
    perform resolver_revision(v_o5, 'confirmar', 'me arrepenti');
  exception when others then
    v_paso := false;
    if sqlerrm not like 'NO_ESTA_EN_REVISION:%' then
      raise exception 'TEST_FAIL: resolver una orden ya resuelta dijo "%"', sqlerrm;
    end if;
  end;
  if v_paso then raise exception 'TEST_FAIL: se resolvio dos veces la misma revision'; end if;

  -- una decisión que no existe no se inventa
  v_paso := true;
  begin
    perform resolver_revision(v_o7, 'quizas', 'a ver que pasa');
  exception when others then
    v_paso := false;
    if sqlerrm not like 'DECISION_INVALIDA:%' then
      raise exception 'TEST_FAIL: una decision inventada dijo "%"', sqlerrm;
    end if;
  end;
  if v_paso then raise exception 'TEST_FAIL: resolver_revision acepto una decision inventada'; end if;

  -- la lista que el tablero no ofrecía: queda la o7 sin resolver
  v_r := ordenes_en_revision(v_ev);
  if jsonb_array_length(v_r) <> 1 then
    raise exception 'TEST_FAIL: tenia que quedar 1 orden en revision, hay %', jsonb_array_length(v_r);
  end if;
  if ((v_r->0)->>'diferencia')::numeric >= 0 then
    raise exception 'TEST_FAIL: la diferencia tiene que venir restada y en negativo: %', v_r->0;
  end if;

  -- ── 8) el rrpp y el admin de otro organizador ───────────
  -- Las dos sesiones contra las mismas cinco funciones (más la lectura de
  -- la bitácora). El admin de otro organizador es el caso que importa:
  -- pasa puede_editar() y lo único que lo frena es mi_organizador()
  -- adentro de cada función.
  foreach v_actor in array array[v_rrpp, v_admin2] loop
    perform set_config('request.jwt.claim.sub', v_actor::text, true);
    for v_sql in
      select unnest(array[
        format('select anular_orden(%L, %L)', v_o8, 'probando desde afuera'),
        format('select anular_entrada(%L, %L)', v_e_perm, 'probando desde afuera'),
        format('select emitir_cortesias(%L, %L, 1, %L, %L)', v_ev, v_gen, 'Yo', 'probando desde afuera'),
        format('select resolver_revision(%L, %L, %L)', v_o7, 'confirmar', 'probando desde afuera'),
        format('select ordenes_en_revision(%L)', v_ev),
        format('select bitacora_admin(%L)', v_ev)])
    loop
      begin
        execute v_sql;
        raise exception 'TEST_FAIL: % no rebotó para %', v_sql, v_actor;
      exception when others then
        if sqlerrm like 'TEST_FAIL%' then raise; end if;
        if sqlerrm <> 'Sin permiso' then
          raise exception 'TEST_FAIL: % dijo "%" en vez de Sin permiso (actor %)', v_sql, sqlerrm, v_actor;
        end if;
      end;
    end loop;
  end loop;

  -- y nada de eso dejó rastro
  if (select estado from ordenes where id = v_o8) <> 'pagada'
     or (select estado from entradas where id = v_e_perm) <> 'valida'
     or (select estado from ordenes where id = v_o7) <> 'revision_manual' then
    raise exception 'TEST_FAIL: alguna de las llamadas rechazadas igual escribio';
  end if;
  select count(*) into v_n from entradas where evento_id = v_ev and cliente = 'Yo';
  if v_n <> 0 then raise exception 'TEST_FAIL: una cortesia rechazada igual se emitio'; end if;

  -- ── 9) el registro ──────────────────────────────────────
  -- Se lee con el rol reseteado: desde la sesión que las escribió, la RLS
  -- ya filtró y contar sobre lo filtrado se aprueba solo.
  reset role;

  select * into v_b from admin_bitacora
   where orden_id = v_o1 and accion = 'orden_anulada';
  if not found then raise exception 'TEST_FAIL: la anulacion de la orden no dejo registro'; end if;
  if v_b.motivo <> 'pago doble: se le cobro dos veces la misma compra' then
    raise exception 'TEST_FAIL: el registro no conserva el motivo, dice "%"', v_b.motivo;
  end if;
  if v_b.actor_id <> v_admin then
    raise exception 'TEST_FAIL: el registro no dice quien lo hizo, dice %', v_b.actor_id;
  end if;
  if (v_b.detalle->>'entradas_anuladas')::int <> 3 then
    raise exception 'TEST_FAIL: el registro no dice cuantas manillas cayeron: %', v_b.detalle;
  end if;

  -- una sola fila por decisión: anular la misma orden dos veces no escribe dos
  select count(*) into v_n from admin_bitacora where orden_id = v_o1;
  if v_n <> 1 then
    raise exception 'TEST_FAIL: la orden anulada dos veces dejo % filas', v_n;
  end if;

  -- la anulación forzada anota cuántas ya habían entrado
  select * into v_b from admin_bitacora where orden_id = v_o2 and accion = 'orden_anulada';
  if (v_b.detalle->>'usadas_incluidas')::int <> 1 then
    raise exception 'TEST_FAIL: el registro no dice cuantas ya habian entrado: %', v_b.detalle;
  end if;

  -- las cortesías dicen quién, para quién y con qué códigos.
  -- Acotado al evento de esta prueba: las otras aserciones filtran por
  -- orden_id, que es único, pero una cortesía no tiene orden. Sin este
  -- filtro la consulta agarraba la primera fila que coincidiera en toda la
  -- tabla —incluida una de otro evento— y el test fallaba por datos ajenos
  -- en vez de por el código.
  select * into v_b from admin_bitacora
   where evento_id = v_ev
     and accion = 'cortesias_emitidas' and detalle->>'para' = 'Radio Line';
  if not found then raise exception 'TEST_FAIL: la emision de cortesias no dejo registro'; end if;
  if v_b.actor_id <> v_admin or jsonb_array_length(v_b.detalle->'codes') <> 4 then
    raise exception 'TEST_FAIL: el registro de las cortesias esta incompleto: %', to_jsonb(v_b);
  end if;

  -- la revisión confirmada guarda lo que la pasarela dijo haber cobrado
  select * into v_b from admin_bitacora where orden_id = v_o4 and accion = 'revision_confirmada';
  if not found or (v_b.detalle->>'monto_cobrado')::numeric <> 1 then
    raise exception 'TEST_FAIL: la revision confirmada no guardo el monto cobrado: %', to_jsonb(v_b);
  end if;

  -- anular una revisión NO escribe dos filas: la de anular_orden ya dice
  -- todo, y su estado_previo es el que cuenta de dónde venía
  select count(*) into v_n from admin_bitacora where orden_id = v_o5;
  if v_n <> 1 then raise exception 'TEST_FAIL: la revision anulada dejo % filas', v_n; end if;
  select * into v_b from admin_bitacora where orden_id = v_o5;
  if v_b.detalle->>'estado_previo' <> 'revision_manual' then
    raise exception 'TEST_FAIL: el registro no dice que venia de una revision: %', v_b.detalle;
  end if;

  -- ── el registro no se corrige ───────────────────────────
  set local role authenticated;
  perform set_config('request.jwt.claim.sub', v_admin::text, true);

  v_paso := true;
  begin
    update admin_bitacora set motivo = 'otra cosa' where orden_id = v_o1;
    get diagnostics v_n = row_count;
    if v_n = 0 then v_paso := false; end if;
  exception when others then v_paso := false;
  end;
  if v_paso then raise exception 'TEST_FAIL: se pudo reescribir el motivo de una anulacion'; end if;

  v_paso := true;
  begin
    delete from admin_bitacora where orden_id = v_o1;
    get diagnostics v_n = row_count;
    if v_n = 0 then v_paso := false; end if;
  exception when others then v_paso := false;
  end;
  if v_paso then raise exception 'TEST_FAIL: se pudo borrar una fila del registro'; end if;

  -- y no se puede firmar con el nombre de otro
  v_paso := true;
  begin
    insert into admin_bitacora (organizador_id, evento_id, accion, motivo, actor_id)
    values (v_org, v_ev, 'orden_anulada', 'a nombre del companero', v_rrpp);
  exception when others then v_paso := false;
  end;
  if v_paso then raise exception 'TEST_FAIL: se pudo firmar una fila del registro con el uid de otro'; end if;

  -- ni una fila sin motivo, aunque se la escriba a mano esquivando la función
  v_paso := true;
  begin
    insert into admin_bitacora (organizador_id, evento_id, accion, motivo, actor_id)
    values (v_org, v_ev, 'orden_anulada', '   ', v_admin);
  exception when others then v_paso := false;
  end;
  if v_paso then raise exception 'TEST_FAIL: entro una fila con el motivo en blanco'; end if;

  reset role;
  raise notice 'OK anular devuelve el cupo, exige motivo y frena en las usadas; las cortesias consumen cupo con tope; la revision manual se resuelve por los dos lados y todo queda firmado';
end $$;

-- ============================================================
-- 0039 — cerrar el evento y liquidar
--
-- Lo que se prueba acá, en orden de cuánto cuesta si falla:
--
-- 1) El doble pago. `pagar_comision` lleva la condición DENTRO del
--    update; el test la ejerce pagando dos veces la misma línea. Se
--    verificó por mutación que el test tiene dientes: sacándole el
--    `and pagada_at is null`, la segunda llamada paga de nuevo.
-- 2) Que la foto no se recalcule. Se cierra, se anula una orden después,
--    y la foto tiene que seguir diciendo lo mismo mientras `hoy` cambia.
--    Si la foto siguiera a los datos, lo que se pagó dejaría de coincidir
--    con lo que la pantalla dice que se debía.
-- 3) Que cerrar NO rompa la puerta. La gente entra después de que la
--    venta cerró; si `validar_entrada` dejara de andar con el evento en
--    'cerrado', el portero se queda con la fila afuera.
-- 4) Que la foto salga del mismo cuerpo que ventas_por_rrpp(), comparando
--    línea por línea en vez de mirarlas.
-- ============================================================
do $$
declare
  v_org   uuid := '0aaa0039-0000-4000-8000-000000000010';
  v_org2  uuid := '0aaa0039-0000-4000-8000-000000000011';
  v_admin uuid := '0aaa0039-0000-4000-8000-000000000012';
  v_rrpp  uuid := '0aaa0039-0000-4000-8000-000000000013';
  v_ajeno uuid := '0aaa0039-0000-4000-8000-000000000014';
  v_ev    uuid := '0aaa0039-0000-4000-8000-000000000020';
  v_fase  uuid := '0aaa0039-0000-4000-8000-000000000021';
  v_tipo  uuid := '0aaa0039-0000-4000-8000-000000000022';
  v_o1 uuid := gen_random_uuid(); v_o2 uuid := gen_random_uuid();
  v_lin uuid; v_code text; x jsonb; q jsonb; v_n int;
begin
  insert into organizadores (id, slug, nombre) values
    (v_org,'liq-0039','Liq'), (v_org2,'liq-0039-otro','Otro');
  insert into auth.users (id, email) values
    (v_admin,'adm0039@t.local'), (v_rrpp,'rrpp0039@t.local'), (v_ajeno,'aj0039@t.local');
  insert into perfiles (id, organizador_id, nombre, rol, slug) values
    (v_admin, v_org,  'Admin 0039',  'admin', null),
    (v_rrpp,  v_org,  'Rrpp 0039',   'rrpp',  'r0039'),
    (v_ajeno, v_org2, 'Ajeno 0039',  'admin', null);
  insert into eventos (id, organizador_id, slug, nombre, fecha, comision_entrada)
    values (v_ev, v_org, 'ev-0039', 'Evento 0039', current_date + 5, 10);
  insert into tipo_entrada (id, organizador_id, evento_id, nombre, categoria, manillas)
    values (v_tipo, v_org, v_ev, 'General 0039', 'entrada', 1);
  insert into evento_fase (id, organizador_id, evento_id, nombre, desde, hasta)
    values (v_fase, v_org, v_ev, 'F', now() - interval '1 hour', now() + interval '10 days');
  insert into fase_precio (organizador_id, fase_id, tipo_id, precio, cupo)
    values (v_org, v_fase, v_tipo, 100, 50);

  -- dos ventas del relacionador: 3 entradas a 10 Bs de comision = 30
  for i in 1..2 loop
    insert into ordenes (id, organizador_id, evento_id, estado, expira_at, comprador_nombre,
                         subtotal, fee, total, rrpp_id, pagada_at)
    values (case when i=1 then v_o1 else v_o2 end, v_org, v_ev, 'pagada',
            now() + interval '1 day', 'Comprador '||i,
            case when i=1 then 200 else 100 end, case when i=1 then 16 else 8 end,
            case when i=1 then 216 else 108 end, v_rrpp, now());
    insert into orden_items (organizador_id, orden_id, tipo_id, fase_id, cantidad, precio_unitario)
    values (v_org, case when i=1 then v_o1 else v_o2 end, v_tipo, v_fase,
            case when i=1 then 2 else 1 end, 100);
    insert into entradas (organizador_id, evento_id, orden_id, code, canal, tipo_id, fase_id,
                          rrpp_id, cliente, precio)
    select v_org, v_ev, case when i=1 then v_o1 else v_o2 end, nuevo_code(), 'rrpp',
           v_tipo, v_fase, v_rrpp, 'Comprador '||i, 100
      from generate_series(1, case when i=1 then 2 else 1 end);
  end loop;

  set local role authenticated;
  perform set_config('request.jwt.claim.sub', v_admin::text, true);

  -- sin motivo no se cierra
  begin
    x := cerrar_evento(v_ev, '   ');
    raise exception 'TEST_FAIL: cerro un evento sin motivo';
  exception when others then
    if sqlerrm not like 'MOTIVO_REQUERIDO%' then raise; end if;
  end;

  x := cerrar_evento(v_ev, 'evento terminado');
  if (select estado from eventos where id = v_ev) <> 'cerrado' then
    raise exception 'TEST_FAIL: el evento no quedo cerrado';
  end if;
  if (x->>'bruto')::numeric <> 300 or (x->>'comisiones')::numeric <> 30
     or (x->>'neto')::numeric <> 270 then
    raise exception 'TEST_FAIL: la cuenta del cierre no da: %', x;
  end if;

  -- (4) la foto sale del mismo cuerpo que ventas_por_rrpp(): comparada, no mirada
  select count(*) into v_n
    from liquidacion_linea l
    join liquidacion q2 on q2.id = l.liquidacion_id and q2.evento_id = v_ev and q2.vigente
    join lateral (select * from jsonb_to_recordset(ventas_por_rrpp(v_ev))
                  as t(perfil_id uuid, entradas int, comision numeric)) v
      on v.perfil_id = l.perfil_id
   where v.entradas <> l.entradas or v.comision <> l.comision;
  if v_n > 0 then raise exception 'TEST_FAIL: la foto no coincide con ventas_por_rrpp en % lineas', v_n; end if;

  -- (3) la puerta sigue andando con el evento cerrado
  select code into v_code from entradas where evento_id = v_ev and estado = 'valida' limit 1;
  x := validar_entrada(v_ev, v_code);
  if x->>'resultado' <> 'valida' then
    raise exception 'TEST_FAIL: cerrar el evento rompio la puerta: %', x->>'resultado';
  end if;

  -- (2) anular despues de cerrar no mueve la foto
  x := anular_orden(v_o2, 'contracargo posterior al cierre');
  q := liquidacion_evento(v_ev);
  if (q->'foto'->>'bruto')::numeric <> 300 then
    raise exception 'TEST_FAIL: la foto se movio con una anulacion posterior: %', q->'foto'->>'bruto';
  end if;
  if (q->'hoy'->>'bruto')::numeric <> 200 then
    raise exception 'TEST_FAIL: lo de hoy no reflejo la anulacion: %', q->'hoy'->>'bruto';
  end if;
  if not (q->'foto'->>'difiere')::boolean then
    raise exception 'TEST_FAIL: no marco que la foto difiere de los datos de hoy';
  end if;

  -- (1) el doble pago
  select l.id into v_lin from liquidacion_linea l
    join liquidacion q2 on q2.id = l.liquidacion_id
   where q2.evento_id = v_ev and q2.vigente limit 1;
  x := pagar_comision(v_lin, null, 'transferencia');
  if not (x->>'ok')::boolean then raise exception 'TEST_FAIL: no dejo pagar la primera vez: %', x; end if;
  x := pagar_comision(v_lin, null, 'otra vez');
  if (x->>'ok')::boolean then raise exception 'TEST_FAIL: PAGO DOS VECES la misma comision'; end if;
  select count(*) into v_n from admin_bitacora
   where evento_id = v_ev and accion = 'comision_pagada';
  if v_n <> 1 then raise exception 'TEST_FAIL: quedaron % registros de pago para un solo pago', v_n; end if;

  -- reabrir avisa de lo ya pagado
  x := reabrir_evento(v_ev, 'faltaba resolver una orden');
  if (x->>'comisiones_ya_pagadas')::int <> 1 then
    raise exception 'TEST_FAIL: reabrir no aviso que ya se habia pagado una comision';
  end if;
  reset role;

  -- un rrpp no cierra ni paga
  set local role authenticated;
  perform set_config('request.jwt.claim.sub', v_rrpp::text, true);
  begin
    x := cerrar_evento(v_ev, 'prueba');
    raise exception 'TEST_FAIL: un rrpp cerro un evento';
  exception when others then if sqlerrm not like 'Sin permiso%' then raise; end if;
  end;
  begin
    x := pagar_comision(v_lin);
    raise exception 'TEST_FAIL: un rrpp marco una comision como pagada';
  exception when others then if sqlerrm not like 'Sin permiso%' then raise; end if;
  end;
  reset role;

  -- un admin de OTRO organizador tampoco: no le existe ni el evento ni la linea
  set local role authenticated;
  perform set_config('request.jwt.claim.sub', v_ajeno::text, true);
  begin
    x := cerrar_evento(v_ev, 'prueba');
    raise exception 'TEST_FAIL: un admin ajeno cerro este evento';
  exception when others then if sqlerrm not like 'EVENTO_INEXISTENTE%' then raise; end if;
  end;
  begin
    x := pagar_comision(v_lin);
    raise exception 'TEST_FAIL: un admin ajeno pago una comision de otro organizador';
  exception when others then if sqlerrm not like 'LINEA_INEXISTENTE%' then raise; end if;
  end;
  if liquidacion_evento(v_ev) <> '{}'::jsonb then
    raise exception 'TEST_FAIL: un admin ajeno vio la liquidacion de otro organizador';
  end if;
  reset role;

  raise notice 'OK cerrar congela la foto, la puerta sigue andando, y una comision se paga una sola vez';
end $$;

-- ============================================================
-- 0040 — los exportables
--
-- Lo que se prueba acá es lo que hace que un archivo mienta sin que nadie
-- lo note, que es la única forma de falla que importa en un export:
--
-- 1) El corte silencioso. Se siembran 1200 manillas —doscientas más que
--    el tope mudo de PostgREST— y se recorre `entradas_evento` como lo
--    hace el navegador: pidiendo de a mil y avanzando `p_desde` hasta
--    juntar `total`. Tienen que salir las 1200, DISTINTAS: un paginado
--    sobre un orden ambiguo repite filas y se come otras, y el archivo
--    queda con la cantidad justa y las filas equivocadas.
-- 2) Que `total` se cuente sin el tope. Es lo único con lo que después se
--    puede decir la verdad sobre si la lista quedó cortada; si se contara
--    sobre la página, `cortada` sería false siempre.
-- 3) El nombre con fórmula. Un comprador se llama
--    `=HYPERLINK("http://malo","Hacé clic")` y su teléfono empieza con
--    `+`. La base tiene que devolverlos TAL CUAL —neutralizar en la base
--    sería corromper el dato para todas las pantallas— y el que neutraliza
--    es csv.js, en el borde donde se escribe el archivo.
-- 4) Los permisos, que no se rehacen en el frontend:
--    · un rrpp no baja las manillas del evento (ni las suyas: la lista es
--      del evento entero), pero SÍ sus compradores, porque
--      compradores_evento ya recorta por auth.uid().
--    · un portero SÍ baja las manillas —es su lista de contingencia sin
--      señal— y en la bitácora de la puerta ve SOLO lo suyo, con
--      `alcance` diciéndolo.
--    · un admin de OTRO organizador no ve nada, y recibe el mismo
--      'Sin permiso' que con un evento que no existe.
-- 5) Que la bitácora de admin traiga el motivo, el autor y de quién era
--    la compra. Sin el comprador, una anulación vieja es una acción y un
--    uuid, y hay que ir a buscar a otra pantalla de quién era: que es el
--    momento en que se deja de leer la bitácora.
-- ============================================================
do $$
declare v_org    uuid := '00400040-0040-4040-8040-000000000001';
        v_org2   uuid := '00400040-0040-4040-8040-000000000002';
        v_admin  uuid := '00400040-0040-4040-8040-000000000003';
        v_rrpp   uuid := '00400040-0040-4040-8040-000000000004';
        v_admin2 uuid := '00400040-0040-4040-8040-000000000005';
        v_por1   uuid := '00400040-0040-4040-8040-000000000006';
        v_por2   uuid := '00400040-0040-4040-8040-000000000007';
        v_ev     uuid := '00400040-0040-4040-8040-000000000008';
        v_gen    uuid := '00400040-0040-4040-8040-000000000009';
        v_fase   uuid := '00400040-0040-4040-8040-00000000000a';
        v_malo   text := '=HYPERLINK("http://malo","Hacé clic")';
        v_o1 uuid; v_o2 uuid; v_o3 uuid;
        v_r jsonb; v_n int; v_off int; v_total int;
        v_ids uuid[]; v_c1 text; v_c2 text;
begin
  -- ── el escenario ────────────────────────────────────────
  insert into organizadores (id, slug, nombre, fee_pct, fee_fijo_transaccion, fee_piso) values
    (v_org,  'prueba-0040',  'Prueba 0040',      0.1000, 0, 0),
    (v_org2, 'prueba-0040b', 'Prueba 0040 otro', 0.1000, 0, 0);
  insert into auth.users (id, email) values
    (v_admin,  'admin-0040@ticketera.local'),
    (v_rrpp,   'rrpp-0040@ticketera.local'),
    (v_admin2, 'admin2-0040@ticketera.local'),
    (v_por1,   'portero1-0040@ticketera.local'),
    (v_por2,   'portero2-0040@ticketera.local');
  insert into perfiles (id, organizador_id, nombre, rol, slug) values
    (v_admin,  v_org,  'Admin 0040',    'admin',   null),
    (v_rrpp,   v_org,  'Rrpp 0040',     'rrpp',    'rrpp-0040'),
    (v_admin2, v_org2, 'Admin de otro', 'admin',   null),
    (v_por1,   v_org,  'Portero Uno',   'portero', null),
    (v_por2,   v_org,  'Portero Dos',   'portero', null);
  insert into eventos (id, organizador_id, slug, nombre, fecha, estado) values
    (v_ev, v_org, 'evento-0040', 'Evento 0040', current_date + 10, 'publicado');
  insert into tipo_entrada (id, organizador_id, evento_id, nombre, categoria, manillas, orden) values
    (v_gen, v_org, v_ev, 'General 0040', 'entrada', 1, 1);
  insert into evento_fase (id, organizador_id, evento_id, nombre, desde, hasta) values
    (v_fase, v_org, v_ev, 'F1', now() - interval '1 hour', now() + interval '10 days');
  insert into fase_precio (organizador_id, fase_id, tipo_id, precio, cupo) values
    (v_org, v_fase, v_gen, 100, 2000);

  -- Tres compras por el camino real. La primera es la del nombre con
  -- fórmula: entra por `crear_orden`, que es por donde entra cualquiera
  -- desde el formulario público.
  v_o1 := (crear_orden(v_ev, jsonb_build_array(jsonb_build_object('tipo_id', v_gen, 'cantidad', 2)),
                       jsonb_build_object('nombre', v_malo, 'telefono', '+591 700 12345',
                                          'email', 'malo@example.com'),
                       null::uuid, null::text, null::uuid)->>'orden')::uuid;
  perform emitir_orden(v_o1);
  v_o2 := (crear_orden(v_ev, jsonb_build_array(jsonb_build_object('tipo_id', v_gen, 'cantidad', 1)),
                       jsonb_build_object('nombre', 'Marcelo Áñez', 'telefono', '70011223'),
                       null::uuid, null::text, v_rrpp)->>'orden')::uuid;
  perform emitir_orden(v_o2);
  v_o3 := (crear_orden(v_ev, jsonb_build_array(jsonb_build_object('tipo_id', v_gen, 'cantidad', 1)),
                       jsonb_build_object('nombre', 'Lucía Terceros', 'telefono', '69884411'),
                       null::uuid, null::text, null::uuid)->>'orden')::uuid;
  perform emitir_orden(v_o3);

  -- ── 1200 manillas ───────────────────────────────────────
  -- Se insertan derecho y no por el checkout: lo que se prueba es el
  -- paginado de entradas_evento, no la venta, y 1200 pasadas por
  -- crear_orden serían minutos de test para probar otra cosa.
  insert into entradas (organizador_id, evento_id, code, canal, tipo_id, fase_id,
                        cliente, precio, estado)
  select v_org, v_ev, 'Z' || lpad(i::text, 6, '0'), 'publico', v_gen, v_fase,
         'Sembrada ' || i, 100, 'valida'
    from generate_series(1, 1200) i;

  select count(*) into v_total from entradas where evento_id = v_ev;
  if v_total <= 1000 then
    raise exception 'TEST_FAIL: el escenario tiene % manillas y tiene que pasar de 1000', v_total;
  end if;

  -- ── el recorrido, como lo hace el navegador ─────────────
  set local role authenticated;
  perform set_config('request.jwt.claim.sub', v_admin::text, true);

  v_r := entradas_evento(v_ev, 0, 1000);
  if (v_r->>'total')::int <> v_total then
    raise exception 'TEST_FAIL: entradas_evento dice total % y hay %', v_r->>'total', v_total;
  end if;
  if jsonb_array_length(v_r->'filas') <> 1000 then
    raise exception 'TEST_FAIL: la primera pagina trajo % y se pidieron 1000',
      jsonb_array_length(v_r->'filas');
  end if;
  if (v_r->>'cortada')::boolean is not true then
    raise exception 'TEST_FAIL: con % de % filas dijo que no estaba cortada',
      jsonb_array_length(v_r->'filas'), v_total;
  end if;

  v_ids := '{}';
  v_off := 0;
  loop
    v_r := entradas_evento(v_ev, v_off, 1000);
    v_n := jsonb_array_length(v_r->'filas');
    exit when v_n = 0;
    select v_ids || array_agg((f->>'id')::uuid) into v_ids
      from jsonb_array_elements(v_r->'filas') f;
    v_off := v_off + v_n;
    exit when v_off >= (v_r->>'total')::int;
  end loop;

  if array_length(v_ids, 1) <> v_total then
    raise exception 'TEST_FAIL: el recorrido junto % filas de %', array_length(v_ids, 1), v_total;
  end if;
  select count(distinct x) into v_n from unnest(v_ids) x;
  if v_n <> v_total then
    raise exception 'TEST_FAIL: el recorrido repitio filas: % distintas de %', v_n, v_total;
  end if;
  -- La última página tiene que decir que ya no falta nada.
  if (v_r->>'cortada')::boolean is not false then
    raise exception 'TEST_FAIL: la ultima pagina dijo que todavia estaba cortada';
  end if;

  -- ── el nombre con fórmula llega crudo ───────────────────
  -- Neutralizar acá sería corromper el dato para toda la aplicación: el
  -- nombre se muestra en el tablero, en la puerta y en el correo. El
  -- apóstrofo lo pone csv.js, en el borde donde se escribe el archivo.
  select f->>'comprador' into v_c1
    from jsonb_array_elements(compradores_evento(v_ev, false)) f
   where f->>'orden_id' = v_o1::text;
  if v_c1 <> v_malo then
    raise exception 'TEST_FAIL: la base devolvio el nombre cambiado: %', v_c1;
  end if;
  select f->>'telefono' into v_c2
    from jsonb_array_elements(compradores_evento(v_ev, false)) f
   where f->>'orden_id' = v_o1::text;
  if v_c2 <> '+591 700 12345' then
    raise exception 'TEST_FAIL: la base devolvio el telefono cambiado: %', v_c2;
  end if;

  -- ── una anulación con su motivo y su autor ──────────────
  v_r := anular_orden(v_o3, 'pago doble; lo devolvió la pasarela', false);
  reset role;
  v_r := bitacora_admin(v_ev, 0, 200);
  set local role authenticated;
  perform set_config('request.jwt.claim.sub', v_admin::text, true);
  v_r := bitacora_admin(v_ev, 0, 200);
  if (v_r->>'total')::int <> 1 then
    raise exception 'TEST_FAIL: la bitacora del panel tiene % filas y tendria que tener 1', v_r->>'total';
  end if;
  if v_r->'filas'->0->>'motivo' <> 'pago doble; lo devolvió la pasarela' then
    raise exception 'TEST_FAIL: la bitacora perdio el motivo: %', v_r->'filas'->0->>'motivo';
  end if;
  if v_r->'filas'->0->>'actor' <> 'Admin 0040' then
    raise exception 'TEST_FAIL: la bitacora no dice quien fue: %', v_r->'filas'->0->>'actor';
  end if;
  -- El comprador es el dato que 0040 le agregó a cada fila: sin él, una
  -- anulación vieja obliga a ir a buscar de quién era la compra.
  if v_r->'filas'->0->>'comprador' <> 'Lucía Terceros' then
    raise exception 'TEST_FAIL: la bitacora no dice de quien era la compra: %',
      v_r->'filas'->0->>'comprador';
  end if;
  reset role;

  -- ── dos porteros escanean ───────────────────────────────
  select code into v_c1 from entradas where evento_id = v_ev and code = 'Z000001';
  select code into v_c2 from entradas where evento_id = v_ev and code = 'Z000002';

  set local role authenticated;
  perform set_config('request.jwt.claim.sub', v_por1::text, true);
  perform validar_entrada(v_ev, v_c1);
  -- El portero ve SU escaneo y ninguno más, y la función lo dice.
  v_r := bitacora_puerta(v_ev, null, 0, 500);
  if v_r->>'alcance' <> 'mios' then
    raise exception 'TEST_FAIL: para un portero el alcance dijo %', v_r->>'alcance';
  end if;
  reset role;

  set local role authenticated;
  perform set_config('request.jwt.claim.sub', v_por2::text, true);
  perform validar_entrada(v_ev, v_c2);
  v_r := bitacora_puerta(v_ev, null, 0, 500);
  if (v_r->>'total')::int <> 1 then
    raise exception 'TEST_FAIL: el portero dos vio % filas y solo hizo 1', v_r->>'total';
  end if;
  if v_r->'filas'->0->>'code' <> v_c2 then
    raise exception 'TEST_FAIL: el portero dos vio el escaneo del otro: %', v_r->'filas'->0->>'code';
  end if;
  -- Y no puede bajar las manillas del evento por la otra punta tampoco…
  -- salvo que sí: es su lista de contingencia. Lo que no puede es auditar
  -- al compañero, que es lo de arriba.
  v_r := entradas_evento(v_ev, 0, 10);
  if (v_r->>'total')::int <> v_total then
    raise exception 'TEST_FAIL: al portero le negaron su lista de la puerta';
  end if;
  reset role;

  -- El admin ve los dos escaneos, y con alcance de evento.
  set local role authenticated;
  perform set_config('request.jwt.claim.sub', v_admin::text, true);
  v_r := bitacora_puerta(v_ev, null, 0, 500);
  if v_r->>'alcance' <> 'evento' then
    raise exception 'TEST_FAIL: para un admin el alcance dijo %', v_r->>'alcance';
  end if;
  if (v_r->>'total')::int <> 2 then
    raise exception 'TEST_FAIL: el admin vio % escaneos y hubo 2', v_r->>'total';
  end if;
  reset role;

  -- ── el relacionador ─────────────────────────────────────
  set local role authenticated;
  perform set_config('request.jwt.claim.sub', v_rrpp::text, true);
  begin
    v_r := entradas_evento(v_ev, 0, 10);
    raise exception 'TEST_FAIL: un rrpp bajo la lista de manillas del evento';
  exception when others then
    if sqlerrm not like 'Sin permiso%' then raise; end if;
  end;
  begin
    v_r := bitacora_admin(v_ev, 0, 10);
    raise exception 'TEST_FAIL: un rrpp leyo la bitacora del panel';
  exception when others then
    if sqlerrm not like 'Sin permiso%' then raise; end if;
  end;
  -- Sus compradores sí, y SOLO los suyos: p_solo_mios en false no lo
  -- amplía, porque compradores_evento lo ignora para el que no edita.
  v_r := compradores_evento(v_ev, false);
  if jsonb_array_length(v_r) <> 1 then
    raise exception 'TEST_FAIL: el rrpp vio % compras y vendio 1', jsonb_array_length(v_r);
  end if;
  if v_r->0->>'orden_id' <> v_o2::text then
    raise exception 'TEST_FAIL: el rrpp vio una compra que no es suya';
  end if;
  reset role;

  -- ── el admin de otro organizador ────────────────────────
  set local role authenticated;
  perform set_config('request.jwt.claim.sub', v_admin2::text, true);
  begin
    v_r := entradas_evento(v_ev, 0, 10);
    raise exception 'TEST_FAIL: un admin ajeno bajo las manillas de otro organizador';
  exception when others then
    if sqlerrm not like 'Sin permiso%' then raise; end if;
  end;
  begin
    v_r := bitacora_admin(v_ev, 0, 10);
    raise exception 'TEST_FAIL: un admin ajeno leyo la bitacora de otro organizador';
  exception when others then
    if sqlerrm not like 'Sin permiso%' then raise; end if;
  end;
  -- Un evento que no existe contesta lo MISMO que uno ajeno: si contestara
  -- distinto, la función sería un oráculo de qué uuids hay en la base del
  -- vecino.
  begin
    v_r := entradas_evento(gen_random_uuid(), 0, 10);
    raise exception 'TEST_FAIL: entradas_evento contesto por un evento inexistente';
  exception when others then
    if sqlerrm not like 'Sin permiso%' then raise; end if;
  end;
  if bitacora_puerta(v_ev, null, 0, 500)->>'total' <> '0' then
    raise exception 'TEST_FAIL: un admin ajeno vio escaneos de otro organizador';
  end if;
  reset role;

  raise notice 'OK los exportables traen todas las filas, dicen si cortaron, devuelven el nombre crudo para que lo neutralice el CSV, y cada rol baja solo lo suyo';
end $$;

rollback;
