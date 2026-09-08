-- ============================================================
-- 0074 — cuántas quedan es un dato del organizador, no del público
--
-- La página del evento decía "Quedan 17" debajo de cada tipo. Para
-- nosotros es el argumento de venta: el número que apura. Para el cliente
-- es un número que no quiere en la calle —cuenta a la competencia cómo va
-- la venta y a los compradores cuánto margen tienen para esperar.
--
-- ── por qué es un interruptor por organizador ──
--
-- Porque no hay una respuesta correcta para todos. El que llena boliches
-- vive de "quedan 6"; el que produce ferias no quiere que se sepa. Un
-- interruptor global obliga a uno de los dos a aguantar la regla del
-- otro. Va en `organizadores` y no en `eventos` por la misma razón que
-- `rrpp_ve_ventas`: es una política de la casa, no un detalle de la fecha,
-- y el cliente que la pide la pide para todas sus fechas.
--
-- ── qué se esconde y qué no ──
--
-- Se esconde el NÚMERO. "Agotado" sigue saliendo: no es una cuenta, es un
-- estado, y sin él el comprador aprieta + y la página le dice que no puede
-- sin decirle por qué. En la portada, el sello "Últimas entradas" también
-- se calla: no dice el número pero dice que hay pocas, que es lo mismo
-- dicho con menos cifras. "Agotado" en la portada sí sigue.
--
-- El cupo sigue viajando al navegador: el stepper lo necesita para no
-- dejar pedir más de lo que hay. Lo que cambia es que no se PINTA. Si
-- algún día hace falta que ni viaje, es otra migración con otro costo:
-- la página tendría que descubrir el tope a los golpes.
-- ============================================================

alter table organizadores
  add column if not exists muestra_cupo boolean not null default true;

comment on column organizadores.muestra_cupo is
  'true: la pagina publica dice "Quedan N" / "N disponibles" y la portada "Ultimas entradas". false: solo "Agotado". El cupo viaja igual para el stepper.';

-- ── la página del evento ────────────────────────────────────
-- Misma función que en 0064, más `muestra_cupo` en el organizador. Se
-- reescribe entera porque una función no se parcha.
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
      'muestra_cupo', v_o.muestra_cupo),
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

-- ── la portada ──────────────────────────────────────────────
-- Igual que en 0071, más `muestra_cupo` junto al organizador. La función
-- `eventos` decide con él si el sello "Últimas entradas" se dice o no.
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
     and e.fecha >= (now() at time zone 'America/La_Paz')::date
     and f.fase_id is not null
$$;
revoke all on function cartelera_publica() from public, anon, authenticated;
grant execute on function cartelera_publica() to service_role;

-- ── el panel lo sabe ────────────────────────────────────────
drop function if exists mi_organizador_config();
create function mi_organizador_config() returns jsonb
  language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
           'slug',           o.slug,
           'nombre',         o.nombre,
           'rrpp_ve_ventas', o.rrpp_ve_ventas,
           'comision_modo',  o.comision_modo,
           'muestra_cupo',   o.muestra_cupo)
    from organizadores o
   where o.id = mi_organizador() and auth.uid() is not null
$$;
revoke execute on function mi_organizador_config() from anon, public;
grant execute on function mi_organizador_config() to authenticated;

comment on function mi_organizador_config() is
  'Lo que la pantalla necesita saber del organizador de quien pregunta. Acotado a mi_organizador(): nadie lee la config de otro.';

-- ── el interruptor, solo admin ──────────────────────────────
drop function if exists guardar_muestra_cupo(boolean);
create function guardar_muestra_cupo(p_muestra boolean) returns jsonb
  language plpgsql volatile security definer set search_path = public as $function$
declare o organizadores;
begin
  if mi_rol() <> 'admin' then raise exception 'Sin permiso'; end if;
  update organizadores set muestra_cupo = coalesce(p_muestra, true)
   where id = mi_organizador() returning * into o;
  return jsonb_build_object('ok', true, 'muestra', o.muestra_cupo, 'motivo',
    case when o.muestra_cupo
      then 'La página vuelve a decir cuántas entradas quedan.'
      else 'La página ya no dice cuántas quedan. Solo avisa cuando se agota.' end);
end $function$;
revoke execute on function guardar_muestra_cupo(boolean) from anon, public;
grant execute on function guardar_muestra_cupo(boolean) to authenticated;

-- ── el cliente que lo pidió ─────────────────────────────────
update organizadores set muestra_cupo = false where slug = 'distrito-ferial';

-- ── control ─────────────────────────────────────────────────
-- Vacío o la migración se queda a medias.
select * from chequeo_funciones_sin_guardia();
