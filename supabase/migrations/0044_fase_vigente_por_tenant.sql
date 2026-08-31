-- ============================================================
-- 0044 — fase_vigente() se acota al organizador de quien pregunta
--
-- Es `security definer` y recibe un `p_evento` cualquiera, así que un
-- `authenticated` de un cliente podía preguntar por el evento de otro y
-- recibir el uuid de su fase vigente. La fuga es chica —un uuid, y
-- `fase_precio` sigue cerrada por RLS— pero es de las que crecen: cada
-- función nueva que reciba ese id lo da por bueno.
--
-- El detalle que hace que esto NO sea un `and f.organizador_id =
-- mi_organizador()` a secas: la página pública la llama a través de la
-- Edge Function `evento`, que corre con service_role y ahí `auth.uid()`
-- es null, o sea `mi_organizador()` también. Con el filtro directo, la
-- función no devolvería ninguna fase y **la página de compra dejaría de
-- vender**. Por eso el corte solo aplica cuando hay sesión: sin sesión es
-- service_role, que es el guardián y ya decidió qué puede leer.
-- ============================================================

create or replace function fase_vigente(p_evento uuid) returns uuid
  language sql stable security definer set search_path = public as $$
  select f.id from evento_fase f
   where f.evento_id = p_evento and f.activo
     and (f.desde is null or f.desde <= now())
     and (f.hasta is null or f.hasta >  now())
     and (mi_organizador() is null or f.organizador_id = mi_organizador())
   order by f.orden limit 1
$$;
revoke execute on function fase_vigente(uuid) from anon, public;
grant execute on function fase_vigente(uuid) to authenticated;

comment on function fase_vigente(uuid) is
  'La fase abierta ahora. Con sesión, solo del organizador de quien pregunta; sin sesión (service_role) no filtra, porque ahí el guardián es la Edge Function.';
