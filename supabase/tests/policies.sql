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

rollback;
