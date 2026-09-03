-- ============================================================
-- 0048 — la página del evento en UN solo viaje a la base
--
-- Lo que se midió: la Edge Function `evento` tardaba 0,7–0,9 s en caliente
-- (y más en frío) sin que la base tuviera nada que ver: la consulta en sí
-- es trivial. Lo que pesaba eran los viajes. La función encadenaba
-- organizadores → eventos → fase_vigente() → evento_fase → fase_precio →
-- disponibilidad_tipo() por cada tipo, uno atrás del otro, y cada ida y
-- vuelta a PostgREST cuesta más que la consulta que lleva adentro. Con
-- tres tipos eran siete pedidos en fila; el comprador miraba "Cargando el
-- evento…" mientras tanto. La cartelera (`eventos`) hacía lo mismo, con
-- una cadena por evento.
--
-- El arreglo es mover el armado a la base: una función devuelve en un
-- jsonb todo lo que la Edge Function necesitaba juntar. Un viaje, y las
-- consultas internas corren en el mismo proceso, sin red en el medio.
--
-- Quién la llama y por qué no es pública: SOLO la Edge Function, con
-- service_role. Igual que las demás funciones de esta base, se le revoca
-- todo a public/anon/authenticated. La Edge Function sigue siendo el
-- guardián: ella decide qué campos de esto viajan al navegador. Esta
-- función devuelve algo más de lo que se publica (uuids, `estado`, el
-- fee en crudo) porque la Edge Function ya los recibía por separado y los
-- usa para armar la respuesta; no aparece nada que hoy no leyera.
--
-- Semántica idéntica a la cadena que reemplaza: organizador inactivo o
-- inexistente, evento inexistente o sin publicar, fase sin abrir. En vez
-- de un null pelado devuelve `{"falta": ...}` con cuál de las cuatro
-- cosas faltó: la Edge Function respondía cuatro mensajes distintos (y
-- un 409 para la fase, no un 404) y el comprador los ve en pantalla.
-- Colapsarlos a "no existe" le diría a alguien con un link temprano que
-- el evento no existe cuando lo que pasa es que todavía no se publicó.
-- Lo que importa de la semántica se conserva: de un evento que no está a
-- la venta no sale ni un campo.
--
-- fase_vigente() y disponibilidad_tipo() se reusan tal cual. Son las
-- mismas que usa crear_orden, así que la página no puede anunciar un
-- precio o un cupo que la compra después no reconozca.
-- ============================================================

create or replace function evento_publico(p_org text, p_slug text) returns jsonb
  language plpgsql stable security definer set search_path = public as $function$
declare
  v_o    organizadores%rowtype;
  v_e    eventos%rowtype;
  v_fase uuid;
  v_f    evento_fase%rowtype;
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
      'fee_fijo_transaccion', v_o.fee_fijo_transaccion, 'fee_piso', v_o.fee_piso),
    'evento', jsonb_build_object(
      'id', v_e.id, 'nombre', v_e.nombre, 'descripcion', v_e.descripcion,
      'lugar', v_e.lugar, 'fecha', v_e.fecha, 'hora_inicio', v_e.hora_inicio,
      'edad_min', v_e.edad_min, 'estado', v_e.estado,
      'tope_entradas_orden', v_e.tope_entradas_orden, 'arte_url', v_e.arte_url),
    'fase', jsonb_build_object(
      'id', v_f.id, 'nombre', v_f.nombre, 'hasta', v_f.hasta, 'arte_url', v_f.arte_url),
    -- Solo tipos activos: los inactivos no se venden y la Edge Function ya
    -- los descartaba. `disponible` es null cuando no hay tope (cupo null),
    -- y eso la Edge Function lo traduce a 9999 como siempre; para esos no
    -- vale la pena ni contar. El orden va acá para que el front no lo
    -- tenga que rehacer.
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
       where p.fase_id = v_fase and t.activo), '[]'::jsonb));
end $function$;
revoke all on function evento_publico(text, text) from public, anon, authenticated;
grant execute on function evento_publico(text, text) to service_role;

comment on function evento_publico(text, text) is
  'Todo lo que la pagina publica de un evento necesita, en un jsonb y un solo viaje. La llama SOLO la Edge Function `evento` con service_role. Si algo no esta a la venta devuelve {"falta": organizador|evento|publicado|fase} y nada mas.';

-- ── la cartelera, por el mismo motivo ────────────────────────
-- `eventos` hacía por cada evento publicado: fase_vigente() → fase_precio
-- → disponibilidad_tipo() por tipo. Paralelizado, pero igual eran tres
-- viajes en fila por evento, más el primero. Acá es uno.
--
-- Devuelve los datos crudos y NO el "desde" ni el estado de venta: esa
-- regla (el más barato que se puede comprar AHORA, "últimas" con dos
-- umbrales) vive en la Edge Function con su explicación, y moverla acá
-- sería tener que explicarla dos veces. La base cuenta; la función decide.
--
-- El corte por fecha es "hoy en La Paz", no la medianoche UTC: a esa hora
-- en Bolivia son las 20:00 y todavía se está vendiendo en la puerta. Bolivia
-- no tiene horario de verano, así que la zona es un offset fijo y esto da
-- lo mismo que restar cuatro horas.
--
-- Dos filtros sobre el tipo y no uno, como en la Edge Function: `activo`
-- decide si se vende, `en_cartelera` si CUENTA para lo que la portada
-- dice del evento (la «Prueba de cobro» de Bs 1 está activa y no debe
-- fijar el "desde" de la fiesta ni inclinar el cupo).
create or replace function cartelera_publica() returns jsonb
  language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', e.id, 'slug', e.slug, 'nombre', e.nombre, 'lugar', e.lugar,
           'fecha', e.fecha, 'hora_inicio', e.hora_inicio, 'flyer_url', e.flyer_url,
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
     and f.fase_id is not null      -- publicado pero sin venta abierta: no es cartelera
$$;
revoke all on function cartelera_publica() from public, anon, authenticated;
grant execute on function cartelera_publica() to service_role;

comment on function cartelera_publica() is
  'Los eventos a la venta hoy (La Paz) con sus precios vivos y disponibilidad, en un jsonb y un solo viaje. La llama SOLO la Edge Function `eventos` con service_role; el "desde" y el estado de venta los decide ella.';
