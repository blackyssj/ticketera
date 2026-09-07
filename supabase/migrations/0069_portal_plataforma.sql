-- ============================================================
-- 0069 — el portal de TICKETAZO: ver todos los clientes y cuadrar
--
-- Todo lo que existe hoy está cortado por organizador: `mi_organizador()`
-- en cada función y cada policy. Es lo correcto — ningún cliente puede
-- ver al de al lado — pero deja a TICKETAZO sin poder mirar su propio
-- negocio. Hoy, para saber cuánta plata quedó en la pasarela y si a cada
-- cliente se le pagó lo suyo, hay que abrir la base a mano y sumar. Con
-- dos clientes se puede; con veinte, no.
--
-- ── por qué la marca NO va en perfiles ──────────────────────
--
-- Lo natural sería `perfiles.plataforma boolean`. El problema es quién
-- puede escribirla: `perfiles` tiene policies de update para el admin de
-- cada organizador, y una columna nueva ahí queda alcanzada por ellas. Un
-- admin de un cliente se marcaría a sí mismo y pasaría a ver el negocio
-- entero — el de él y el de todos los demás.
--
-- Por eso es una tabla aparte, sin una sola policy: `authenticated` no
-- llega, y la única forma de dar de alta a alguien es un insert con
-- service_role, o sea desde los scripts y a propósito.
--
-- ── qué cuadra este portal ──────────────────────────────────
--
-- Una sola igualdad, la que importa:
--
--     lo que entró por la pasarela
--   − lo que se le giró a los organizadores
--   = lo que tiene que estar en la wallet del comercio
--
-- Si eso no da, o cobramos algo que no registramos, o giramos de más. Las
-- dos son urgentes y ninguna se ve desde la pantalla de un cliente.
--
-- Lo que queda del lado de TICKETAZO es la comisión, y no se calcula
-- aparte: es `sum(fee)` de las órdenes pagadas. Nunca sale de la wallet
-- —el giro pide `subtotal`, no `total`— así que la comisión no es una
-- transferencia que pueda fallar, es una resta que nunca se hace.
--
-- Las órdenes SIM- se cuentan aparte y no suman a ningún total: son de la
-- pasarela en modo prueba y por esa plata nunca pasó un peso.
-- ============================================================

create table if not exists plataforma_operador (
  perfil_id uuid primary key references perfiles(id) on delete cascade,
  nota      text,
  creado_at timestamptz not null default clock_timestamp()
);
alter table plataforma_operador enable row level security;
-- Ni una policy: nadie con sesión la lee ni la escribe. Se da de alta con
-- service_role y se comprueba desde funciones `security definer`.
revoke all on plataforma_operador from anon, authenticated;

comment on table plataforma_operador is
  'Quien de TICKETAZO puede ver el negocio entero. Tabla aparte de perfiles a proposito: perfiles tiene policies de update para el admin de cada cliente, y una columna ahi la podria escribir el propio cliente para verse todo.';

drop function if exists es_plataforma();
create function es_plataforma() returns boolean
  language sql stable security definer set search_path = public as $$
  select exists (select 1 from plataforma_operador where perfil_id = auth.uid())
$$;
revoke execute on function es_plataforma() from anon, public;
grant execute on function es_plataforma() to authenticated;

-- ── el tablero ──────────────────────────────────────────────
drop function if exists panel_plataforma();
create function panel_plataforma() returns jsonb
  language plpgsql stable security definer set search_path = public as $function$
declare v_res jsonb := '[]'::jsonb; r record; v_tot jsonb;
begin
  if not es_plataforma() then raise exception 'Sin permiso'; end if;

  for r in
    select g.id, g.slug, g.nombre, g.fee_pct, g.comision_modo, g.comercio_id,
           g.pago_automatico, g.pago_auto_minimo
      from organizadores g where g.activo order by g.nombre
  loop
    v_res := v_res || jsonb_build_object(
      'organizador', r.nombre, 'slug', r.slug,
      'fee_pct', r.fee_pct, 'modo', r.comision_modo,
      'automatico', r.pago_automatico, 'minimo', r.pago_auto_minimo,
      'eventos', (select count(*) from eventos e
                   where e.organizador_id = r.id and e.estado = 'publicado'),
      'entradas', (select count(*) from entradas x
                    where x.organizador_id = r.id and x.estado <> 'anulada'),
      -- Todo lo de abajo mira SOLO plata que entro de verdad.
      'cobrado',  (select coalesce(sum(o.total),0) from ordenes o
                    where o.organizador_id = r.id and o.estado = 'pagada'
                      and coalesce(o.pago_ref,'') not like 'SIM-%'),
      'nuestro',  (select coalesce(sum(o.fee),0) from ordenes o
                    where o.organizador_id = r.id and o.estado = 'pagada'
                      and coalesce(o.pago_ref,'') not like 'SIM-%'),
      'del_cliente', (select coalesce(sum(o.subtotal),0) from ordenes o
                    where o.organizador_id = r.id and o.estado = 'pagada'
                      and coalesce(o.pago_ref,'') not like 'SIM-%'),
      'girado',   (select coalesce(sum(p.monto),0) from pago_organizador p
                    where p.organizador_id = r.id and p.estado <> 'rechazado'),
      'girado_ok',(select coalesce(sum(p.monto),0) from pago_organizador p
                    where p.organizador_id = r.id and p.estado = 'pagado'),
      'en_camino',(select coalesce(sum(p.monto),0) from pago_organizador p
                    where p.organizador_id = r.id
                      and p.estado in ('pedido','enviado','aprobacion_manual')),
      'rechazados',(select count(*) from pago_organizador p
                    where p.organizador_id = r.id and p.estado = 'rechazado'),
      'simuladas', (select coalesce(sum(o.total),0) from ordenes o
                    where o.organizador_id = r.id and o.estado = 'pagada'
                      and coalesce(o.pago_ref,'') like 'SIM-%'));
  end loop;

  -- La igualdad que hay que mirar. `en_pasarela` es lo que TIENE que
  -- estar en la wallet del comercio; compararlo con lo que dice BeePay es
  -- el cierre de la cuenta, y esa comparacion se hace afuera porque la
  -- wallet vive en otra base.
  select jsonb_build_object(
    'cobrado',  coalesce(sum((x->>'cobrado')::numeric), 0),
    'nuestro',  coalesce(sum((x->>'nuestro')::numeric), 0),
    'del_cliente', coalesce(sum((x->>'del_cliente')::numeric), 0),
    'girado',   coalesce(sum((x->>'girado')::numeric), 0),
    'en_camino',coalesce(sum((x->>'en_camino')::numeric), 0),
    'en_pasarela', coalesce(sum((x->>'cobrado')::numeric), 0)
                 - coalesce(sum((x->>'girado')::numeric), 0),
    'por_girar', coalesce(sum((x->>'del_cliente')::numeric), 0)
                 - coalesce(sum((x->>'girado')::numeric), 0))
    into v_tot
    from jsonb_array_elements(v_res) x;

  return jsonb_build_object('ok', true, 'clientes', v_res, 'total', v_tot,
                            'al', now());
end $function$;
revoke execute on function panel_plataforma() from anon, public;
grant execute on function panel_plataforma() to authenticated;

comment on function panel_plataforma() is
  'El negocio entero para TICKETAZO: por cliente lo vendido, lo cobrado, nuestra comision, lo girado y lo que falta girar, mas el total. Exige es_plataforma(); un admin de cliente recibe Sin permiso.';

-- ── los ultimos giros, de todos los clientes ────────────────
drop function if exists pagos_plataforma(int);
create function pagos_plataforma(p_limite int default 40) returns jsonb
  language plpgsql stable security definer set search_path = public as $function$
begin
  if not es_plataforma() then raise exception 'Sin permiso'; end if;
  return (select coalesce(jsonb_agg(jsonb_build_object(
            'cliente', g.nombre, 'monto', p.monto, 'estado', p.estado,
            'titular', p.titular, 'banco', p.banco_nombre, 'cuenta', p.cuenta,
            'referencia', p.referencia, 'motivo', p.motivo,
            'automatico', p.pedido_por is null,
            'cuando', p.pedido_at) order by p.pedido_at desc), '[]'::jsonb)
    from (select * from pago_organizador order by pedido_at desc
           limit greatest(coalesce(p_limite, 40), 1)) p
    join organizadores g on g.id = p.organizador_id);
end $function$;
revoke execute on function pagos_plataforma(int) from anon, public;
grant execute on function pagos_plataforma(int) to authenticated;

-- ── el chequeo tiene que reconocer la guardia nueva ─────────
-- `chequeo_funciones_sin_guardia` (0051) busca las guardias por nombre en
-- el cuerpo. `es_plataforma()` es una guardia legitima y no estaba en la
-- lista, asi que las dos funciones de arriba salian marcadas. Dejarlas
-- marcadas es peor que no tener el chequeo: a la tercera falsa alarma
-- nadie lo mira, y la que importe pasa de largo.
create or replace function chequeo_funciones_sin_guardia() returns setof text
language sql stable security definer set search_path = public as $$
  select p.proname::text
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public'
    and p.proname <> 'chequeo_funciones_sin_guardia'
    and has_function_privilege('authenticated', p.oid, 'EXECUTE')
    and p.prosrc !~* 'mi_organizador\(\)|puede_editar\(\)|es_portero\(\)|mi_rol\(\)|es_plataforma\(\)|auth\.uid\(\)'
$$;
