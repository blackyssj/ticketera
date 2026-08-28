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
