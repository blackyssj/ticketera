-- ============================================================
-- 0075 — la página del evento sabe si el organizador tiene otras fechas
--
-- El relacionador repartió durante días el link viejo, el de UN evento.
-- El que llega por ahí ve esa noche y nada más: no tiene cómo enterarse
-- de que el mismo organizador vende otra fecha la semana siguiente, y la
-- vidriera del link único —que existe para eso— le queda a un paso que
-- nadie le muestra.
--
-- La página necesita un solo dato para ofrecer ese paso: cuántas fechas
-- del organizador están a la venta, esta incluida. Con más de una,
-- muestra el camino a la vidriera; con una sola, no hay a dónde ir y no
-- muestra nada.
--
-- Se cuenta con el MISMO criterio que la vidriera (cartelera_publica):
-- publicado, de hoy en adelante en La Paz, y con una fase abierta. Un
-- evento publicado sin fase abierta no aparece en la vidriera, así que
-- contarlo mandaría al comprador a una lista donde sólo está la fecha
-- de la que vino.
--
-- Va en evento_publico y no en otro viaje desde la función: la página
-- del evento se hizo de un solo pedido a propósito (0048) y un count de
-- dos filas no justifica romper eso.
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
                    and x.fecha >= (now() at time zone 'America/La_Paz')::date
                    and fase_vigente(x.id) is not null)),
    'evento', jsonb_build_object(
      'id', v_e.id, 'nombre', v_e.nombre, 'descripcion', v_e.descripcion,
      'lugar', v_e.lugar, 'fecha', v_e.fecha, 'hora_inicio', v_e.hora_inicio,
      'edad_min', v_e.edad_min, 'estado', v_e.estado,
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
                      where m.evento_id = v_e.id and m.estado = 'libre'));
end $function$;
revoke execute on function evento_publico(text, text) from anon, public, authenticated;

-- Vacío o la migración se queda a medias.
select * from chequeo_funciones_sin_guardia();
