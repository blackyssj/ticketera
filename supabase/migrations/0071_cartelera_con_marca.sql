-- ============================================================
-- 0071 — el afiche tipográfico toma el color del cliente
--
-- En la portada, un evento sin flyer sale como un cartel dibujado: el día
-- en grande, el nombre y el organizador sobre un papel a rayas. El color
-- de ese papel es el violeta de TICKETAZO, y es lo único que hay.
--
-- Con dos fechas del mismo cliente al lado —una con su arte rojo sobre
-- vino y la otra en violeta— no se leen como dos funciones de lo mismo:
-- se leen como que a la segunda le falta algo. Que es verdad, le falta el
-- flyer; pero mientras no llegue, mostrarla en la marca del cliente es
-- infinitamente mejor que mostrarla en la nuestra.
--
-- La portada ya sabía hacerlo: `papel` con dos colores existe desde la
-- cartelera de demostración, donde nueve carteles del mismo violeta se
-- leían como un error de carga. Lo único que faltaba era que la cartelera
-- real mandara los colores. Cero código nuevo del lado del navegador.
--
-- La portada sigue siendo de TICKETAZO —el fondo, la tipografía, la
-- estructura— y eso no se toca: es nuestra vidriera y muestra a todos.
-- Lo que toma la marca es la tarjeta del evento, que es del cliente.
-- ============================================================

create or replace function cartelera_publica() returns jsonb
  language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', e.id, 'slug', e.slug, 'nombre', e.nombre, 'lugar', e.lugar,
           'fecha', e.fecha, 'hora_inicio', e.hora_inicio, 'flyer_url', e.flyer_url,
           -- Los dos colores de la marca, para el afiche dibujado. Van
           -- sueltos y no como par: el que decide si alcanzan para pintar
           -- algo es el front, que es quien sabe qué dibuja.
           'color_fondo', e.color_fondo, 'color_acento', e.color_acento,
           'organizadores', jsonb_build_object('slug', o.slug, 'nombre', o.nombre),
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
     and e.fecha >= (now() at time zone 'America/La_Paz')::date
     and f.fase_id is not null
$$;
revoke all on function cartelera_publica() from public, anon, authenticated;
grant execute on function cartelera_publica() to service_role;
