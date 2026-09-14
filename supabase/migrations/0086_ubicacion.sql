-- 0086 — dónde queda: dirección y punto en el mapa del evento
--
-- "La Esquina Ferial" es un nombre, no una dirección. El comprador que no
-- conoce el lugar abre el link a las diez de la noche y no sabe a dónde ir.
-- Tres columnas en eventos: la dirección en texto y el punto (lat, lng)
-- que la página usa para el mapa y para el botón "Cómo llegar", que en el
-- teléfono abre la app de mapas. Las dos coordenadas van juntas o no van:
-- un lat sin lng es un punto que no existe.
--
-- El panel las carga desde el formulario del evento: la dirección a mano y
-- el punto pegando el link de "Compartir" de Google Maps (admin.js lo lee).

alter table eventos
  add column if not exists direccion text,
  add column if not exists lat numeric(9,6),
  add column if not exists lng numeric(9,6);

do $$ begin
  alter table eventos add constraint eventos_punto_completo_check
    check ((lat is null) = (lng is null)
           and (lat is null or (lat between -90 and 90 and lng between -180 and 180)));
exception when duplicate_object then null; end $$;

comment on column eventos.direccion is 'Dirección en texto para el comprador (calle, referencia). Distinta de `lugar`, que es el nombre del sitio.';
comment on column eventos.lat is 'Latitud del punto del evento. Va con lng o no va.';
comment on column eventos.lng is 'Longitud del punto del evento. Va con lat o no va.';

-- ── la página del evento: igual que en 0085, más dirección y punto ──
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
                      where m.evento_id = v_e.id and m.estado = 'libre'));
end $function$;
revoke execute on function evento_publico(text, text) from anon, public, authenticated;

-- ── Distrito Ferial: sus dos fechas son en el mismo lugar ──
update eventos e
   set direccion = 'Calle Juan Carlos Tórrez', lat = -17.785582, lng = -63.212349
  from organizadores o
 where o.id = e.organizador_id and o.slug = 'distrito-ferial'
   and e.slug in ('viernes-18', 'miercoles-23');

-- Vacío o la migración se queda a medias.
select * from chequeo_funciones_sin_guardia();
