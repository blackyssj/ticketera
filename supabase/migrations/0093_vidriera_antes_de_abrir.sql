-- ============================================================
-- 0093 — la vidriera muestra el evento aunque la venta todavía no abra
--
-- Los relacionadores reparten /<organizador>?r=<codigo>, la vidriera del
-- cliente. cartelera_publica() solo traía eventos con una fase abierta
-- AHORA, así que el 01/10 —LÜMEN con la Welcome programada para las
-- 19:30 y los 131 links ya circulando— la vidriera decía "Este
-- organizador no tiene nada a la venta ahora". El que llegaba por el link
-- se iba sin saber que en dos horas abría, justo en la previa que el
-- relacionador estaba armando.
--
-- Ahora entra también el evento publicado que tiene fases públicas pero
-- ninguna abierta (el mismo criterio que 0092 usa en la página): trae
-- `abre`, la próxima hora en que abre una fase, y `precio_proximo`, el
-- más barato de lo que abre a esa hora, para que la tarjeta diga
-- "Abre hoy 19:30 · desde 50 Bs". Sin nada por abrir es un evento
-- agotado y se muestra como tal en vez de desaparecer.
--
-- Lo que se puede COMPRAR no cambia: crear_orden sigue preguntándole a
-- fase_vigente(). `precios` sigue siendo solo de la fase abierta, así que
-- con la venta cerrada viaja vacío.
-- ============================================================

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
              where p.fase_id = f.fase_id and t.activo and t.en_cartelera), '[]'::jsonb),
           'abre', pr.abre,
           'precio_proximo', pr.precio
         ) order by e.fecha, e.hora_inicio), '[]'::jsonb)
    from eventos e
    join organizadores o on o.id = e.organizador_id and o.activo
    cross join lateral (select fase_vigente(e.id) as fase_id) f
    -- Sin fase abierta: cuándo abre la próxima y desde cuánto.
    cross join lateral (
      select min(x.desde) as abre,
             min(p.precio) filter (where x.desde = (
               select min(y.desde) from evento_fase y
                where y.evento_id = e.id and y.activo and y.desde > now())) as precio
        from evento_fase x
        join fase_precio p on p.fase_id = x.id
        join tipo_entrada t on t.id = p.tipo_id and t.activo and t.en_cartelera
       where f.fase_id is null and x.evento_id = e.id and x.activo and x.desde > now()) pr
   where e.estado = 'publicado'
     and e.listado
     and e.fecha >= (now() at time zone 'America/La_Paz')::date
     and (f.fase_id is not null or exists (
           select 1 from evento_fase x
             join fase_precio p on p.fase_id = x.id
             join tipo_entrada t on t.id = p.tipo_id and t.activo and t.en_cartelera
            where x.evento_id = e.id and x.activo))
$$;
revoke all on function cartelera_publica() from public, anon, authenticated;
grant execute on function cartelera_publica() to service_role;

-- Vacío o la migración se queda a medias.
select * from chequeo_funciones_sin_guardia();
