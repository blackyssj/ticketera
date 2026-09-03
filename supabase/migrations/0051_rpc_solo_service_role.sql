-- Las funciones que sólo llaman las Edge Functions (service_role) o el cron
-- eran ejecutables por CUALQUIER usuario logueado: el rol `authenticated` es
-- el mismo para el staff y, desde 0049, para los compradores. emitir_orden
-- sin guardia interna significaba que un comprador con una orden pendiente
-- podía emitirse las entradas sin pagar, y pagos_a_confirmar le mostraba
-- órdenes ajenas. Ninguna de estas siete la llama el panel: se les quita
-- execute a todo lo que no sea service_role. Las funciones que SÍ usa el
-- panel ya deciden adentro con mi_organizador()/puede_editar()/es_portero().
revoke execute on function public.comision_de(p_perfil uuid, p_evento uuid) from public, anon, authenticated;
grant execute on function public.comision_de(p_perfil uuid, p_evento uuid) to service_role;
revoke execute on function public.crear_orden(p_evento uuid, p_items jsonb, p_comprador jsonb, p_client_key uuid, p_ip_hash text, p_rrpp uuid) from public, anon, authenticated;
grant execute on function public.crear_orden(p_evento uuid, p_items jsonb, p_comprador jsonb, p_client_key uuid, p_ip_hash text, p_rrpp uuid) to service_role;
revoke execute on function public.disponibilidad_tipo(p_fase uuid, p_tipo uuid) from public, anon, authenticated;
grant execute on function public.disponibilidad_tipo(p_fase uuid, p_tipo uuid) to service_role;
revoke execute on function public.emitir_orden(p_orden uuid, p_monto_cobrado numeric, p_pago_ref text, p_desde_revision boolean) from public, anon, authenticated;
grant execute on function public.emitir_orden(p_orden uuid, p_monto_cobrado numeric, p_pago_ref text, p_desde_revision boolean) to service_role;
revoke execute on function public.nuevo_code() from public, anon, authenticated;
grant execute on function public.nuevo_code() to service_role;
revoke execute on function public.pagos_a_confirmar(p_limite integer) from public, anon, authenticated;
grant execute on function public.pagos_a_confirmar(p_limite integer) to service_role;
revoke execute on function public.vencer_ordenes(p_evento uuid) from public, anon, authenticated;
grant execute on function public.vencer_ordenes(p_evento uuid) to service_role;

-- Invariante para que no vuelva a pasar: toda función ejecutable por
-- authenticated tiene que decidir por rol adentro. Devuelve las que no.
create or replace function chequeo_funciones_sin_guardia() returns setof text
language sql stable security definer set search_path = public as $$
  select p.proname::text
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public'
    and p.proname <> 'chequeo_funciones_sin_guardia'
    and has_function_privilege('authenticated', p.oid, 'EXECUTE')
    and p.prosrc !~* 'mi_organizador\(\)|puede_editar\(\)|es_portero\(\)|mi_rol\(\)|auth\.uid\(\)'
$$;
revoke execute on function chequeo_funciones_sin_guardia() from public, anon, authenticated;
