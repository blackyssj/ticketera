-- 0085 — evento sin listar: público por link, ausente de la cartelera
--
-- Hay eventos que se venden pero no se anuncian: una demo que se le muestra
-- a un cliente antes de firmar, la fiesta de una empresa, una promo de
-- colegio que reparte el link por su grupo. Hasta hoy "publicado" era una
-- sola cosa: a la venta Y en la portada de TICKETAZO. `listado` separa las
-- dos: en false, la página del evento funciona igual (evento_publico no
-- mira esta columna) pero la cartelera general no lo muestra y la página
-- de sus hermanos no lo cuenta entre "otras fechas".
--
-- Se edita desde el formulario del evento en el panel (admin.js), con la
-- misma policy que el resto de las columnas del evento.

alter table eventos add column if not exists listado boolean not null default true;
comment on column eventos.listado is
  'true: aparece en la cartelera de TICKETAZO y cuenta como "otra fecha" del organizador. false: solo se llega por el link directo. No cambia si está a la venta: eso sigue siendo `estado`.';

-- ── la portada: igual que en 0074, más `and e.listado` ──────
create or replace function cartelera_publica() returns jsonb
  language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', e.id, 'slug', e.slug, 'nombre', e.nombre, 'lugar', e.lugar,
           'fecha', e.fecha, 'hora_inicio', e.hora_inicio, 'flyer_url', e.flyer_url,
           'color_fondo', e.color_fondo, 'color_acento', e.color_acento,
           'organizadores', jsonb_build_object('slug', o.slug, 'nombre', o.nombre,
                                               'muestra_cupo', o.muestra_cupo),
           'precios', coalesce((
             select jsonb_agg(jsonb_build_object(
                      'tipo_id', p.tipo_id, 'precio', p.precio, 'cupo', p.cupo,
                      'disponible', case when p.cupo is null then null
                                         else disponibilidad_tipo(f.fase_id, p.tipo_id) end))
               from fase_precio p join tipo_entrada t on t.id = p.tipo_id
              where p.fase_id = f.fase_id and t.activo and t.en_cartelera), '[]'::jsonb)
         ) order by e.fecha, e.hora_inicio), '[]'::jsonb)
    from eventos e
    join organizadores o on o.id = e.organizador_id and o.activo
    cross join lateral (select fase_vigente(e.id) as fase_id) f
   where e.estado = 'publicado'
     and e.listado
     and e.fecha >= (now() at time zone 'America/La_Paz')::date
     and f.fase_id is not null
$$;
revoke all on function cartelera_publica() from public, anon, authenticated;
grant execute on function cartelera_publica() to service_role;

-- ── la página del evento: igual que en 0075, `fechas` solo cuenta listados ──
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
      'lugar', v_e.lugar, 'fecha', v_e.fecha, 'hora_inicio', v_e.hora_inicio,
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
                      where m.evento_id = v_e.id and m.estado = 'libre'));
end $function$;
revoke execute on function evento_publico(text, text) from anon, public, authenticated;

-- Vacío o la migración se queda a medias.
select * from chequeo_funciones_sin_guardia();
