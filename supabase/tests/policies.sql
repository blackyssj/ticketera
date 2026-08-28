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
