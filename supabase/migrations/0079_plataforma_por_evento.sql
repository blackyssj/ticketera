-- ============================================================
-- 0079 — el portal de plataforma, evento por evento
--
-- `panel_plataforma()` (0069) muestra una fila por CLIENTE. Sirve para
-- cuadrar la wallet y para ver el margen, que era lo que faltaba cuando
-- se hizo. Pero la plata no se liquida por cliente: se liquida por
-- EVENTO, cada fecha con su tope del 70%, su disponible y sus giros. Con
-- dos fechas del mismo cliente, la fila del cliente dice "falta girarle
-- 623 Bs" y no dice cuál de las dos noches los tiene ni cuánto de eso ya
-- se puede mandar hoy.
--
-- Peor: el mínimo del pago automático también se aplica por evento, así
-- que la única pantalla donde se podía ver por qué un giro no salió era
-- el panel del propio cliente — o sea que para saber cómo va NUESTRO
-- negocio había que entrar con las credenciales del cliente.
--
-- Esta función es la misma cuenta que ya hace el panel del organizador,
-- pero para todos los clientes juntos y sin salir de nuestra cuenta.
--
-- ── por qué reusa disponible_de y no recalcula ──
--
-- Porque el disponible es la cifra que decide si sale plata, y ya está
-- escrita una vez en `disponible_de` con todas sus reglas: el anticipo
-- del 70% hasta que pase la fecha, el techo de lo realmente cobrado, las
-- órdenes simuladas que no cuentan, lo ya pedido. Reescribirla acá sería
-- garantizar que dentro de un mes las dos pantallas digan números
-- distintos, y que nadie sepa cuál de las dos miente.
--
-- Cuesta unas cuantas consultas por evento. Con la cantidad de fechas que
-- maneja hoy la ticketera no se nota; el día que sean cientos, esto se
-- resuelve con una materializada y no aflojando la regla.
--
-- ── qué eventos entran ──
--
-- Los publicados y los cerrados, y ADEMÁS cualquiera que tenga una orden
-- pagada de verdad aunque hoy esté en borrador. Un evento con plata
-- adentro que alguien despublicó no puede desaparecer del tablero: es
-- exactamente el que se olvida sin liquidar.
-- ============================================================

drop function if exists eventos_plataforma();
create function eventos_plataforma() returns jsonb
  language plpgsql stable security definer set search_path = public as $function$
declare
  v_res jsonb := '[]'::jsonb; r record; d jsonb;
  v_pct numeric := costo_pasarela_pct();
  v_cobrado numeric(12,2); v_fee numeric(12,2); v_sub numeric(12,2); v_costo numeric(12,2);
begin
  if not es_plataforma() then raise exception 'Sin permiso'; end if;

  for r in
    select e.id, e.slug, e.nombre, e.fecha, e.estado, e.organizador_id,
           g.nombre as org_nombre, g.slug as org_slug,
           g.pago_automatico, g.pago_auto_minimo
      from eventos e
      join organizadores g on g.id = e.organizador_id and g.activo
     where e.estado in ('publicado','cerrado')
        or exists (select 1 from ordenes o
                    where o.evento_id = e.id and o.estado = 'pagada'
                      and coalesce(o.pago_ref,'') not like 'SIM-%')
     order by g.nombre, e.fecha
  loop
    select coalesce(sum(o.total),0), coalesce(sum(o.fee),0), coalesce(sum(o.subtotal),0)
      into v_cobrado, v_fee, v_sub
      from ordenes o
     where o.evento_id = r.id and o.estado = 'pagada'
       and coalesce(o.pago_ref,'') not like 'SIM-%';
    v_costo := round(v_cobrado * v_pct, 2);

    -- La misma cuenta que ve el organizador en su propio panel.
    d := disponible_de(r.organizador_id, r.id);

    v_res := v_res || jsonb_build_object(
      'organizador', r.org_nombre, 'org_slug', r.org_slug,
      'evento', r.nombre, 'slug', r.slug, 'fecha', r.fecha, 'estado', r.estado,
      'entradas', (select count(*) from entradas x
                    where x.evento_id = r.id and x.estado <> 'anulada'),
      'cobrado', v_cobrado, 'nuestro', v_fee, 'del_cliente', v_sub,
      'costo_pasarela', v_costo, 'margen', round(v_fee - v_costo, 2),
      'girado',    (select coalesce(sum(p.monto),0) from pago_organizador p
                     where p.evento_id = r.id and p.estado <> 'rechazado'),
      'en_camino', (select coalesce(sum(p.monto),0) from pago_organizador p
                     where p.evento_id = r.id
                       and p.estado in ('pedido','enviado','aprobacion_manual')),
      'rechazados',(select count(*) from pago_organizador p
                     where p.evento_id = r.id and p.estado = 'rechazado'),
      -- Lo que se le puede mandar HOY, con el tope del anticipo aplicado.
      'disponible',   (d->>'disponible')::numeric,
      'evento_pasado',(d->>'evento_pasado')::boolean,
      -- Lo que todavía le debemos en total, sin el tope: sirve para ver
      -- cuánta plata queda retenida esperando a que pase la fecha.
      'por_girar', round(v_sub - (select coalesce(sum(p.monto),0) from pago_organizador p
                                   where p.evento_id = r.id and p.estado <> 'rechazado'), 2),
      'simuladas', (select coalesce(sum(o.total),0) from ordenes o
                     where o.evento_id = r.id and o.estado = 'pagada'
                       and coalesce(o.pago_ref,'') like 'SIM-%'),
      'automatico', r.pago_automatico, 'minimo', r.pago_auto_minimo);
  end loop;

  return jsonb_build_object('ok', true, 'eventos', v_res);
end $function$;

revoke execute on function eventos_plataforma() from anon, public;
grant  execute on function eventos_plataforma() to authenticated;

comment on function eventos_plataforma() is
  'El tablero de TICKETAZO abierto por evento: cobrado, comision, costo de pasarela, girado y disponible de cada fecha de cada cliente. Guardado por es_plataforma(). El disponible sale de disponible_de(), la misma funcion que ve el organizador, para que las dos pantallas no puedan discrepar.';

-- ── control ─────────────────────────────────────────────────
select * from chequeo_funciones_sin_guardia();
