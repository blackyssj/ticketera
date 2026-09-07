-- ============================================================
-- 0062 — el evento se ve con la marca del cliente
--
-- Toda página de evento sale hoy con la paleta de TICKETAZO: noche, rojo
-- y dorado cerveza. Está bien para el primer cliente, cuyo evento era
-- justamente rojo y negro, y deja de estarlo apenas entra el segundo.
--
-- El argumento de venta de la ticketera es que el comprador siente que
-- está comprando en la casa del organizador, no en un portal genérico
-- con el logo de otro arriba. Una página que se ve igual para todos es
-- exactamente lo que la competencia hace.
--
-- ── por qué dos colores y no una hoja de estilos ────────────
--
-- La tentación es dejar que cada cliente mande su CSS. Eso es dar
-- ejecución de estilos arbitrarios sobre la página que cobra: basta un
-- `position:fixed` encima del precio para que alguien compre una cosa
-- creyendo que compra otra.
--
-- Dos colores alcanzan porque la hoja ya está escrita con variables. El
-- fondo y el acento son los dos que se repiten en todo: barra, botones,
-- chips, foco. El resto de la rampa —los grises del fondo, el rojo claro
-- y el hondo— se deriva de esos dos con `color-mix`, así que una marca
-- entera se define con dos campos y no se puede romper la página.
--
-- ── por qué se validan como hexadecimal ─────────────────────
--
-- Estos valores terminan adentro de una declaración CSS. Sin el check,
-- un valor como `red; position:fixed; top:0` se convierte en dos
-- declaraciones, y la segunda no la escribimos nosotros. El regex es la
-- defensa que importa; el front escapa igual, pero una sola defensa en
-- el borde de la base es la que no se olvida.
--
-- ── el logo ─────────────────────────────────────────────────
--
-- Tercera columna, opcional. Sin logo, la página sigue armando la marca
-- con tipografía a partir del nombre (DISTRITO / FERIAL), que es lo que
-- hace hoy y se ve bien. Con logo, lo usa en la barra.
--
-- Idempotente: `add column if not exists` y el check dentro de un bloque
-- que ignora el duplicado.
-- ============================================================

alter table eventos add column if not exists color_fondo  text;
alter table eventos add column if not exists color_acento text;
alter table eventos add column if not exists logo_url     text;

do $$ begin
  alter table eventos add constraint eventos_colores_hex_check check (
    (color_fondo  is null or color_fondo  ~ '^#[0-9A-Fa-f]{6}$') and
    (color_acento is null or color_acento ~ '^#[0-9A-Fa-f]{6}$'));
exception when duplicate_object then null; end $$;

comment on column eventos.color_fondo is
  'Fondo de la pagina del evento, #RRGGBB. Null = la paleta de TICKETAZO. Validado como hexadecimal porque termina dentro de una declaracion CSS.';
comment on column eventos.color_acento is
  'Color de acento (botones, chips, foco), #RRGGBB. Null = el rojo de TICKETAZO.';
comment on column eventos.logo_url is
  'Logo del organizador para la barra. Sin el, la marca se arma con tipografia a partir del nombre.';

-- ── la funcion publica devuelve la marca ────────────────────
-- Se recrea entera y no se toca nada mas: mismas claves, tres agregadas.
-- Si alguna quedara afuera, la pagina se pinta a medias — fondo del
-- cliente con botones de TICKETAZO — que se ve peor que no pintar nada.
create or replace function evento_publico(p_org text, p_slug text) returns jsonb
  language plpgsql stable security definer set search_path = public as $function$
declare
  v_o    organizadores%rowtype;
  v_e    eventos%rowtype;
  v_fase uuid;
  v_f    evento_fase%rowtype;
  v_base jsonb;
begin
  select * into v_o from organizadores where slug = p_org and activo;
  if not found then return jsonb_build_object('falta', 'organizador'); end if;

  select * into v_e from eventos where organizador_id = v_o.id and slug = p_slug;
  if not found then return jsonb_build_object('falta', 'evento'); end if;
  if v_e.estado <> 'publicado' then return jsonb_build_object('falta', 'publicado'); end if;

  v_fase := fase_vigente(v_e.id);
  if v_fase is null then return jsonb_build_object('falta', 'fase'); end if;
  select * into v_f from evento_fase where id = v_fase;

  v_base := jsonb_build_object(
    'organizador', jsonb_build_object(
      'id', v_o.id, 'nombre', v_o.nombre, 'fee_pct', v_o.fee_pct,
      'fee_fijo_transaccion', v_o.fee_fijo_transaccion, 'fee_piso', v_o.fee_piso),
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
  return v_base;
end $function$;
revoke execute on function evento_publico(text, text) from anon, public, authenticated;

comment on function evento_publico(text, text) is
  'Todo lo que la pagina publica de un evento necesita, en una sola llamada. Incluye la marca del organizador (color_fondo, color_acento, logo_url). Solo service_role: el guardian es la Edge Function.';
