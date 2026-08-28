-- ============================================================
-- 0026 — lo que vendió el relacionador y lo que le toca cobrar
--
-- Dos funciones y una base común:
--
--   mis_ventas(p_evento)      — lo que ve la persona. Filtra por auth.uid()
--                               ADENTRO. No recibe p_perfil: un parámetro
--                               con el id sería exactamente el agujero que
--                               esta tarea existe para cerrar, porque el
--                               navegador puede mandar el del compañero.
--   ventas_por_rrpp(p_evento) — el desglose por persona, para el admin.
--                               Exige puede_editar() como guardar_precios.
--
-- Tres decisiones que están acá y no en el frontend:
--
-- 1) Las entradas se cuentan de `entradas`, NO de orden_items.cantidad ni
--    del número de órdenes. Un combo de mesa emite N entradas (una por
--    manilla) desde una sola orden con un solo item de cantidad 1: contar
--    órdenes daría 1 donde hay 10. Es el mismo error que ya nos mordió en
--    el cupo.
--
-- 2) Una entrada anulada no cuenta: ni como entrada vendida ni como
--    comisión. Lo recaudado sí se queda con el subtotal completo de la
--    orden — la orden se cobró — pero una orden a la que no le queda
--    ninguna entrada válida desaparece entera del reporte.
--
-- 3) La atribución que manda es ordenes.rrpp_id, que es lo que escribe
--    crear-orden (0025). entradas.rrpp_id no se mira: hoy emitir_orden ni
--    siquiera lo copia, y tener dos fuentes para el mismo dato es cómo se
--    empieza a discutir con un relacionador delante del cliente. Se une
--    por la orden y listo.
--
-- Lo recaudado sale de ordenes.subtotal, no de sumar entradas.precio:
-- un combo de 2 manillas a 200 emite dos entradas con precio 200 cada una
-- (0016), así que sumarlas daría 400 donde entraron 200; y las entradas de
-- mesa se emiten con precio 0, así que darían 0 donde entró la mesa
-- entera. El subtotal de la orden es la única cifra que no miente en los
-- dos casos. Es el subtotal, no el total: el fee es de la plataforma.
--
-- La comisión es entradas × comision_de(persona, evento) — monto fijo por
-- entrada (0024). No toca fase_precio: si mañana sube el precio de la
-- manilla, esta cifra no se mueve.
-- ============================================================

-- Cambiar la firma de una función es drop + create (invariante 4: dos
-- firmas vivas dejan a PostgREST sin poder elegir candidata y la función
-- queda muerta sin que nada avise). `if exists` para que correr esta
-- migración dos veces no falle.
drop function if exists mis_ventas(uuid);
drop function if exists ventas_por_rrpp(uuid);
drop function if exists ventas_rrpp_base(uuid, uuid);

-- ── la base: una sola cuenta, dos lecturas ──────────────────
-- No se expone a nadie. Es el cuerpo compartido de las dos funciones de
-- abajo: si la cuenta de la comisión viviera duplicada en las dos, en
-- algún momento una de las dos se corregiría sola y el relacionador vería
-- un número distinto del que ve el admin.
create or replace function ventas_rrpp_base(p_evento uuid, p_perfil uuid)
returns table (
  perfil_id         uuid,
  evento_id         uuid,
  evento_nombre     text,
  evento_fecha      date,
  entradas          int,
  recaudado         numeric(12,2),
  comision_unitaria numeric(12,2),
  comision          numeric(12,2)
)
  language sql stable security definer set search_path = public as $$
  with ordenes_rrpp as (
    select o.id, o.evento_id, o.rrpp_id, o.subtotal,
           (select count(*) from entradas e
             where e.orden_id = o.id and e.estado <> 'anulada')::int as validas
      from ordenes o
     where o.organizador_id = mi_organizador()   -- el corte de tenant, siempre
       and o.estado = 'pagada'                   -- pendiente o vencida no es venta
       and o.rrpp_id is not null
       and (p_evento is null or o.evento_id = p_evento)
       and (p_perfil is null or o.rrpp_id = p_perfil)
  ),
  por_evento as (
    select r.rrpp_id, r.evento_id,
           sum(r.validas)::int as entradas,
           sum(r.subtotal)::numeric(12,2) as recaudado
      from ordenes_rrpp r
     where r.validas > 0
     group by r.rrpp_id, r.evento_id
  )
  select pe.rrpp_id, pe.evento_id, ev.nombre, ev.fecha,
         pe.entradas, pe.recaudado,
         comision_de(pe.rrpp_id, pe.evento_id)::numeric(12,2),
         (pe.entradas * comision_de(pe.rrpp_id, pe.evento_id))::numeric(12,2)
    from por_evento pe
    join eventos ev on ev.id = pe.evento_id
   where ev.organizador_id = mi_organizador()
$$;
revoke execute on function ventas_rrpp_base(uuid, uuid) from public, anon, authenticated;

comment on function ventas_rrpp_base(uuid, uuid) is
  'Cuerpo compartido de mis_ventas() y ventas_por_rrpp(): una fila por (relacionador, evento) con entradas válidas, recaudado y comisión. Acota por mi_organizador() adentro, no por parámetro. No se expone: se llama solo desde las dos funciones de arriba.';

-- ── lo que ve la persona ────────────────────────────────────
create or replace function mis_ventas(p_evento uuid default null) returns jsonb
  language plpgsql stable security definer set search_path = public as $function$
declare v_yo uuid := auth.uid();
begin
  -- sin sesión no hay ventas que mostrar. mi_organizador() ya devolvería
  -- null y no saldría ninguna fila, pero el corte explícito evita que un
  -- cambio futuro en la base lo convierta en "todas las de todos".
  if v_yo is null then return '[]'::jsonb; end if;

  return (
    select coalesce(jsonb_agg(jsonb_build_object(
             'evento_id',         v.evento_id,
             'evento_nombre',     v.evento_nombre,
             'evento_fecha',      v.evento_fecha,
             'entradas',          v.entradas,
             'recaudado',         v.recaudado,
             'comision_unitaria', v.comision_unitaria,
             'comision',          v.comision)
           order by v.comision desc, v.evento_fecha desc), '[]'::jsonb)
      from ventas_rrpp_base(p_evento, v_yo) v);
end $function$;
revoke execute on function mis_ventas(uuid) from anon, public;
grant execute on function mis_ventas(uuid) to authenticated;

comment on function mis_ventas(uuid) is
  'Las ventas del usuario de la sesión, por evento. Sin p_evento: todos los eventos de su organizador donde vendió algo. No recibe el id de la persona a propósito: sale de auth.uid().';

-- ── el desglose por persona, para el admin ──────────────────
create or replace function ventas_por_rrpp(p_evento uuid) returns jsonb
  language plpgsql stable security definer set search_path = public as $function$
begin
  if not puede_editar() then raise exception 'Sin permiso'; end if;

  return (
    select coalesce(jsonb_agg(jsonb_build_object(
             'perfil_id',         v.perfil_id,
             'nombre',            p.nombre,
             'slug',              p.slug,
             'evento_id',         v.evento_id,
             'evento_nombre',     v.evento_nombre,
             'evento_fecha',      v.evento_fecha,
             'entradas',          v.entradas,
             'recaudado',         v.recaudado,
             'comision_unitaria', v.comision_unitaria,
             'comision',          v.comision)
           order by v.comision desc, p.nombre), '[]'::jsonb)
      from ventas_rrpp_base(p_evento, null) v
      -- el join también acota por organizador: esta función corre como
      -- definer, así que la RLS de perfiles no la frena, y una orden con
      -- un rrpp_id de otro tenant (que crear-orden no puede producir, pero
      -- la columna sí admite) filtraría el nombre de esa persona.
      join perfiles p on p.id = v.perfil_id and p.organizador_id = mi_organizador());
end $function$;
revoke execute on function ventas_por_rrpp(uuid) from anon, public;
grant execute on function ventas_por_rrpp(uuid) to authenticated;

comment on function ventas_por_rrpp(uuid) is
  'El desglose por relacionador de un evento, ordenado por comisión descendente. Exige puede_editar(): un rrpp no ve lo que vendieron los demás. Con p_evento null devuelve todos los eventos del organizador.';
