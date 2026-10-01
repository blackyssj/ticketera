-- ============================================================
-- 0091 — la página del evento muestra todas las fases, no solo la de hoy
--
-- LÜMEN vende por tandas: Welcome Ticket a 50, First Offering a 120,
-- Second a 160, Too Late To Pray a 200. La página mostraba solo la fase
-- abierta, así que el que entraba veía "50 Bs" y nada más: no sabía que
-- al agotarse sube a 120 —que es justo el argumento para comprar ya— y
-- cuando la Welcome se agotaba desaparecía sin rastro, como si nunca
-- hubiera existido el precio barato que otros sí agarraron.
--
-- evento_publico suma `fases`: cada fase pública con su precio (el más
-- bajo, y `varios` si hay tipos con precios distintos) y un estado:
--   vigente  la que vende ahora
--   agotada  todo lo suyo con cupo y sin nada para vender ("sold out")
--   cerrada  pasó su fecha de cierre sin agotarse
--   proxima  todavía no abrió: espera su fecha o que se agote la anterior
--
-- Agotada se mira ANTES que cerrada a propósito: una tanda que se vendió
-- entera y después llegó a su hora de cierre se cuenta como vendida, que
-- es lo que pasó y lo que el organizador quiere mostrar.
--
-- Se cuenta con los mismos criterios que fase_vigente() (0061): sin eso
-- la lista podría decir "a la venta" sobre una fase que crear_orden no
-- vende, o "sold out" sobre una que sí.
--
-- Va en el mismo viaje (0048): son pocas filas y la página se pinta de
-- un solo pedido.
-- ============================================================

create or replace function evento_publico(p_org text, p_slug text) returns jsonb
  language plpgsql stable security definer set search_path = public as $function$
declare
  v_o organizadores%rowtype; v_e eventos%rowtype;
  v_fase uuid; v_f evento_fase%rowtype;
begin
  select * into v_o from organizadores where slug = p_org and activo;
  if not found then return jsonb_build_object('falta', 'organizador'); end if;

  select * into v_e from eventos where organizador_id = v_o.id and slug = p_slug;
  if not found then return jsonb_build_object('falta', 'evento'); end if;
  if v_e.estado <> 'publicado' then return jsonb_build_object('falta', 'publicado'); end if;

  v_fase := fase_vigente(v_e.id);
  if v_fase is null then return jsonb_build_object('falta', 'fase'); end if;
  select * into v_f from evento_fase where id = v_fase;

  return jsonb_build_object(
    'organizador', jsonb_build_object(
      'id', v_o.id, 'nombre', v_o.nombre, 'fee_pct', v_o.fee_pct,
      'fee_fijo_transaccion', v_o.fee_fijo_transaccion, 'fee_piso', v_o.fee_piso,
      'comision_modo', v_o.comision_modo,
      'muestra_cupo', v_o.muestra_cupo,
      'fechas', (select count(*) from eventos x
                  where x.organizador_id = v_o.id
                    and x.estado = 'publicado'
                    and x.listado
                    and x.fecha >= (now() at time zone 'America/La_Paz')::date
                    and fase_vigente(x.id) is not null)),
    'evento', jsonb_build_object(
      'id', v_e.id, 'nombre', v_e.nombre, 'descripcion', v_e.descripcion,
      'lugar', v_e.lugar, 'direccion', v_e.direccion, 'lat', v_e.lat, 'lng', v_e.lng,
      'fecha', v_e.fecha, 'hora_inicio', v_e.hora_inicio,
      'edad_min', v_e.edad_min, 'estado', v_e.estado, 'listado', v_e.listado,
      'tope_entradas_orden', v_e.tope_entradas_orden, 'arte_url', v_e.arte_url,
      'color_fondo', v_e.color_fondo, 'color_acento', v_e.color_acento,
      'logo_url', v_e.logo_url),
    'fase', jsonb_build_object(
      'id', v_f.id, 'nombre', v_f.nombre, 'hasta', v_f.hasta, 'arte_url', v_f.arte_url),
    'precios', coalesce((
      select jsonb_agg(jsonb_build_object(
               'tipo_id', p.tipo_id, 'precio', p.precio, 'cupo', p.cupo,
               'disponible', case when p.cupo is null then null
                                  else disponibilidad_tipo(v_fase, p.tipo_id) end,
               'tipo_entrada', jsonb_build_object(
                 'id', t.id, 'nombre', t.nombre, 'descripcion', t.descripcion,
                 'incluye', t.incluye, 'categoria', t.categoria,
                 'manillas', t.manillas, 'orden', t.orden, 'activo', t.activo))
             order by t.orden)
        from fase_precio p join tipo_entrada t on t.id = p.tipo_id
       where p.fase_id = v_fase and t.evento_id = v_e.id and t.activo), '[]'::jsonb),
    'mesas_libres', (select count(*) from mesas m
                      where m.evento_id = v_e.id and m.estado = 'libre'),
    -- Todas las fases públicas del evento, en orden, con su precio y en
    -- qué está cada una. Mismos criterios que fase_vigente(): cuenta solo
    -- lo que es oferta al público (tipo activo y en_cartelera) y una fase
    -- está agotada cuando TODO lo suyo tiene cupo y no le queda nada.
    'fases', coalesce((
      select jsonb_agg(jsonb_build_object(
               'nombre', x.nombre, 'precio', x.precio, 'varios', x.varios,
               'estado', x.estado, 'desde', x.desde, 'hasta', x.hasta)
             order by x.orden)
        from (select f.nombre, f.orden, f.desde, f.hasta,
                     min(p.precio) as precio,
                     count(distinct p.precio) > 1 as varios,
                     case
                       when f.id = v_fase then 'vigente'
                       when bool_and(p.cupo is not null
                              and coalesce(disponibilidad_tipo(f.id, p.tipo_id), 1) = 0)
                         then 'agotada'
                       when f.hasta is not null and f.hasta <= now() then 'cerrada'
                       else 'proxima'
                     end as estado
                from evento_fase f
                join fase_precio p on p.fase_id = f.id
                join tipo_entrada t on t.id = p.tipo_id and t.activo and t.en_cartelera
               where f.evento_id = v_e.id and f.activo
               group by f.id) x), '[]'::jsonb));
end $function$;

revoke execute on function evento_publico(text, text) from anon, public, authenticated;

-- Vacío o la migración se queda a medias.
select * from chequeo_funciones_sin_guardia();
