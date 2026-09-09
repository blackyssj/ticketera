-- ============================================================
-- 0081 — el tablero por evento dice a dónde iría la plata
--
-- 0079 armó la tabla por evento para MIRAR. Con 0080 esa misma fila pasa
-- a tener un botón que gira de verdad, y para eso le faltan dos cosas:
--
--   · el `id` del evento, que es lo que hay que mandarle a `liquidar`.
--     0079 no lo devolvía porque nadie lo necesitaba para leer.
--
--   · la cuenta bancaria a la que iría el giro. Un botón que dice
--     "girar 280 Bs" sin decir a qué cuenta es un botón que se aprieta a
--     ciegas: el operador de plataforma no tiene el panel del cliente
--     abierto al lado, y la cuenta la cargó el cliente. La confirmación
--     tiene que poder mostrar titular, banco y número, que es lo único
--     que permite frenar antes de mandar plata al lugar equivocado.
--
-- Sale de `disponible_de`, que ya la trae armada: no hay una consulta más.
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
      -- El uuid: es lo que `liquidar` necesita para girar desde acá.
      'id', r.id,
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
      -- A dónde iría el giro. Sin esto el botón se aprieta a ciegas.
      'cuenta', d->'cuenta',
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
  'El tablero de TICKETAZO abierto por evento: cobrado, comision, costo de pasarela, girado, disponible y la cuenta destino de cada fecha de cada cliente. Guardado por es_plataforma(). El disponible sale de disponible_de(), la misma funcion que ve el organizador, para que las dos pantallas no puedan discrepar.';

-- ── control ─────────────────────────────────────────────────
select * from chequeo_funciones_sin_guardia();
