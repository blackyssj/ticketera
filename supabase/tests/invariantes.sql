-- Invariantes estructurales. Corren contra la base migrada, no escriben nada.
-- Cada uno es una trampa de Plataforma Puerta convertida en algo que grita solo.
do $$
declare v_malas text;
begin
  select string_agg(t.tablename, ', ' order by t.tablename) into v_malas
  from pg_tables t
  -- organizadores ES el tenant. contactos (0047) y cuenta_intentos (0049)
  -- son de la plataforma y no de un cliente: un pedido de "quiero vender
  -- con ustedes" y un intento de crear cuenta de comprador no pertenecen
  -- a ningún organizador. Todo lo demás lleva organizador_id not null.
  where t.schemaname = 'public'
    and t.tablename not in ('organizadores', 'contactos', 'cuenta_intentos')
    and not exists (select 1 from information_schema.columns c
                     where c.table_schema = 'public' and c.table_name = t.tablename
                       and c.column_name = 'organizador_id' and c.is_nullable = 'NO');
  if v_malas is not null then
    raise exception 'TEST_FAIL: tablas sin organizador_id not null: %', v_malas;
  end if;
  raise notice 'OK invariante 1 - tenancy';
end $$;

do $$
declare v_malas text;
begin
  select string_agg(c.relname, ', ' order by c.relname) into v_malas
  from pg_class c join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public' and c.relkind = 'v'
    and coalesce(array_to_string(c.reloptions, ','), '') not like '%security_invoker=on%';
  if v_malas is not null then
    raise exception 'TEST_FAIL: vistas sin security_invoker: %', v_malas;
  end if;
  raise notice 'OK invariante 2 - security_invoker';
end $$;

do $$
declare v_tab text; v_fun text;
begin
  select string_agg(distinct table_name, ', ') into v_tab
  from information_schema.role_table_grants
  where grantee = 'anon' and table_schema = 'public'
    and privilege_type in ('INSERT','UPDATE','DELETE','TRUNCATE');
  if v_tab is not null then raise exception 'TEST_FAIL: anon escribe en: %', v_tab; end if;

  select string_agg(p.proname, ', ' order by p.proname) into v_fun
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and has_function_privilege('anon', p.oid, 'execute');
  if v_fun is not null then raise exception 'TEST_FAIL: anon ejecuta: %', v_fun; end if;
  raise notice 'OK invariante 3 - anon no escribe ni ejecuta';
end $$;

do $$
declare v_malas text;
begin
  select string_agg(proname || ' (' || n || ' firmas)', ', ') into v_malas
  from (select p.proname, count(*) as n from pg_proc p
        join pg_namespace ns on ns.oid = p.pronamespace
        where ns.nspname = 'public' and p.prokind = 'f'
        group by p.proname having count(*) > 1) d;
  if v_malas is not null then
    raise exception 'TEST_FAIL: funciones con firma duplicada: %', v_malas;
  end if;
  raise notice 'OK invariante 4 - una firma por funcion';
end $$;

do $$
declare v_malas text;
begin
  -- Toda policy que permita escribir tiene que nombrar a puede_editar(),
  -- mi_rol() o auth.uid(). Una que solo mire el tenant deja escribir a
  -- cualquier usuario del organizador, que es exactamente el agujero de
  -- 0012. El patrón vive en una sola función (chequeo_policies_sin_rol,
  -- definida en 0012) para que este invariante y su propio test en
  -- policies.sql corran el mismo código, no una copia que se puede
  -- desincronizar.
  select chequeo_policies_sin_rol() into v_malas;
  if v_malas is not null then
    raise exception 'TEST_FAIL: policies de escritura sin filtro de rol: %', v_malas;
  end if;
  raise notice 'OK invariante 5 - escribir pide rol';
end $$;

do $$
declare v_malas text;
begin
  -- TRUNCATE no pasa por RLS: ninguna policy lo cubre. Viene de los grants
  -- por defecto de Supabase en cada tabla nueva, así que sin revocarlo
  -- cualquier usuario autenticado puede vaciar una tabla entera aunque no
  -- pueda escribir una sola fila por policy — el agujero que destapó 0012
  -- pero para TRUNCATE en vez de UPDATE.
  select string_agg(table_name || ' (' || grantee || ')', ', ') into v_malas
  from information_schema.role_table_grants
  where table_schema = 'public'
    and grantee in ('anon','authenticated')
    and privilege_type = 'TRUNCATE';
  if v_malas is not null then
    raise exception 'TEST_FAIL: tablas con TRUNCATE otorgado a anon/authenticated: %', v_malas;
  end if;
  raise notice 'OK invariante 6 - nadie autenticado trunca';
end $$;
