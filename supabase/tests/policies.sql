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

-- El invariante 5 es una heurística de texto (busca puede_editar(), mi_rol()
-- o auth.uid() en qual/with_check). Esto prueba esa heurística sola: una
-- policy con mi_rol() tiene que pasar, una sin ningún chequeo de rol tiene
-- que hacerla fallar. Es el hallazgo del falso positivo de perfiles,
-- convertido en algo que grita solo si alguien vuelve a angostar el patrón.
begin;

create policy "prueba invariante: con mi_rol" on eventos for update to authenticated
  using (mi_rol() = 'admin');
create policy "prueba invariante: sin chequeo" on eventos for update to authenticated
  using (true);

do $$
declare v_con_rol_atrapada boolean;
        v_sin_rol_atrapada boolean;
begin
  select coalesce(qual, '') || coalesce(with_check, '') not like '%puede_editar%'
     and coalesce(qual, '') || coalesce(with_check, '') not like '%mi_rol(%'
     and coalesce(qual, '') || coalesce(with_check, '') not like '%auth.uid()%'
    into v_con_rol_atrapada
  from pg_policies
  where schemaname = 'public' and policyname = 'prueba invariante: con mi_rol';

  if v_con_rol_atrapada then
    raise exception 'TEST_FAIL: el invariante no reconoce mi_rol() como filtro de rol';
  end if;

  select coalesce(qual, '') || coalesce(with_check, '') not like '%puede_editar%'
     and coalesce(qual, '') || coalesce(with_check, '') not like '%mi_rol(%'
     and coalesce(qual, '') || coalesce(with_check, '') not like '%auth.uid()%'
    into v_sin_rol_atrapada
  from pg_policies
  where schemaname = 'public' and policyname = 'prueba invariante: sin chequeo';

  if not v_sin_rol_atrapada then
    raise exception 'TEST_FAIL: el invariante no atrapa una policy sin ningun chequeo de rol';
  end if;

  raise notice 'OK el invariante 5 reconoce mi_rol() y atrapa lo que no filtra por rol';
end $$;

rollback;
