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
