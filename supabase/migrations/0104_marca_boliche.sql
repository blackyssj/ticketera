-- ============================================================
-- 0104 — Bowie y BurTown: la marca arriba, la noche abajo
--
-- Pedido de José del 10/10, con Crush y MADNESS ya a la venta: en la
-- cartelera y en la página la tarjeta decía "CRUSH" en grande y "BOWIE"
-- chiquito como lugar. Lo que vende es el boliche — la gente va a Bowie y
-- se entera de cómo se llama la noche —, así que arriba va la MARCA del
-- organizador y abajo el nombre de la fecha. Y que todo lo que la página
-- dice de la noche salga de Plataforma Puerta, donde vive: el free cover,
-- la hora, la edad y dónde queda el boliche.
--
-- ── qué hay en este archivo ──
--   1. organizadores.titulo_marca: el título público es la marca del
--      organizador y el evento va de subtítulo. Prendido para bowie y
--      burtown. Es un dato del organizador y no un slug escrito en el
--      front: el próximo boliche que se sume se prende con un update.
--   2. eventos.free_cover y eventos.maps_url: lo que Puerta sabe de la
--      noche y del lugar y que el esquema de acá no tenía dónde guardar.
--   3. puerta_espejar_evento (la de 0103, definición viva) guarda el
--      free cover y la ubicación del club cuando Puerta los manda, sin
--      pisar lo que no venga.
--   4. la guarda del panel suma free_cover a lo que se decide en Puerta.
--   5. evento_publico y cartelera_publica (definiciones vivas) devuelven
--      la marca, el free cover, el cierre, el link del mapa, si la entrada
--      se dibuja como la de Puerta y el sello de la fase.
--   6. la huella de los espejos en blanco, para que el próximo pase los
--      reaplique con la función nueva.
--
-- Lo que Puerta manda desde v5.9 (ticketazo_eventos, plataforma/supabase/
-- migracion-v5.9.sql), además de lo de 0103. puerta-sync lo recorta a esta
-- forma antes de llamar a la base:
--     "club":   {"nombre", "lugar", "direccion", "lat", "lng", "maps_url"}
--     "listas": [{"nombre", "orden", "ingreso_hasta",           -- lista_tipos
--                 "registro_hasta_local"}]
--   ingreso_hasta         "HH:MM:SS": hasta qué hora ENTRA gratis el anotado
--                         (lo que corta la puerta en Puerta).
--   registro_hasta_local  "YYYY-MM-DD HH:MM" en hora de Bolivia: hasta
--                         cuándo uno se puede ANOTAR. Puerta la arma porque
--                         lista_tipos.registro_hasta está en UTC (MADNESS/
--                         Invitados cierra 02:00 UTC = 22:00 acá), y puede
--                         caer otro día que la noche.
-- eventos.lista_hasta de Puerta NO viene, a propósito (v5.9 lo explica):
-- nada en Puerta lo lee ni lo corta, vale siempre su default 23:00, y
-- publicarlo sería anunciar un cierre que no existe.
-- Si Puerta no manda club ni listas, todo sigue como en 0103: lugar =
-- nombre del organizador, sin dirección ni free cover.
--
-- APLICAR ANTES de redesplegar evento, eventos, orden, og y puerta-sync
-- (leen las columnas nuevas o las piden por nombre).
-- ============================================================

-- Los ALTER de abajo piden ACCESS EXCLUSIVE sobre organizadores y eventos y
-- lo tienen hasta el final (todo el archivo va en una sola transacción por
-- sql.py). Si una consulta larga tiene tomada alguna de las dos, el ALTER
-- se encola y detrás de él quedan TODAS las lecturas nuevas — la página, la
-- cartelera y crear_orden de todos los clientes, no solo de Bowie y
-- BurTown. Mejor que falle a los 5 s y se reintente: al ser una sola
-- transacción, no queda nada a medias. Mismo criterio que v5.9 de Puerta.
set local lock_timeout = '5s';

-- ── 1. el título es la marca ────────────────────────────────
alter table organizadores add column if not exists titulo_marca boolean not null default false;
comment on column organizadores.titulo_marca is
  'true = en la cartelera, la página, el título del documento y la tarjeta de WhatsApp el título grande es el nombre del organizador (BOWIE) y el nombre del evento va abajo, de subtítulo. Para clientes que venden por la marca de la casa y no por el nombre de cada noche.';

update organizadores set titulo_marca = true
 where slug in ('bowie', 'burtown') and not titulo_marca;

-- ── 2. lo que Puerta sabe de la noche y del lugar ───────────
--
-- free_cover: las listas de Puerta que son free cover ("Free Cover
-- Mujeres"), con sus dos horas: ingreso_hasta es hasta qué hora entra
-- gratis el que está en esa lista ('HH:MM') y registro_hasta hasta cuándo
-- se anota uno ('YYYY-MM-DD HH:MM', hora de Bolivia: con día, porque una
-- lista se puede cerrar el jueves para el sábado). Las dos de
-- lista_tipos, por lista; null = Puerta no tiene ese tope. Una lista por
-- elemento: [{"nombre","ingreso_hasta","registro_hasta"}]. Qué se dice con
-- eso (y si la lista ya cerró) lo decide la función `evento` al pedir la
-- página. Se guarda ya filtrado y armado — la página no tiene que saber que
-- en Puerta también hay listas de Invitados o de Compra en Puerta, que no
-- le dicen nada al que compra online.
--
-- Por qué no columnas sueltas: Puerta tiene una cantidad variable de listas
-- por noche, cada una con su hora. Y por qué no un jsonb con todo lo de
-- Puerta adentro: la página mostraría lo que haya, y un día mostraría un
-- cupo o un nombre de relacionador que alguien agregó a la respuesta.
--
-- maps_url: el link de Google Maps del boliche. La página ya sabe dibujar
-- el mapa con lat/lng; el link sirve cuando Puerta tiene el lugar cargado
-- como link compartido (maps.app.goo.gl/…, que no trae coordenadas
-- adentro) para el botón "Cómo llegar". Solo https: el front lo pone en
-- un href, y un javascript: ahí es un script en nuestro dominio. Qué
-- dominios valen lo decide puerta_maps(); el CHECK es la red de abajo.
alter table eventos add column if not exists free_cover jsonb
  constraint eventos_free_cover_check
  check (free_cover is null or jsonb_typeof(free_cover) = 'array');
alter table eventos add column if not exists maps_url text
  constraint eventos_maps_url_check
  check (maps_url is null or (maps_url ~ '^https://' and length(maps_url) <= 500));

comment on column eventos.free_cover is
  'Espejos de Plataforma Puerta (0104): las listas free cover de la noche, [{"nombre","ingreso_hasta","registro_hasta"}]: ingreso_hasta HH:MM (hasta qué hora entra gratis), registro_hasta YYYY-MM-DD HH:MM en hora de Bolivia (hasta cuándo se anota), o null. Lo escribe puerta_espejar_evento; el panel no lo cambia (puerta_guarda).';
comment on column eventos.maps_url is
  'Link https de Google Maps del lugar, para "Cómo llegar" cuando no hay lat/lng. Hoy lo llena el espejo de Puerta con el del club.';

-- ── 3. del JSON de Puerta, sin reventar ─────────────────────
--
-- Un dato raro en el club o en una lista (una hora '25:99', una latitud
-- 'abc') NO puede tirar abajo el espejo del evento: puerta_aplicar_eventos
-- atrapa la excepción, pero el evento entero queda sin actualizar — precio
-- y horario incluidos — hasta que alguien corrija el dato en Puerta. Estas
-- devuelven null en vez de fallar, y null es "no vino".

-- '23:00:00' → '23:00'.
create or replace function puerta_hora(p text) returns text
  language plpgsql immutable set search_path = public as $$
begin
  return to_char(nullif(btrim(p), '')::time, 'HH24:MI');
exception when others then
  return null;
end $$;
revoke execute on function puerta_hora(text) from public, anon, authenticated;

-- '2026-10-10 22:00' (hora de Bolivia, como la arma Puerta) → igual, o null.
-- Con zona ('…+00', '…Z') NO se acepta: un ::timestamp tira la zona en
-- silencio y la hora UTC cruda saldría publicada como si fuera de acá —
-- "en lista hasta las 02:00" para una lista que cierra a las 22:00. La
-- cruda, si alguna vez viene sola, la pasa a hora de Bolivia puerta-sync.
create or replace function puerta_momento(p text) returns text
  language plpgsql immutable set search_path = public as $$
begin
  if btrim(p) !~ '^\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}(:\d{2}(\.\d+)?)?$' then
    return null;
  end if;
  return to_char(btrim(p)::timestamp, 'YYYY-MM-DD HH24:MI');
exception when others then
  return null;
end $$;
revoke execute on function puerta_momento(text) from public, anon, authenticated;

create or replace function puerta_numero(p text) returns numeric
  language plpgsql immutable set search_path = public as $$
begin
  return nullif(btrim(p), '')::numeric;
exception when others then
  return null;
end $$;
revoke execute on function puerta_numero(text) from public, anon, authenticated;

-- El link del mapa, solo si es de Google Maps y https. Mismo criterio que
-- puerta_url para las imágenes: lo carga el personal del boliche en Puerta,
-- no gente de TICKETAZO, y termina en un href de ticketazo.com.bo. Un link a
-- cualquier lado ahí es un botón "Cómo llegar" que manda a otra parte.
create or replace function puerta_maps(p text) returns text
  language sql immutable set search_path = public as $$
  select case
    when length(u) <= 500
     and u ~* '^https://((www\.)?google\.[a-z]{2,3}(\.[a-z]{2})?/maps|maps\.google\.[a-z]{2,3}(\.[a-z]{2})?/|maps\.app\.goo\.gl/|goo\.gl/maps/)[a-z0-9._~%/?#&=+,;:@!$()*-]*$'
    then u end
    from (select btrim(p) as u) s
$$;
revoke execute on function puerta_maps(text) from public, anon, authenticated;

-- ── 4. el espejo, con el club y las listas ──────────────────
--
-- La de 0103 (definición viva, sin cambios en lo que ya hacía) más:
--
-- Ubicación: lugar, dirección, punto y link del club de Puerta. Se pisan
-- con la misma regla que el flyer: solo si en Puerta CAMBIARON desde la
-- última vez que se aplicó y no vinieron vacíos. El panel puede corregir
-- el lugar y el mapa de una fecha (la guarda lo deja), y con `vendidas` en
-- la huella el evento se reaplica con cada venta de los relacionadores: sin
-- esta regla, la corrección del panel duraría un minuto. Lo que Puerta no
-- manda no borra nada — si nunca cargaron la dirección del club, queda lo
-- de hoy: lugar = nombre del organizador.
--
-- Free cover: es de Puerta y se reemplaza entero cada vez que viene la
-- lista (vacía también: si allá sacaron el free cover, acá no se sigue
-- anunciando). Si `listas` no viene —un Puerta sin v5.9— no se toca.
-- Las que cuentan son las que dicen "free" en el nombre, sin distinguir
-- mayúsculas: así las nombra Bowie ("Free Cover Mujeres") y no hay otro
-- dato en lista_tipos que diga que una lista entra gratis.
create or replace function puerta_espejar_evento(p jsonb, p_forzar boolean default false)
returns text language plpgsql security definer set search_path = public as $$
declare
  v_cfg     puerta_config;
  v_org     organizadores;
  v_pe      puerta_evento;
  v_existe  boolean;
  v_id      uuid;
  v_club    text := p->>'club_id';
  v_fecha   date;
  v_hash    text;
  v_estado  text;
  v_corte   timestamptz;
  v_vdesde  timestamptz := nullif(p->>'manilla_desde', '')::timestamptz;
  v_tipo    uuid;
  v_online  uuid;
  v_fases   boolean;
  v_base    int;
  v_f       jsonb;
  v_i       int;
  v_fid     uuid;
  v_fdesde  timestamptz;
  v_fhasta  timestamptz;
  v_precio  numeric;
  v_cupo    int;
  v_quedan  int;
  v_factivo boolean;
  v_ids     uuid[] := '{}';
  v_pagadas int;
  v_en_cola int;
  v_reordenar  boolean;
  v_sin_precio boolean := false;
  v_sync    text := coalesce(current_setting('ticketazo.puerta_sync', true), '');
  -- 0104: el club (dónde queda) y las listas (el free cover)
  v_c       jsonb := case when jsonb_typeof(p->'club') = 'object' then p->'club' else '{}'::jsonb end;
  v_c_ant   jsonb;
  v_lugar   text;
  v_dir     text;
  v_lat     numeric;
  v_lng     numeric;
  v_maps    text;
  v_listas  boolean := jsonb_typeof(p->'listas') = 'array';
  v_free    jsonb;
begin
  if coalesce(p->>'id', '') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
     or coalesce(btrim(p->>'nombre'), '') = '' or nullif(p->>'fecha', '') is null then
    return 'ignorado:datos_incompletos';
  end if;
  v_id := (p->>'id')::uuid;
  v_fecha := (p->>'fecha')::date;

  -- La huella, con las fases ordenadas por id: si Puerta las mandara en
  -- otro orden la huella cambiaría sola y el evento se reaplicaría cada
  -- minuto sin que nada haya cambiado.
  v_hash := md5(((p - 'fases') || jsonb_build_object('fases', coalesce((
              select jsonb_agg(x order by x->>'id')
                from jsonb_array_elements(case when jsonb_typeof(p->'fases') = 'array'
                                               then p->'fases' else '[]'::jsonb end) x),
              '[]'::jsonb)))::text);

  select * into v_cfg from puerta_config where id;
  -- Las dos defensas de la fecha de corte también acá, no solo en Puerta:
  -- si Puerta manda de más, las noches anteriores igual no se espejan.
  if v_club is null or not (v_club = any (v_cfg.clubs)) then return 'ignorado:club'; end if;
  if v_fecha < v_cfg.desde then return 'ignorado:antes_del_corte'; end if;

  select * into v_org from organizadores where slug = v_club;
  if not found then return 'ignorado:sin_organizador'; end if;

  select * into v_pe from puerta_evento where evento_id = v_id;
  v_existe := found;
  if v_existe and v_pe.hash = v_hash and not coalesce(p_forzar, false) then
    update puerta_evento set visto_at = clock_timestamp() where evento_id = v_id;
    return 'igual';
  end if;
  if not v_existe and exists (select 1 from eventos where id = v_id) then
    return 'ignorado:id_ocupado';           -- un uuid que acá ya es otra cosa
  end if;
  if v_existe and v_pe.organizador_id <> v_org.id then
    return 'ignorado:cambio_de_club';       -- no se muda un evento con ventas entre clientes
  end if;

  -- De acá en adelante se escribe lo espejado: se prende el permiso (ver
  -- puerta_sync_activo) y se deja como estaba antes del return del final.
  -- Si algo revienta en el medio, el rollback lo devuelve solo.
  perform set_config('ticketazo.puerta_sync', 'on', true);

  v_estado := case when p->>'estado' = 'cerrado' then 'cerrado' else 'publicado' end;
  v_corte  := puerta_corte(p);
  v_fases  := coalesce((p->>'venta_por_fases')::boolean, false)
              and jsonb_typeof(p->'fases') = 'array'
              and jsonb_array_length(p->'fases') > 0;

  -- ── el club y las listas (0104) ──
  -- v_c_ant es el club que mandó Puerta la vez anterior: contra eso se
  -- decide si la ubicación cambió allá (ver más abajo). Sin espejo previo
  -- es '{}' y no importa: el evento se crea con lo que venga.
  v_c_ant := case when jsonb_typeof(v_pe.datos->'club') = 'object'
                  then v_pe.datos->'club' else '{}'::jsonb end;
  v_lugar := nullif(btrim(left(v_c->>'lugar', 120)), '');
  v_dir   := nullif(btrim(left(v_c->>'direccion', 240)), '');
  v_lat   := puerta_numero(v_c->>'lat');
  v_lng   := puerta_numero(v_c->>'lng');
  -- El punto va completo o no va (eventos_punto_completo_check), y el 0,0
  -- es un campo sin cargar, no un boliche en el golfo de Guinea.
  if v_lat is null or v_lng is null or abs(v_lat) > 90 or abs(v_lng) > 180
     or (v_lat = 0 and v_lng = 0) then
    v_lat := null; v_lng := null;
  end if;
  v_maps := puerta_maps(v_c->>'maps_url');
  if v_listas then
    -- A lo sumo seis: es un renglón por lista en el afiche de la página.
    -- Las dos horas, de cada lista (v5.9): eventos.lista_hasta de Puerta no
    -- viene y no se lee aunque viniera — no corta nada allá.
    select jsonb_agg(jsonb_build_object(
             'nombre', x.nombre, 'ingreso_hasta', x.ingreso_hasta,
             'registro_hasta', x.registro_hasta)
           order by x.orden, x.n)
      into v_free
      from (select left(btrim(l->>'nombre'), 60) as nombre,
                   puerta_hora(l->>'ingreso_hasta') as ingreso_hasta,
                   puerta_momento(l->>'registro_hasta_local') as registro_hasta,
                   coalesce(puerta_numero(l->>'orden'), 0) as orden, n
              from jsonb_array_elements(p->'listas') with ordinality as a(l, n)
             where jsonb_typeof(l) = 'object'
               and coalesce(btrim(l->>'nombre'), '') ~* 'free'
             order by 4, n
             limit 6) x;
  end if;

  -- ── el evento ──
  if not v_existe then
    insert into eventos (id, organizador_id, slug, nombre, lugar, direccion, lat, lng,
                         maps_url, free_cover, flyer_url, fecha,
                         hora_inicio, hora_fin, edad_min, estado, arte_url,
                         comision_entrada, listado, rrpp_por_defecto)
    values (v_id, v_org.id, puerta_slug(v_org.id, p->>'nombre', v_fecha, v_id),
            btrim(p->>'nombre'), coalesce(v_lugar, v_org.nombre), v_dir, v_lat, v_lng,
            v_maps, v_free, puerta_url(p->>'flyer_url'), v_fecha,
            coalesce(nullif(p->>'hora_inicio', '')::time, '21:00'),
            coalesce(nullif(p->>'hora_fin', '')::time, '06:00'),
            coalesce(nullif(p->>'edad_min', '')::int, 18),
            v_estado, puerta_url(p->>'ticket_url'), 0, true, null);
    insert into puerta_evento (evento_id, organizador_id, club)
    values (v_id, v_org.id, v_club);
  else
    -- Flyer y arte: el panel los puede cambiar. Se pisan solo si en Puerta
    -- CAMBIARON desde la última vez y no quedaron vacíos; si no, el flyer
    -- que alguien subió acá se perdería cada vez que Puerta cambia la hora.
    -- La ubicación del club (0104), con la misma regla y por lo mismo. El
    -- free cover no: es de Puerta (la guarda no deja tocarlo acá) y se
    -- reemplaza entero cada vez que viene la lista.
    update eventos e set
      nombre      = btrim(p->>'nombre'),
      fecha       = v_fecha,
      hora_inicio = coalesce(nullif(p->>'hora_inicio', '')::time, '21:00'),
      hora_fin    = coalesce(nullif(p->>'hora_fin', '')::time, '06:00'),
      edad_min    = coalesce(nullif(p->>'edad_min', '')::int, 18),
      estado      = v_estado,
      comision_entrada = 0,
      listado     = true,
      rrpp_por_defecto = null,
      flyer_url   = case when puerta_url(p->>'flyer_url') is not null
                          and puerta_url(p->>'flyer_url')
                              is distinct from puerta_url(v_pe.datos->>'flyer_url')
                         then puerta_url(p->>'flyer_url') else e.flyer_url end,
      arte_url    = case when puerta_url(p->>'ticket_url') is not null
                          and puerta_url(p->>'ticket_url')
                              is distinct from puerta_url(v_pe.datos->>'ticket_url')
                         then puerta_url(p->>'ticket_url') else e.arte_url end,
      lugar       = case when v_lugar is not null
                          and (v_c->'lugar') is distinct from (v_c_ant->'lugar')
                         then v_lugar else e.lugar end,
      direccion   = case when v_dir is not null
                          and (v_c->'direccion') is distinct from (v_c_ant->'direccion')
                         then v_dir else e.direccion end,
      lat         = case when v_lat is not null
                          and (v_c->'lat', v_c->'lng') is distinct from (v_c_ant->'lat', v_c_ant->'lng')
                         then v_lat else e.lat end,
      lng         = case when v_lat is not null
                          and (v_c->'lat', v_c->'lng') is distinct from (v_c_ant->'lat', v_c_ant->'lng')
                         then v_lng else e.lng end,
      maps_url    = case when v_maps is not null
                          and (v_c->'maps_url') is distinct from (v_c_ant->'maps_url')
                         then v_maps else e.maps_url end,
      free_cover  = case when v_listas then v_free else e.free_cover end
     where e.id = v_id;
  end if;

  -- ── el tipo: uno solo, General, una manilla ──
  select t.id into v_tipo from tipo_entrada t where t.id = v_pe.tipo_id and t.evento_id = v_id;
  if v_tipo is null then
    select t.id into v_tipo from tipo_entrada t where t.evento_id = v_id and t.nombre = 'General';
  end if;
  if v_tipo is null then
    insert into tipo_entrada (organizador_id, evento_id, nombre, manillas, orden, activo,
                              categoria, en_cartelera)
    values (v_org.id, v_id, 'General', 1, 0, true, 'entrada', true)
    returning id into v_tipo;
  else
    update tipo_entrada set manillas = 1, activo = true, categoria = 'entrada', en_cartelera = true
     where id = v_tipo
       and (manillas, activo, categoria, en_cartelera) is distinct from (1, true, 'entrada', true);
  end if;

  -- ── las fases ──
  -- Primero, sin escribir nada, cuáles quedan activas y en qué lugar: con
  -- fases, las de Puerta en su orden (1..n, la posición en v_ids); sin
  -- fases, la Online en 0. Todo lo demás va desactivado de 1000 para arriba.
  if v_fases then
    for v_f in
      select x from jsonb_array_elements(p->'fases') with ordinality as a(x, n)
       order by coalesce(nullif(x->>'orden', '')::int, 0), n
    loop
      if coalesce(v_f->>'id', '') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
        continue;
      end if;
      v_fid := (v_f->>'id')::uuid;
      if v_fid = any (v_ids)
         or exists (select 1 from evento_fase where id = v_fid and evento_id <> v_id) then
        continue;                           -- repetida, o ese uuid acá es de otro evento
      end if;
      v_ids := v_ids || v_fid;
    end loop;
  else
    v_online := coalesce((select f.id from evento_fase f
                           where f.id = v_pe.fase_online and f.evento_id = v_id),
                         gen_random_uuid());
    v_ids := array[v_online];
  end if;

  -- `orden` es único por evento y la restricción no es diferible: se
  -- chequea fila por fila. Si alguna fase tiene que cambiar de lugar, todas
  -- se estacionan primero por encima de cualquier número en uso y recién
  -- después cada una va al suyo. Pero solo si hace falta: escribir `orden`
  -- (columna de un índice único) pide el candado fuerte de la fila, el que
  -- choca con el de la FK de orden_items, y crear_orden toma los candados al
  -- revés (primero fase_precio, después la fase). Con `vendidas` la huella
  -- cambia con cada venta de Puerta y el evento se reaplica seguido: si cada
  -- vez se tocara `orden`, una compra y el sync se trabarían entre sí
  -- (probado: deadlock). Por eso `orden` tampoco va en el SET de los
  -- upsert de abajo: en un ON CONFLICT DO UPDATE el candado se decide por
  -- las columnas que nombra el SET, aunque el valor no cambie. Cuando sí hay
  -- que reordenar (Puerta agregó o movió una fase), primero se toman los
  -- precios del evento, en el mismo orden que crear_orden, y `orden` se
  -- escribe aparte.
  select exists (
    select 1 from evento_fase f
     where f.evento_id = v_id
       and case when f.id = any (v_ids)
                then f.orden is distinct from
                     case when v_fases then array_position(v_ids, f.id) else 0 end
                else f.orden < 1000 end)
    into v_reordenar;
  if v_reordenar then
    perform 1 from fase_precio fp join evento_fase f on f.id = fp.fase_id
     where f.evento_id = v_id
     order by fp.fase_id, fp.tipo_id
       for update of fp;
    select 1000000 + coalesce(max(abs(orden)), 0) into v_base from evento_fase where evento_id = v_id;
    update evento_fase f set orden = v_base + s.rn
      from (select id, row_number() over (order by orden, id) as rn
              from evento_fase where evento_id = v_id) s
     where f.id = s.id;
  end if;

  if v_fases then
    for v_f in
      select x from jsonb_array_elements(p->'fases') with ordinality as a(x, n)
       order by coalesce(nullif(x->>'orden', '')::int, 0), n
    loop
      if coalesce(v_f->>'id', '') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
        continue;
      end if;
      v_fid := (v_f->>'id')::uuid;
      v_i := array_position(v_ids, v_fid);
      if v_i is null then continue; end if;
      -- La ventana de prepagadas del evento manda también sobre las fases:
      -- en Puerta ningún relacionador vende fuera de ella, haya fases o no.
      v_fhasta := least(coalesce(nullif(v_f->>'hasta', '')::timestamptz, v_corte), v_corte);
      v_fdesde := greatest(nullif(v_f->>'desde', '')::timestamptz, v_vdesde);
      if v_fdesde >= v_fhasta then v_fdesde := null; end if;
      v_factivo := coalesce(nullif(v_f->>'activo', '')::boolean, true);

      v_precio := nullif(v_f->>'precio', '')::numeric;
      if v_precio is null or v_precio <= 0 then
        v_precio := 0; v_factivo := false; v_sin_precio := true;
      end if;

      if v_f ? 'quedan' or (v_f ? 'vendidas' and nullif(v_f->>'cupo', '') is not null) then
        v_quedan := case when v_f ? 'quedan' then nullif(v_f->>'quedan', '')::int
                         else (v_f->>'cupo')::int
                              - coalesce(nullif(v_f->>'vendidas', '')::int, 0) end;
        if v_quedan is null then
          v_cupo := null;                   -- 'quedan' vacío: allá no tiene tope
        else
          select coalesce(sum(i.cantidad), 0) into v_pagadas
            from orden_items i join ordenes o on o.id = i.orden_id
           where i.fase_id = v_fid and o.estado = 'pagada';
          select count(*) into v_en_cola
            from puerta_envio s join entradas e on e.id = s.entrada_id
           where s.evento_id = v_id and s.tipo = 'entrada'
             and s.estado in ('pendiente', 'tomado') and e.fase_id = v_fid;
          v_cupo := v_pagadas + greatest(v_quedan - v_en_cola, 0);
        end if;
      else
        v_cupo := nullif(v_f->>'cupo', '')::int;
      end if;
      -- cupo 0 no existe (check > 0): una fase sin nada para vender acá
      -- se apaga, que para fase_vigente es lo mismo que agotada.
      if v_cupo is not null and v_cupo < 1 then v_cupo := null; v_factivo := false; end if;

      insert into evento_fase (id, organizador_id, evento_id, nombre, desde, hasta,
                               arte_url, orden, activo)
      values (v_fid, v_org.id, v_id, coalesce(nullif(btrim(v_f->>'nombre'), ''), 'Fase ' || v_i),
              v_fdesde, v_fhasta, puerta_url(v_f->>'ticket_url'), v_i, v_factivo)
      on conflict (id) do update set
        nombre = excluded.nombre, desde = excluded.desde, hasta = excluded.hasta,
        activo = excluded.activo,
        arte_url = coalesce(excluded.arte_url, evento_fase.arte_url);
      if v_reordenar then
        update evento_fase set orden = v_i where id = v_fid and orden is distinct from v_i;
      end if;

      insert into fase_precio (organizador_id, fase_id, tipo_id, precio, cupo)
      values (v_org.id, v_fid, v_tipo, v_precio, v_cupo)
      on conflict (fase_id, tipo_id) do update set precio = excluded.precio, cupo = excluded.cupo;
    end loop;
    v_online := v_pe.fase_online;           -- si existía, queda desactivada abajo
  else
    v_fhasta := v_corte;
    v_fdesde := case when v_vdesde < v_fhasta then v_vdesde end;
    v_precio := nullif(p->>'precio_manilla', '')::numeric;
    v_factivo := true;
    if v_precio is null or v_precio <= 0 then
      v_precio := 0; v_factivo := false; v_sin_precio := true;
    end if;
    insert into evento_fase (id, organizador_id, evento_id, nombre, desde, hasta, orden, activo)
    values (v_online, v_org.id, v_id, 'Online', v_fdesde, v_fhasta, 0, v_factivo)
    on conflict (id) do update set
      nombre = 'Online', desde = excluded.desde, hasta = excluded.hasta,
      activo = excluded.activo;
    if v_reordenar then
      update evento_fase set orden = 0 where id = v_online and orden is distinct from 0;
    end if;
    insert into fase_precio (organizador_id, fase_id, tipo_id, precio, cupo)
    values (v_org.id, v_online, v_tipo, v_precio, null)
    on conflict (fase_id, tipo_id) do update set precio = excluded.precio, cupo = null;
  end if;

  -- Lo que no vino en esta versión: desactivado y de 1000 para arriba. Si no
  -- hubo que reordenar, ya está ahí (es lo que se chequeó arriba): solo se
  -- apaga, sin tocar `orden`.
  if v_reordenar then
    update evento_fase f set activo = false, orden = 1000 + s.rn
      from (select id, row_number() over (order by orden, id) as rn
              from evento_fase where evento_id = v_id and not (id = any (v_ids))) s
     where f.id = s.id;
  else
    update evento_fase set activo = false
     where evento_id = v_id and not (id = any (v_ids)) and activo;
  end if;

  update puerta_evento set
    tipo_id        = v_tipo,
    fase_online    = case when v_fases then fase_online else v_online end,
    hash           = v_hash,
    datos          = p,
    cierre         = case when v_estado = 'cerrado' then 'puerta' end,
    visto_at       = clock_timestamp(),
    actualizado_at = clock_timestamp()
   where evento_id = v_id;

  perform set_config('ticketazo.puerta_sync', v_sync, true);
  return case when v_existe then 'actualizado' else 'creado' end
         || case when v_sin_precio then ':sin_precio' else '' end;
end $$;
revoke execute on function puerta_espejar_evento(jsonb, boolean) from public, anon, authenticated;
grant execute on function puerta_espejar_evento(jsonb, boolean) to service_role;

-- ── 5. la guarda del panel ──────────────────────────────────
--
-- La de 0103 (definición viva) con free_cover entre lo que se decide en
-- Puerta. Un free cover cambiado en el panel se anunciaría en la página y
-- en la puerta de Bowie no existiría: la chica que llega a las 23:30 por
-- un "hasta las 00:00" que inventamos acá paga la entrada. La ubicación
-- (lugar, dirección, punto, link) se sigue pudiendo corregir acá.
create or replace function puerta_guarda() returns trigger
  language plpgsql security definer set search_path = public as $$
declare v_evento uuid; v_fase uuid; v_msg text :=
  'Este evento viene de Plataforma Puerta: nombre, fecha, horario, precios y fases se cambian allá y se copian solos. Acá podés cambiar el flyer, la descripción y el arte.';
begin
  if puerta_sync_activo() then
    return coalesce(new, old);
  end if;

  if tg_table_name = 'eventos' then
    if not evento_espejo(old.id) then return coalesce(new, old); end if;
    if tg_op = 'DELETE' then
      raise exception 'ESPEJO_PUERTA: %', v_msg;
    end if;
    if (new.id, new.organizador_id, new.slug, new.nombre, new.fecha, new.hora_inicio,
        new.hora_fin, new.edad_min, new.estado, new.comision_entrada,
        new.rrpp_por_defecto, new.listado, new.free_cover)
       is distinct from
       (old.id, old.organizador_id, old.slug, old.nombre, old.fecha, old.hora_inicio,
        old.hora_fin, old.edad_min, old.estado, old.comision_entrada,
        old.rrpp_por_defecto, old.listado, old.free_cover) then
      raise exception 'ESPEJO_PUERTA: %', v_msg;
    end if;
    return new;

  elsif tg_table_name = 'evento_fase' then
    if not (evento_espejo(case when tg_op = 'INSERT' then new.evento_id else old.evento_id end)
            or (tg_op = 'UPDATE' and evento_espejo(new.evento_id))) then
      return coalesce(new, old);
    end if;
    if tg_op = 'UPDATE'
       and (new.id, new.organizador_id, new.evento_id, new.nombre, new.desde, new.hasta,
            new.orden, new.activo)
           is not distinct from
           (old.id, old.organizador_id, old.evento_id, old.nombre, old.desde, old.hasta,
            old.orden, old.activo) then
      return new;   -- solo cambió el arte de la fase
    end if;
    raise exception 'ESPEJO_PUERTA: %', v_msg;

  elsif tg_table_name = 'fase_precio' then
    v_fase := case when tg_op = 'INSERT' then new.fase_id else old.fase_id end;
    select evento_id into v_evento from evento_fase where id = v_fase;
    if not evento_espejo(v_evento) then
      if tg_op = 'UPDATE' and new.fase_id is distinct from old.fase_id then
        select evento_id into v_evento from evento_fase where id = new.fase_id;
        if not evento_espejo(v_evento) then return new; end if;
      else
        return coalesce(new, old);
      end if;
    end if;
    raise exception 'ESPEJO_PUERTA: %', v_msg;

  elsif tg_table_name = 'tipo_entrada' then
    if not (evento_espejo(case when tg_op = 'INSERT' then new.evento_id else old.evento_id end)
            or (tg_op = 'UPDATE' and evento_espejo(new.evento_id))) then
      return coalesce(new, old);
    end if;
    if tg_op = 'UPDATE'
       and (new.id, new.organizador_id, new.evento_id, new.nombre, new.manillas, new.orden,
            new.activo, new.categoria, new.en_cartelera)
           is not distinct from
           (old.id, old.organizador_id, old.evento_id, old.nombre, old.manillas, old.orden,
            old.activo, old.categoria, old.en_cartelera) then
      return new;   -- solo descripción / incluye
    end if;
    raise exception 'ESPEJO_PUERTA: %', v_msg;

  elsif tg_table_name = 'mesas' then
    -- Las mesas de Bowie y BurTown se venden en Puerta (fuera de esto).
    -- También el UPDATE que la muda de evento: la policy de mesas solo mira
    -- el organizador de la MESA, no el del evento, así que un admin de otro
    -- cliente podía colgar una mesa suya de una fecha de Bowie (el uuid es
    -- público, va en el QR). La entrada de esa mesa no viaja a Puerta
    -- (puerta_encolar_orden deja afuera las mesas) y rebotaría en la fila.
    if evento_espejo(new.evento_id)
       and (tg_op = 'INSERT' or new.evento_id is distinct from old.evento_id) then
      raise exception 'ESPEJO_PUERTA: las mesas de este evento se venden en Plataforma Puerta.';
    end if;
    return coalesce(new, old);

  elsif tg_table_name = 'entradas' then
    if not evento_espejo(new.evento_id) then return new; end if;
    if tg_op = 'INSERT' and new.orden_id is null then
      raise exception 'ESPEJO_PUERTA: las cortesías de este evento se dan en Plataforma Puerta. Una cortesía emitida acá no existiría allá y rebotaría en la puerta.';
    end if;
    if tg_op = 'UPDATE' and new.estado is distinct from old.estado and new.estado <> 'anulada' then
      raise exception 'ESPEJO_PUERTA: el ingreso de este evento se marca con el escáner de Plataforma Puerta, no con esta puerta.';
    end if;
    return new;
  end if;

  return coalesce(new, old);
end $$;
revoke execute on function puerta_guarda() from public, anon, authenticated;

-- ── 6. la página y la cartelera ─────────────────────────────
--
-- evento_publico: la de 0102 (definición viva) más
--   · organizador.titulo_marca.
--   · evento.hora_fin y free_cover: la página arma "Puertas 21:00 a 06:00"
--     y el renglón del free cover. hora_fin se manda siempre pero la
--     función `evento` lo usa solo en espejos: en el resto el default
--     06:00 nunca lo eligió nadie.
--   · evento.maps_url, para "Cómo llegar".
--   · evento.entrada_puerta: el evento es espejo y la entrada se dibuja
--     IGUAL que la de Plataforma Puerta (ticket.js). La entrada va a
--     parar al mismo escáner y a los mismos chats que las que genera el
--     relacionador: si se viera distinta, en la fila sería "la de
--     internet" y alguien la discutiría. Sale del espejo y no de
--     titulo_marca: una fecha que no viene de Puerta no tiene por qué
--     parecerse a Puerta.
--   · fase.sello: el nombre de la fase que Puerta imprime en la entrada
--     (marcaFase en app.js de Puerta). Solo en espejos que venden por
--     fases: la fase 'Online' la inventa 0103 cuando Puerta vende a precio
--     único, allá no existe y allá esa entrada no lleva sello.
create or replace function evento_publico(p_org text, p_slug text) returns jsonb
  language plpgsql stable security definer set search_path = public as $function$
declare
  v_o organizadores%rowtype; v_e eventos%rowtype;
  v_fase uuid; v_f evento_fase%rowtype; v_pe puerta_evento%rowtype;
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
  select * into v_pe from puerta_evento where evento_id = v_e.id;

  return jsonb_build_object(
    'organizador', jsonb_build_object(
      'id', v_o.id, 'nombre', v_o.nombre, 'fee_pct', v_o.fee_pct,
      'fee_fijo_transaccion', v_o.fee_fijo_transaccion, 'fee_piso', v_o.fee_piso,
      'comision_modo', v_o.comision_modo,
      'muestra_cupo', v_o.muestra_cupo,
      'instagram', v_o.instagram,
      'titulo_marca', v_o.titulo_marca,
      'fechas', (select count(*) from eventos x
                  where x.organizador_id = v_o.id
                    and x.estado = 'publicado'
                    and x.listado
                    and x.fecha >= (now() at time zone 'America/La_Paz')::date
                    and fase_vigente(x.id) is not null)),
    'evento', jsonb_build_object(
      'id', v_e.id, 'nombre', v_e.nombre, 'descripcion', v_e.descripcion,
      'lugar', v_e.lugar, 'direccion', v_e.direccion, 'lat', v_e.lat, 'lng', v_e.lng,
      'maps_url', v_e.maps_url,
      'fecha', v_e.fecha, 'hora_inicio', v_e.hora_inicio, 'hora_fin', v_e.hora_fin,
      'edad_min', v_e.edad_min, 'estado', v_e.estado, 'listado', v_e.listado,
      'free_cover', v_e.free_cover,
      'entrada_puerta', v_pe.evento_id is not null,
      'tope_entradas_orden', v_e.tope_entradas_orden, 'arte_url', v_e.arte_url,
      'color_fondo', v_e.color_fondo, 'color_acento', v_e.color_acento,
      'logo_url', v_e.logo_url, 'flyer_url', v_e.flyer_url),
    'fase', jsonb_build_object(
      'id', v_f.id, 'nombre', v_f.nombre, 'hasta', v_f.hasta, 'arte_url', v_f.arte_url,
      'sello', case when v_pe.evento_id is not null and v_f.id is not null
                     and v_f.id is distinct from v_pe.fase_online
                    then v_f.nombre end),
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
revoke execute on function evento_publico(text, text) from public, anon, authenticated;
grant execute on function evento_publico(text, text) to service_role;

-- cartelera_publica: la viva, con titulo_marca en el organizador. La
-- tarjeta arma "BOWIE / Crush" con eso; nada más cambia.
create or replace function cartelera_publica() returns jsonb
  language sql stable security definer set search_path = public as $function$
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', e.id, 'slug', e.slug, 'nombre', e.nombre, 'lugar', e.lugar,
           'fecha', e.fecha, 'hora_inicio', e.hora_inicio, 'flyer_url', e.flyer_url,
           'color_fondo', e.color_fondo, 'color_acento', e.color_acento,
           'organizadores', jsonb_build_object('slug', o.slug, 'nombre', o.nombre,
                                               'muestra_cupo', o.muestra_cupo,
                                               'titulo_marca', o.titulo_marca),
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
$function$;
revoke execute on function cartelera_publica() from public, anon, authenticated;
grant execute on function cartelera_publica() to service_role;

-- ── 7. que el próximo pase traiga lo nuevo ──────────────────
--
-- Puerta se despliega primero. Si cuando esto se aplica ya manda el club y
-- las listas, la huella guardada de Crush y MADNESS ya es la de esa
-- versión: el sync contestaría 'igual' y la función nueva no los vería
-- nunca (hasta el próximo cambio en Puerta). Sin huella, se reaplican en la
-- próxima corrida, al minuto.
--
-- Y se olvida el club que vio la función vieja: la ubicación se pisa solo
-- si CAMBIÓ desde la última vez, y ese club nunca se aplicó. Sin esto, un
-- club que llegó antes de 0104 quedaría para siempre como "ya visto".
update puerta_evento set hash = null, datos = datos - 'club';

-- ── control ─────────────────────────────────────────────────
select * from chequeo_funciones_sin_guardia();   -- tiene que devolver vacío
