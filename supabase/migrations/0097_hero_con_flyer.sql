-- ============================================================
-- 0097 — la página del evento muestra el flyer arriba
--
-- El afiche del hero salía de `arte_url`, que es el MODELO DE LA ENTRADA:
-- el fondo sobre el que se dibuja el QR, con el hueco en el medio. Nocturne
-- trajo las dos piezas por separado —el flyer del evento y un fondo de
-- calaveras para la entrada— y el cliente quiere ver su flyer en la página,
-- no el fondo de la entrada. Es lo mismo que ya pasa en la cartelera y en
-- la tarjeta de WhatsApp: el flyer es la cara del evento.
--
-- evento_publico ahora también devuelve `flyer_url`. La página lo usa en el
-- hero si existe y, si no, sigue con el arte como hasta hoy. La entrada no
-- cambia: se sigue dibujando sobre el arte (o el de la fase).
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
  -- Sin fase abierta, la página igual se muestra si el evento TIENE fases
  -- públicas: antes de que abra la venta (dice cuándo), entre una tanda
  -- agotada y la próxima por fecha, o con todo vendido (dice sold out).
  -- El "no hay fase" queda para un evento sin nada cargado.
  if v_fase is null and not exists (
       select 1 from evento_fase f
         join fase_precio p on p.fase_id = f.id
         join tipo_entrada t on t.id = p.tipo_id and t.activo and t.en_cartelera
        where f.evento_id = v_e.id and f.activo) then
    return jsonb_build_object('falta', 'fase');
  end if;
  if v_fase is not null then
    select * into v_f from evento_fase where id = v_fase;
  end if;

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
      'logo_url', v_e.logo_url, 'flyer_url', v_e.flyer_url),
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
    'sin_venta', v_fase is null,
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
                     -- El precio que se anuncia es el de lo que todavía se
                     -- puede comprar; si no queda nada, el de siempre
                     -- (es el que va tachado).
                     coalesce(min(p.precio) filter (where p.cupo is null
                                or disponibilidad_tipo(f.id, p.tipo_id) > 0),
                              min(p.precio)) as precio,
                     count(distinct p.precio) > 1 as varios,
                     case
                       when f.id = v_fase then 'vigente'
                       -- Vendida de verdad: lo PAGADO llena el cupo.
                       when bool_and(p.cupo is not null and
                              (select coalesce(sum(i.cantidad), 0) from orden_items i
                                 join ordenes o on o.id = i.orden_id
                                where i.fase_id = f.id and i.tipo_id = p.tipo_id
                                  and o.estado = 'pagada') >= p.cupo)
                         then 'agotada'
                       -- Sin lugar, pero porque hay compras a medio pagar: si
                       -- alguna vence, vuelve a la venta. No es "sold out".
                       when bool_and(p.cupo is not null
                              and coalesce(disponibilidad_tipo(f.id, p.tipo_id), 1) = 0)
                         then 'retenida'
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
