-- ============================================================
-- 0103 — Bowie y BurTown: las fechas de Plataforma Puerta, a la venta acá
--
-- José es dueño de los dos sistemas. Cuando en Puerta se publica una fecha
-- de Bowie o de BurTown, TICKETAZO la crea sola, publicada y en la
-- cartelera, al MISMO precio de Puerta y sin cargo nuestro. Cada entrada que
-- se paga acá se crea allá a nombre del relacionador "josemenacho2", como
-- cualquier prepagada: comisión normal, rinde precio menos comisión y se
-- escanea con el escáner de Puerta. La puerta es la de Puerta; la nuestra no
-- toca estas fechas.
--
-- ── por qué el MISMO uuid de evento ──
-- El QR de nuestra entrada dice `EVT:<evento>:<code>` y el escáner de Puerta
-- compara ese <evento> contra el id de la noche que tiene abierta. Con un id
-- propio, la entrada rebotaba como "Este QR es de otro evento" aunque el
-- code existiera allá. Mismo id y el escáner de Puerta no se entera de que
-- la entrada vino de afuera, que es lo que se pidió: cero cambios en app.js.
--
-- ── qué hay en este archivo ──
--   · organizadores `bowie` y `burtown`, sin cargo (el comprador paga el
--     precio de Puerta, ni un peso más).
--   · puerta_config: desde cuándo se espeja, el interruptor y cuánto
--     esperar a que el filtro de Seguridad de Puerta se confirme.
--   · puerta_evento: qué evento de acá es espejo de cuál de allá, y la
--     huella de la última versión para no reescribir cada minuto.
--   · puerta_envio: la cola de lo que hay que contarle a Puerta (entradas
--     nuevas, anulaciones del panel y las del filtro de Seguridad), con
--     reintentos y reenvío forzado si Puerta cambió el precio en el medio.
--   · las funciones que usa la Edge Function `puerta-sync` (solo
--     service_role) y los triggers que llenan la cola y cuidan el espejo.
--   · padrón y validación de NUESTRA puerta: devuelven vacío/aviso para
--     estas fechas en vez de romper.
--   · el cron que llama a puerta-sync cada minuto.
--
-- APLICAR ANTES de desplegar puerta-sync (llama a estas funciones) y antes
-- de redesplegar estado-orden, barrer-pagos y crear-orden (leen la cola).
-- ============================================================

-- ── 1. los dos organizadores ────────────────────────────────
--
-- Todos los valores explícitos, aunque coincidan con el default: un default
-- que alguien cambie mañana no puede cambiar lo que le cobramos al
-- comprador de Bowie.
--   · fee 0 / fijo 0 / piso 0 / 'sobre': total = precio de Puerta. Con
--     'sobre' y todo en cero crear_orden da fee 0 por construcción.
--   · comercio 1521: el mismo de los clientes actuales. La plata la cobra
--     TICKETAZO y José la rinde en Puerta como relacionador.
--   · anticipo 0 y pago automático apagado: a Bowie NO se le gira desde
--     acá. Si se le girara, el club cobraría dos veces (el giro y la
--     rendición de josemenacho2). Pasada la fecha disponible_de deja el
--     100% igual, por si José necesita retirarlo a su propia cuenta.
--   · muestra_cupo false: el cupo de acá no es el de Puerta (allá venden
--     también los relacionadores), así que un "quedan 12" mentiría.
--   · rrpp_ve_ventas false: en estas fechas no vende ningún relacionador
--     de TICKETAZO; los relacionadores están en Puerta.
--
-- Si el slug ya está tomado por OTRO organizador (no por una corrida
-- anterior de este mismo archivo), se frena: reutilizarlo pondría las
-- fechas de Bowie bajo la cuenta y las tarifas de otro cliente.
do $$
declare v_o organizadores; v_slug text; v_nombre text;
begin
  foreach v_slug in array array['bowie', 'burtown'] loop
    v_nombre := case v_slug when 'bowie' then 'Bowie' else 'BurTown' end;
    select * into v_o from organizadores where slug = v_slug;
    if not found then
      insert into organizadores (slug, nombre, activo, fee_pct, fee_fijo_transaccion,
                                 fee_piso, comision_modo, comercio_id, anticipo_pct,
                                 pago_automatico, pago_auto_minimo, pago_hora,
                                 muestra_cupo, rrpp_ve_ventas, instagram)
      values (v_slug, v_nombre, true, 0, 0, 0, 'sobre', 1521, 0,
              false, 100, 8, false, false, null);
    elsif v_o.nombre <> v_nombre or v_o.fee_pct <> 0 or v_o.fee_fijo_transaccion <> 0
          or v_o.fee_piso <> 0 or v_o.comision_modo <> 'sobre' then
      raise exception 'El slug % ya es de otro organizador (%). No se reutiliza: revisalo a mano.',
        v_slug, v_o.nombre;
    end if;
  end loop;
end $$;

-- ── 2. configuración ────────────────────────────────────────
--
-- Una sola fila. `desde`: las fechas anteriores no se espejan nunca — las
-- del 10/10 (MADNESS y Crush) ya se estaban vendiendo en Puerta cuando esto
-- salió y no se tocan. `activo` es el interruptor: apagado, puerta-sync deja
-- de crear y actualizar espejos y saca de la venta los que quedan por
-- delante, PERO sigue mandando a Puerta las entradas ya cobradas y trayendo
-- sus estados — apagar no puede dejar a alguien que pagó sin su entrada en
-- la puerta. Correr `desde` hacia adelante también saca de la venta las
-- fechas ya espejadas que quedan antes del corte nuevo (cierre 'corte').
--
-- `filtro_espera`: cuánto tiene que seguir marcada por Seguridad una entrada
-- en Puerta antes de anularla. Allá la marca del filtro es un interruptor
-- (un segundo escaneo en modo filtro la saca) y no frena el ingreso: el
-- 10/10, 74 de 171 filtradas terminaron entrando, 61 de ellas unos 6 s
-- después de la marca. Anular a la primera lectura anularía a gente que
-- Seguridad dejó pasar o que quedó marcada por una doble lectura de la
-- cámara.
create table if not exists puerta_config (
  id                boolean primary key default true check (id),
  desde             date not null default '2026-10-11',
  activo            boolean not null default true,
  clubs             text[] not null default '{bowie,burtown}',
  filtro_espera     interval not null default '5 minutes'
                    check (filtro_espera >= interval '0'),
  ultima_corrida_at timestamptz,
  ultima_corrida    jsonb,
  actualizado_at    timestamptz not null default clock_timestamp()
);
insert into puerta_config (id) values (true) on conflict (id) do nothing;
alter table puerta_config enable row level security;
revoke all on puerta_config from anon, authenticated;

comment on table puerta_config is
  'Espejo de Plataforma Puerta (0103): desde qué fecha se espeja, el interruptor, la espera del filtro de Seguridad y el informe de la última corrida de puerta-sync. Para tocar a mano: update puerta_config set activo = false;';

-- ── 3. qué evento de acá es espejo de cuál de allá ──────────
--
-- `hash` es la huella del JSON que mandó Puerta la última vez que se
-- aplicó. Si vuelve igual, no se toca nada: sin esto cada minuto se
-- reescribirían evento, fases y precios de todas las fechas, y cada
-- reescritura es una ventana para pisarle un cambio a otra cosa.
-- `fase_online` es la fase que se inventa cuando Puerta vende sin fases;
-- sirve para no mandarle a Puerta un fase_id que allá no existe.
create table if not exists puerta_evento (
  evento_id      uuid primary key references eventos(id),
  organizador_id uuid not null references organizadores(id),
  club           text not null,
  tipo_id        uuid references tipo_entrada(id) on delete set null,
  fase_online    uuid references evento_fase(id) on delete set null,
  hash           text,
  datos          jsonb not null default '{}'::jsonb,
  cierre         text check (cierre in ('puerta', 'ausente', 'apagado', 'corte')),
  visto_at       timestamptz not null default clock_timestamp(),
  actualizado_at timestamptz not null default clock_timestamp(),
  creado_at      timestamptz not null default clock_timestamp()
);
alter table puerta_evento enable row level security;
revoke all on puerta_evento from anon, authenticated;

comment on table puerta_evento is
  'Eventos de TICKETAZO que son espejo de un evento de Plataforma Puerta (mismo uuid). cierre: puerta = Puerta lo cerró, ausente = Puerta dejó de mandarlo (o lo manda con datos que acá no se pueden aplicar), apagado = puerta_config.activo en false, corte = quedó antes de puerta_config.desde.';

-- ── 4. la cola hacia Puerta ─────────────────────────────────
--
-- Una fila por entrada a crear allá y una por anulación. No se llama a
-- Puerta desde el trigger que emite: emitir es la transacción del cobro, y
-- una red lenta o un Puerta caído no pueden demorar ni tumbar una venta ya
-- cobrada. Se anota acá, en la misma transacción —si la emisión se
-- deshace, la fila también—, y puerta-sync la manda.
--
-- estados: pendiente → tomado (una corrida la está mandando) → hecho.
-- rechazado = Puerta dijo que no (evento cerrado o borrado allá, fase que
-- falta): una entrada PAGADA sin lugar en la puerta, la mira una persona.
-- cancelado = no hacía falta mandarla (se anuló acá antes de su primer
-- intento, o Seguridad retiró la marca del filtro antes de que saliera la
-- anulación).
--
-- `forzar_precio`: Puerta rechaza con 'precio_distinto' una entrada cuyo
-- precio no es el que tiene HOY (alguien reservó a 60, en Puerta lo
-- subieron a 70 y pagó después). La entrada está cobrada y a ese precio:
-- registrar_envios la vuelve a mandar sola con forzar_precio, que en Puerta
-- guarda lo cobrado y deja rastro en ticketazo_forzados. Para reenviar a
-- mano una 'rechazado' después de mirarla:
--     update puerta_envio set estado = 'pendiente', forzar_precio = true,
--            proximo_at = clock_timestamp() where id = …;
-- `motivo` de una anulación: 'panel' (alguien la anuló acá) o
-- 'filtro_seguridad' (la rechazó el filtro de Puerta; ver aplicar_estados).
create table if not exists puerta_envio (
  id             bigint generated always as identity primary key,
  organizador_id uuid not null references organizadores(id),
  evento_id      uuid not null references eventos(id),
  entrada_id     uuid not null references entradas(id) on delete cascade,
  tipo           text not null check (tipo in ('entrada', 'anular')),
  estado         text not null default 'pendiente'
                 check (estado in ('pendiente', 'tomado', 'hecho', 'rechazado', 'cancelado')),
  motivo         text,
  forzar_precio  boolean not null default false,
  intentos       int not null default 0,
  proximo_at     timestamptz not null default clock_timestamp(),
  tomado_at      timestamptz,
  resultado      text,
  puerta_id      uuid,
  ultimo_error   text,
  creado_at      timestamptz not null default clock_timestamp(),
  actualizado_at timestamptz not null default clock_timestamp(),
  unique (tipo, entrada_id)
);
create index if not exists puerta_envio_cola_idx on puerta_envio (tipo, proximo_at)
  where estado in ('pendiente', 'tomado');
create index if not exists puerta_envio_evento_idx on puerta_envio (evento_id);
alter table puerta_envio enable row level security;
revoke all on puerta_envio from anon, authenticated;
revoke all on sequence puerta_envio_id_seq from anon, authenticated;

comment on table puerta_envio is
  'Cola de entradas y anulaciones de eventos espejo que puerta-sync tiene que mandarle a Plataforma Puerta. rechazado = Puerta no la aceptó: entrada pagada sin lugar allá, revisar a mano.';

-- service_role es el único que llega: lo usa puerta-sync, y estado-orden /
-- barrer-pagos / crear-orden miran si hay algo pendiente en la cola.
grant select, insert, update, delete on puerta_config, puerta_evento, puerta_envio to service_role;

-- ── 5. ¿es espejo? ──────────────────────────────────────────
create or replace function evento_espejo(p_evento uuid) returns boolean
  language sql stable security definer set search_path = public as $$
  select exists (select 1 from puerta_evento where evento_id = p_evento)
$$;
revoke execute on function evento_espejo(uuid) from public, anon, authenticated;
grant execute on function evento_espejo(uuid) to service_role;

-- El permiso para escribir lo espejado. Lo prenden las funciones del sync
-- con set_config(…, true) al entrar y lo dejan como estaba al salir: vale
-- MIENTRAS corre la función, no por el resto de la transacción. Si la
-- función revienta, el rollback (de la transacción o del bloque que la
-- atrapó) también devuelve el valor anterior.
--
-- Por qué no la cláusula `set ticketazo.puerta_sync = 'on'` en el CREATE
-- FUNCTION, que hace eso mismo sola: fijar un parámetro propio en la
-- definición de una función es cosa de superusuario, y en Supabase la
-- migración corre como `postgres`, que no lo es (rolsuper = false, y
-- supautils no lo habilita). La migración entera se caía con "permission
-- denied to set parameter". set_config en tiempo de ejecución sí lo puede
-- cualquiera.
--
-- Esas funciones solo las ejecuta service_role, y PostgREST no deja fijar
-- un GUC arbitrario desde afuera, así que el panel no tiene cómo prenderlo.
-- Para un arreglo a mano desde el SQL editor:
--     begin; set local ticketazo.puerta_sync = 'on'; update ...; commit;
create or replace function puerta_sync_activo() returns boolean
  language sql stable set search_path = public as $$
  select coalesce(current_setting('ticketazo.puerta_sync', true), '') = 'on'
$$;
revoke execute on function puerta_sync_activo() from public, anon, authenticated;

-- ── 6. la guarda del panel ──────────────────────────────────
--
-- Nombre, fecha, horario, edad, estado, precios, fases y tipos de un espejo
-- se deciden en Puerta. Si el panel los cambiara, al minuto el sync los
-- pisaría (o peor: no, porque la huella de Puerta no cambió) y el precio
-- de acá dejaría de ser el de allá — el comprador pagaría una cosa y José
-- rendiría otra. Se frena en un trigger y no en cada función del panel
-- porque el panel escribe estas tablas de dos maneras (PostgREST directo y
-- funciones como guardar_precios, borrar_fase, cerrar_evento) y una guarda
-- por camino es una guarda que alguien olvida en el camino siguiente.
--
-- Lo que sí se puede tocar: flyer, descripción, arte, colores, lugar y
-- mapa del evento; arte de la fase; descripción e "incluye" del tipo.
--
-- Y entradas: en un espejo la puerta es la de Puerta. Nada de acá pasa una
-- entrada a 'usada' (ni la devuelve a 'valida'), y no hay cortesías:
-- una cortesía emitida acá no existiría allá y rebotaría en la fila.
-- Anular sí se puede: encola la anulación hacia Puerta (más abajo).
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
        new.rrpp_por_defecto, new.listado)
       is distinct from
       (old.id, old.organizador_id, old.slug, old.nombre, old.fecha, old.hora_inicio,
        old.hora_fin, old.edad_min, old.estado, old.comision_entrada,
        old.rrpp_por_defecto, old.listado) then
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

drop trigger if exists puerta_guarda on eventos;
create trigger puerta_guarda before update or delete on eventos
  for each row execute function puerta_guarda();
drop trigger if exists puerta_guarda on evento_fase;
create trigger puerta_guarda before insert or update or delete on evento_fase
  for each row execute function puerta_guarda();
drop trigger if exists puerta_guarda on fase_precio;
create trigger puerta_guarda before insert or update or delete on fase_precio
  for each row execute function puerta_guarda();
drop trigger if exists puerta_guarda on tipo_entrada;
create trigger puerta_guarda before insert or update or delete on tipo_entrada
  for each row execute function puerta_guarda();
drop trigger if exists puerta_guarda on mesas;
create trigger puerta_guarda before insert or update of evento_id on mesas
  for each row execute function puerta_guarda();
-- En entradas, con WHEN: es la tabla caliente de la emisión y la puerta.
-- Las entradas de una orden y las anulaciones ni llaman a la función.
drop trigger if exists puerta_guarda on entradas;
create trigger puerta_guarda before insert on entradas
  for each row when (new.orden_id is null) execute function puerta_guarda();
drop trigger if exists puerta_guarda_estado on entradas;
create trigger puerta_guarda_estado before update of estado on entradas
  for each row when (new.estado is distinct from old.estado and new.estado <> 'anulada')
  execute function puerta_guarda();

-- ── 7. llenar la cola ───────────────────────────────────────
--
-- Al pagarse la orden y no al insertar cada entrada: emitir_orden inserta
-- las entradas ANTES de marcar la orden pagada, y una entrada de una orden
-- que todavía no está pagada no se le manda a nadie. emitir_orden es el
-- único camino a 'pagada' (estado-orden, barrer-pagos, crear-orden gratis y
-- resolver_revision pasan todos por ella), así que este trigger los cubre a
-- todos sin tocar ninguno. Las mesas quedan afuera.
create or replace function puerta_encolar_orden() returns trigger
  language plpgsql security definer set search_path = public as $$
begin
  if evento_espejo(new.evento_id) then
    insert into puerta_envio (organizador_id, evento_id, entrada_id, tipo)
    select e.organizador_id, e.evento_id, e.id, 'entrada'
      from entradas e
     where e.orden_id = new.id and e.mesa_id is null and e.estado <> 'anulada'
    on conflict (tipo, entrada_id) do nothing;
  end if;
  return new;
end $$;
revoke execute on function puerta_encolar_orden() from public, anon, authenticated;

drop trigger if exists puerta_encolar_orden on ordenes;
create trigger puerta_encolar_orden after update of estado on ordenes
  for each row when (new.estado = 'pagada' and old.estado is distinct from 'pagada')
  execute function puerta_encolar_orden();

-- Anular en el panel (anular_entrada, anular_orden) anula también allá.
-- Lo que anula el propio sync —porque Puerta ya la tiene anulada— no
-- vuelve a viajar: Puerta ya lo sabe.
--
-- Si ya había una fila 'anular' del filtro de Seguridad, pasa a ser del
-- panel: cancelada (Seguridad retiró la marca antes de que saliera) se
-- revive, y en camino se queda en camino pero ya no se cancela si después
-- retiran la marca. Con un `do nothing` la anulación del panel chocaba
-- contra esa fila y, si el filtro se retiraba, no salía nunca: la entrada
-- seguía válida en la puerta de Puerta.
create or replace function puerta_encolar_anulacion() returns trigger
  language plpgsql security definer set search_path = public as $$
begin
  if not puerta_sync_activo() and evento_espejo(new.evento_id) then
    insert into puerta_envio (organizador_id, evento_id, entrada_id, tipo, motivo)
    values (new.organizador_id, new.evento_id, new.id, 'anular', 'panel')
    on conflict (tipo, entrada_id) do update set
      motivo       = 'panel',
      estado       = case when puerta_envio.estado = 'cancelado' then 'pendiente'
                          else puerta_envio.estado end,
      proximo_at   = case when puerta_envio.estado = 'cancelado' then clock_timestamp()
                          else puerta_envio.proximo_at end,
      resultado    = case when puerta_envio.estado = 'cancelado' then null
                          else puerta_envio.resultado end,
      ultimo_error = case when puerta_envio.estado = 'cancelado' then null
                          else puerta_envio.ultimo_error end,
      actualizado_at = clock_timestamp()
     where puerta_envio.estado in ('cancelado', 'pendiente', 'tomado');
  end if;
  return new;
end $$;
revoke execute on function puerta_encolar_anulacion() from public, anon, authenticated;

drop trigger if exists puerta_encolar_anulacion on entradas;
create trigger puerta_encolar_anulacion after update of estado on entradas
  for each row when (new.estado = 'anulada' and old.estado is distinct from 'anulada')
  execute function puerta_encolar_anulacion();

-- ── 8. del JSON de Puerta al espejo ─────────────────────────

-- Hasta cuándo se vende online. Es el corte de prepagadas de Puerta
-- (manilla_hasta_ts, el que app.js anuncia como "Podés vender prepagadas
-- hasta las …"). Si está vacío, en Puerta significa "sin límite" (así lo
-- dice la pantalla de horario de venta); acá sin límite no puede ser, porque
-- se seguiría vendiendo con la fiesta terminada: se toma la hora legada
-- manilla_hasta si la hay y si no el fin del evento. Y nunca después de
-- entrada_hasta: pasada esa hora el QR ya no entra en Puerta, venderlo
-- sería cobrar una entrada que rebota.
create or replace function puerta_corte(p jsonb) returns timestamptz
  language sql stable set search_path = public as $$
  select least(
    coalesce(
      nullif(p->>'manilla_hasta_ts', '')::timestamptz,
      case when nullif(p->>'manilla_hasta', '') is not null then
        ((p->>'fecha')::date
          + case when (p->>'manilla_hasta')::time
                      < coalesce(nullif(p->>'hora_inicio', '')::time, '21:00')
                 then 1 else 0 end
          + (p->>'manilla_hasta')::time) at time zone 'America/La_Paz'
      end,
      ((p->>'fecha')::date
        + case when coalesce(nullif(p->>'hora_fin', '')::time, '06:00')
                    <= coalesce(nullif(p->>'hora_inicio', '')::time, '21:00')
               then 1 else 0 end
        + coalesce(nullif(p->>'hora_fin', '')::time, '06:00')) at time zone 'America/La_Paz'),
    nullif(p->>'entrada_hasta', '')::timestamptz)
$$;
revoke execute on function puerta_corte(jsonb) from public, anon, authenticated;

-- El slug sale del nombre ("Crush" → crush). Bowie repite nombres de
-- noche en noche, así que si ya hay otra fecha con ese slug se desempata
-- con la fecha (crush-17-10). Se decide UNA vez, al crear: el link ya
-- puede estar circulando por WhatsApp, y renombrar en Puerta no lo rompe.
create or replace function puerta_slug(p_org uuid, p_nombre text, p_fecha date, p_evento uuid)
returns text language plpgsql stable set search_path = public as $$
declare v_base text; v text; i int := 0;
begin
  v_base := lower(translate(coalesce(p_nombre, ''),
    'ÁÀÄÂÃÉÈËÊÍÌÏÎÓÒÖÔÕÚÙÜÛÑÇáàäâãéèëêíìïîóòöôõúùüûñç',
    'AAAAAEEEEIIIIOOOOOUUUUNCaaaaaeeeeiiiiooooouuuunc'));
  v_base := btrim(regexp_replace(v_base, '[^a-z0-9]+', '-', 'g'), '-');
  v_base := btrim(left(v_base, 45), '-');
  if length(v_base) < 2 then v_base := 'noche'; end if;
  foreach v in array array[v_base,
                           v_base || '-' || to_char(p_fecha, 'DD-MM'),
                           v_base || '-' || to_char(p_fecha, 'DD-MM-YYYY'),
                           v_base || '-' || left(replace(p_evento::text, '-', ''), 8)] loop
    if not exists (select 1 from eventos
                    where organizador_id = p_org and slug = v and id <> p_evento) then
      return v;
    end if;
  end loop;
  return v;   -- el último lleva parte del uuid: no se repite
end $$;
revoke execute on function puerta_slug(uuid, text, date, uuid) from public, anon, authenticated;

-- Una imagen que viene de Puerta (flyer, arte de la entrada, arte de una
-- fase) se acepta solo si está en el Storage público de Puerta y tiene
-- nombre de imagen. og (la tarjeta de WhatsApp) baja esa URL desde el
-- servidor y la sirve bajo ticketazo.com.bo/og/…: con cualquier URL, un
-- admin de Puerta —el personal del boliche, no gente de TICKETAZO—
-- decidiría qué contenido sirve nuestro dominio (un SVG con script, por
-- ejemplo, en el mismo origen que el panel). Hoy todas las de Puerta
-- cumplen (disenos/<uuid>.jpg?v=…). Una que no cumple se trata como vacía:
-- queda la imagen que ya había.
create or replace function puerta_url(p text) returns text
  language sql immutable set search_path = public as $$
  select case
    when p ~* '^https://kdkjmqrbiszmkcprinir\.supabase\.co/storage/v1/object/public/[a-z0-9._~%/+=-]+\.(jpe?g|png|webp)(\?[a-z0-9._~%&=+-]*)?$'
     and p !~ '\.\.'
    then p end
$$;
revoke execute on function puerta_url(text) from public, anon, authenticated;

-- Un evento de Puerta → su espejo. Devuelve qué hizo, para el informe
-- (con ':sin_precio' al final si alguna fase vino sin precio de verdad).
--
-- Fases: si Puerta vende por fases, las mismas fases con el MISMO uuid y
-- precio (el fase_id que vuelve a Puerta con cada entrada es entonces el de
-- allá), y en el MISMO orden: `orden` y, a igual `orden`, el lugar en la
-- lista. Puerta la manda ordenada como la recorre fase_vigente (orden,
-- created_at); desempatar acá por otra cosa (desde, id) podía poner a la
-- venta otra fase que la que Puerta vende ahora, a otro precio. Si vende a
-- precio único, una fase "Online" que corta donde corta la venta de
-- prepagadas. Las que dejan de existir se desactivan en vez de
-- borrarse: pueden tener órdenes colgadas (FK restrict) y la historia de lo
-- vendido no se borra.
--
-- Precio 0 (o vacío, o negativo): esa fase NO se vende acá. En Puerta no
-- hay ningún CHECK que impida un precio_manilla en 0, y acá una fase a
-- Bs 0 es un evento gratis sin tope: crear-orden emite sin pasarela y cada
-- QR viajaría a Puerta como prepagada de josemenacho2. Una noche "free" de
-- verdad se carga a mano, no se espeja sola.
--
-- Cupo de una fase de Puerta: allá la fase avanza cuando se llena, y la
-- llenan también los relacionadores. Puerta manda `vendidas` (todas las no
-- anuladas de esa fase, incluidas las de acá que ya llegaron) o `quedan`.
-- Con cualquiera de las dos, lo que acá se puede vender es lo que le queda
-- a Puerta menos lo que acá ya está cobrado y todavía no llegó allá (la
-- cola). Como el cupo de acá cuenta lo pagado acá, queda:
--     cupo acá = pagadas acá + (quedan allá − en la cola)
-- que no cambia cuando una entrada de acá llega allá (sube `vendidas` y baja
-- la cola), así que entre una lectura y la otra sigue siendo cierto. Sin
-- ninguno de los dos se copia el cupo de Puerta: acá no se vende más que
-- eso, pero tampoco se entera de lo que vendieron los relacionadores.
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

  -- ── el evento ──
  if not v_existe then
    insert into eventos (id, organizador_id, slug, nombre, lugar, flyer_url, fecha,
                         hora_inicio, hora_fin, edad_min, estado, arte_url,
                         comision_entrada, listado, rrpp_por_defecto)
    values (v_id, v_org.id, puerta_slug(v_org.id, p->>'nombre', v_fecha, v_id),
            btrim(p->>'nombre'), v_org.nombre, puerta_url(p->>'flyer_url'), v_fecha,
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
                         then puerta_url(p->>'ticket_url') else e.arte_url end
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

-- La lista entera que mandó Puerta. `p_eventos` null = no hubo respuesta
-- de Puerta: no se cierra nada (cerrar por un corte de red sacaría de la
-- venta todas las fechas). Una lista vacía SÍ es respuesta: no hay fechas.
-- Cada evento va en su propio bloque: uno con datos raros no frena a los
-- otros.
create or replace function puerta_aplicar_eventos(p_eventos jsonb, p_ventana date)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_cfg puerta_config; v_ev jsonb; v_r text; v_ids uuid[] := '{}';
  v_creados int := 0; v_actualizados int := 0; v_iguales int := 0; v_cerrados int := 0;
  v_ignorados jsonb := '[]'; v_errores jsonb := '[]'; v_sin_precio jsonb := '[]';
  v_hoy date := (now() at time zone 'America/La_Paz')::date;
  v_sync text := coalesce(current_setting('ticketazo.puerta_sync', true), '');
begin
  select * into v_cfg from puerta_config where id;
  perform set_config('ticketazo.puerta_sync', 'on', true);   -- ver puerta_sync_activo

  if not coalesce(v_cfg.activo, false) then
    with c as (
      update eventos e set estado = 'cerrado'
        from puerta_evento pe
       where pe.evento_id = e.id and e.estado <> 'cerrado' and e.fecha >= v_hoy - 1
      returning e.id)
    update puerta_evento set cierre = 'apagado', hash = null, actualizado_at = clock_timestamp()
     where evento_id in (select id from c);
    get diagnostics v_cerrados = row_count;
    perform set_config('ticketazo.puerta_sync', v_sync, true);
    return jsonb_build_object('apagado', true, 'cerrados', v_cerrados);
  end if;

  if p_eventos is null or jsonb_typeof(p_eventos) <> 'array' then
    perform set_config('ticketazo.puerta_sync', v_sync, true);
    return jsonb_build_object('sin_datos', true);
  end if;

  for v_ev in select x from jsonb_array_elements(p_eventos) x loop
    begin
      v_r := puerta_espejar_evento(v_ev, false);
    exception when others then
      v_r := 'error:' || sqlerrm;
    end;
    -- "Vino" es lo que se aplicó, lo que llegó igual y lo que falló por
    -- algo pasajero (se reintenta al minuto). Un 'ignorado' NO: un espejo
    -- que Puerta manda con otro boliche, sin nombre o antes del corte no se
    -- puede actualizar, y no puede seguir vendiendo con el precio y el
    -- horario de la última vez. Abajo se cierra como cualquier ausente.
    if v_r not like 'ignorado:%'
       and coalesce(v_ev->>'id', '') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
      v_ids := v_ids || (v_ev->>'id')::uuid;
    end if;
    case
      when v_r like 'creado%'      then v_creados := v_creados + 1;
      when v_r like 'actualizado%' then v_actualizados := v_actualizados + 1;
      when v_r = 'igual'           then v_iguales := v_iguales + 1;
      when v_r like 'error:%'      then
        v_errores := v_errores || jsonb_build_object('id', v_ev->>'id', 'motivo', v_r);
      else
        v_ignorados := v_ignorados || jsonb_build_object('id', v_ev->>'id', 'motivo', v_r);
    end case;
    if v_r like '%:sin_precio' then
      v_sin_precio := v_sin_precio || to_jsonb(v_ev->>'id');
    end if;
  end loop;

  -- Fuera de la venta: lo que Puerta dejó de mandar (lo borraron o lo
  -- despublicaron allá), lo que manda y acá no se puede aplicar (los
  -- 'ignorado' de arriba) y lo que quedó antes de `desde`. Desde ayer y no
  -- desde la ventana: si alguien corre `desde` hacia adelante, a Puerta se
  -- le piden fechas desde el corte nuevo y las del medio ya no vienen; sin
  -- esto quedarían a la venta, congeladas, sin enterarse de un cambio de
  -- precio o de un cierre en Puerta. Si vuelve, el próximo pase lo reabre
  -- (hash en null obliga a reaplicarlo).
  with c as (
    update eventos e set estado = 'cerrado'
      from puerta_evento pe
     where pe.evento_id = e.id and e.estado <> 'cerrado'
       and e.fecha >= least(coalesce(p_ventana, v_hoy - 1), v_hoy - 1)
       and not (e.id = any (v_ids))
    returning e.id, e.fecha)
  update puerta_evento pe
     set cierre = case when c.fecha < v_cfg.desde then 'corte' else 'ausente' end,
         hash = null, actualizado_at = clock_timestamp()
    from c
   where pe.evento_id = c.id;
  get diagnostics v_cerrados = row_count;

  perform set_config('ticketazo.puerta_sync', v_sync, true);
  return jsonb_build_object('recibidos', jsonb_array_length(p_eventos),
    'creados', v_creados, 'actualizados', v_actualizados, 'iguales', v_iguales,
    'cerrados', v_cerrados, 'sin_precio', v_sin_precio,
    'ignorados', v_ignorados, 'errores', v_errores);
end $$;
revoke execute on function puerta_aplicar_eventos(jsonb, date) from public, anon, authenticated;
grant execute on function puerta_aplicar_eventos(jsonb, date) to service_role;

-- ── 9. lo que puerta-sync necesita saber al arrancar ────────
--
-- ventana: desde qué fecha pedirle eventos a Puerta. Ayer incluido: la
-- noche del sábado sigue abierta el domingo de madrugada y Puerta la cierra
-- recién a la mañana. estados: los espejos de los últimos dos días con al
-- menos una entrada ya en Puerta, que es donde puede haber ingresos y
-- filtros que traer.
create or replace function puerta_estado_sync() returns jsonb
  language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'activo',  c.activo,
    'desde',   c.desde,
    'ventana', greatest(c.desde, (now() at time zone 'America/La_Paz')::date - 1),
    'estados', coalesce((
      select jsonb_agg(pe.evento_id)
        from puerta_evento pe join eventos e on e.id = pe.evento_id
       where e.fecha >= (now() at time zone 'America/La_Paz')::date - 2
         and exists (select 1 from puerta_envio s
                      where s.evento_id = pe.evento_id and s.tipo = 'entrada'
                        and s.estado = 'hecho')), '[]'::jsonb))
  from puerta_config c where c.id
$$;
revoke execute on function puerta_estado_sync() from public, anon, authenticated;
grant execute on function puerta_estado_sync() to service_role;

-- ── 10. tomar y devolver la cola ────────────────────────────
--
-- `for update skip locked` + la marca 'tomado': dos corridas solapadas
-- (el cron y el aviso inmediato de una compra) nunca agarran la misma fila.
-- Una fila 'tomado' de hace más de dos minutos es de una corrida que murió
-- a mitad de camino y se vuelve a tomar: reenviarla no duplica nada,
-- Puerta es idempotente por ref.
--
-- Antes de tomar se limpia lo que no hace falta mandar: una entrada que se
-- anuló acá antes de su PRIMER intento no viaja (ni su anulación). Con un
-- intento hecho no se sabe: un timeout o un 5xx pueden llegar después de
-- que Puerta la creó y se perdió la respuesta. Esa se manda igual (si ya
-- estaba, Puerta contesta 'ya_estaba') y la anulación sale detrás. Y una
-- anulación no sale mientras la entrada siga en camino: anular algo que
-- allá todavía no existe devolvería "no_existe" y la entrada llegaría
-- después, viva.
create or replace function puerta_tomar_envios(p_tipo text, p_limite int default 50)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v jsonb;
begin
  if p_tipo not in ('entrada', 'anular') then raise exception 'tipo inválido: %', p_tipo; end if;

  -- La limpieza también salta lo bloqueado: si otra corrida tiene una fila
  -- en la mano, esta no se queda esperando a que la suelte.
  if p_tipo = 'entrada' then
    update puerta_envio s
       set estado = 'cancelado', resultado = 'anulada_antes_de_salir',
           actualizado_at = clock_timestamp()
     where s.id in (select x.id from puerta_envio x
                     where x.tipo = 'entrada' and x.estado = 'pendiente' and x.intentos = 0
                       and exists (select 1 from entradas e
                                    where e.id = x.entrada_id and e.estado = 'anulada')
                     for update of x skip locked);
  else
    -- 'nunca_llego' solo si de verdad nunca salió: sin fila de entrada (una
    -- mesa) o cancelada antes de su primer intento. Una 'rechazado' también
    -- se anula allá: Puerta puede tenerla con otros datos, y en el peor caso
    -- contesta 'no_existe'.
    update puerta_envio a
       set estado = 'hecho', resultado = 'nunca_llego', actualizado_at = clock_timestamp()
     where a.id in (select x.id from puerta_envio x
                     where x.tipo = 'anular' and x.estado = 'pendiente'
                       and not exists (select 1 from puerta_envio s
                                        where s.entrada_id = x.entrada_id and s.tipo = 'entrada'
                                          and (s.estado in ('pendiente', 'tomado', 'hecho', 'rechazado')
                                               or s.intentos > 0))
                     for update of x skip locked);
  end if;

  with c as (
    select s.id
      from puerta_envio s
     where s.tipo = p_tipo
       and ((s.estado = 'pendiente' and s.proximo_at <= clock_timestamp())
         or (s.estado = 'tomado' and s.tomado_at < clock_timestamp() - interval '2 minutes'))
       and (p_tipo = 'entrada' or not exists (
             select 1 from puerta_envio x
              where x.entrada_id = s.entrada_id and x.tipo = 'entrada'
                and x.estado in ('pendiente', 'tomado')))
     order by s.id
     limit greatest(least(coalesce(p_limite, 50), 200), 1)
     for update of s skip locked),
  u as (
    update puerta_envio s
       set estado = 'tomado', tomado_at = clock_timestamp(), intentos = s.intentos + 1,
           actualizado_at = clock_timestamp()
      from c where s.id = c.id
    returning s.id, s.entrada_id, s.evento_id, s.forzar_precio)
  select coalesce(jsonb_agg(jsonb_build_object(
           'id',        u.id,
           'ref',       u.entrada_id,
           'evento_id', u.evento_id,
           'code',      e.code,
           -- Puerta pide cliente not null; una compra sin nombre no existe
           -- (crear-orden lo exige) pero el sync no puede trabarse por eso.
           'cliente',   coalesce(nullif(btrim(e.cliente), ''), 'Compra TICKETAZO'),
           'precio',    e.precio,
           'forzar_precio', u.forzar_precio,
           -- La fase "Online" es nuestra: allá no existe ese uuid.
           'fase_id',   case when e.fase_id is not distinct from pe.fase_online then null
                             else e.fase_id end)
           order by u.id), '[]'::jsonb)
    into v
    from u
    join entradas e on e.id = u.entrada_id
    left join puerta_evento pe on pe.evento_id = u.evento_id;
  return v;
end $$;
revoke execute on function puerta_tomar_envios(text, int) from public, anon, authenticated;
grant execute on function puerta_tomar_envios(text, int) to service_role;

-- Lo que contestó Puerta, fila por fila. Un error (de red, un 5xx, una
-- ref que no volvió) devuelve la fila a la cola con espera creciente:
-- 30 s, 1, 2, 4, 8 minutos y después cada 15. No se rinde nunca: detrás
-- de cada fila hay una entrada pagada.
--
-- 'precio_distinto': Puerta cambió el precio entre la reserva y el pago
-- (o en el minuto que tarda el sync en copiarlo). Si lo que se le manda es
-- exactamente lo que el comprador pagó —el precio_unitario de su orden
-- pagada—, se reenvía en el acto con forzar_precio: la entrada está
-- cobrada y tiene que entrar, y José rinde lo cobrado, no el precio nuevo.
-- Puerta guarda el rastro en ticketazo_forzados. Se fuerza una sola vez;
-- si vuelve a rebotar, queda 'rechazado' para una persona.
create or replace function puerta_registrar_envios(p_resultados jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_hechos int; v_rechazados int; v_reintentos int; v_forzados int; v_anuladas int;
        v_sync text := coalesce(current_setting('ticketazo.puerta_sync', true), '');
begin
  with r as (
    select distinct on (x.id) x.id, x.resultado, x.puerta_id, left(x.motivo, 500) as motivo
      from jsonb_to_recordset(coalesce(p_resultados, '[]'::jsonb))
           as x(id bigint, resultado text, puerta_id uuid, motivo text)
     where x.id is not null),
  final as (
    select s.id, r.resultado, r.puerta_id, r.motivo,
           case
             when s.tipo = 'entrada' and r.resultado in ('creada', 'ya_estaba') then 'hecho'
             when s.tipo = 'entrada' and r.resultado = 'rechazada' and not s.forzar_precio
                  and coalesce(r.motivo, '') like 'precio_distinto%'
                  and exists (select 1
                                from entradas e
                                join ordenes o on o.id = e.orden_id and o.estado = 'pagada'
                                join orden_items i on i.orden_id = o.id
                                                  and i.tipo_id = e.tipo_id
                                                  and i.fase_id is not distinct from e.fase_id
                               where e.id = s.entrada_id and i.precio_unitario = e.precio)
               then 'forzar'
             when s.tipo = 'entrada' and r.resultado = 'rechazada' then 'rechazado'
             when s.tipo = 'anular'
                  and r.resultado in ('anulada', 'ya_anulada', 'usada', 'no_existe') then 'hecho'
             else 'pendiente'
           end as estado
      from r join puerta_envio s on s.id = r.id and s.estado = 'tomado'),
  upd as (
    update puerta_envio s set
      estado        = case when f.estado = 'forzar' then 'pendiente' else f.estado end,
      forzar_precio = s.forzar_precio or f.estado = 'forzar',
      resultado     = coalesce(f.resultado, 'error'),
      puerta_id     = coalesce(f.puerta_id, s.puerta_id),
      ultimo_error  = case when f.estado = 'hecho' then null
                           else coalesce(f.motivo, f.resultado, 'sin detalle') end,
      proximo_at    = case when f.estado = 'forzar' then clock_timestamp()
                           when f.estado = 'pendiente'
                           then clock_timestamp() + least(interval '30 seconds'
                                  * power(2, least(greatest(s.intentos - 1, 0), 5)),
                                interval '15 minutes')
                           else s.proximo_at end,
      tomado_at     = null,
      actualizado_at = clock_timestamp()
      from final f
     where s.id = f.id
    returning f.estado)
  select count(*) filter (where estado = 'hecho'),
         count(*) filter (where estado = 'rechazado'),
         count(*) filter (where estado = 'pendiente'),
         count(*) filter (where estado = 'forzar')
    into v_hechos, v_rechazados, v_reintentos, v_forzados
    from upd;

  -- Una anulación que Puerta confirmó y que acá sigue válida es la del
  -- filtro de Seguridad (la del panel ya estaba anulada acá): recién ahora
  -- se anula acá, sin devolución. Antes no, porque si en el medio la
  -- persona entró Puerta contesta 'usada', y acá tiene que quedar usada, no
  -- anulada con alguien adentro. El permiso del sync va prendido para que
  -- puerta_encolar_anulacion no la vuelva a encolar: Puerta ya lo sabe.
  perform set_config('ticketazo.puerta_sync', 'on', true);
  update entradas e set estado = 'anulada'
    from puerta_envio s
   where s.entrada_id = e.id and s.tipo = 'anular' and s.estado = 'hecho'
     and s.resultado in ('anulada', 'ya_anulada')
     and s.id in (select x.id from jsonb_to_recordset(coalesce(p_resultados, '[]'::jsonb))
                                    as x(id bigint))
     and e.estado = 'valida' and evento_espejo(e.evento_id);
  get diagnostics v_anuladas = row_count;
  perform set_config('ticketazo.puerta_sync', v_sync, true);

  return jsonb_build_object('hechos', v_hechos, 'rechazados', v_rechazados,
                            'reintentos', v_reintentos, 'forzados', v_forzados,
                            'anuladas_aca', v_anuladas);
end $$;
revoke execute on function puerta_registrar_envios(jsonb) from public, anon, authenticated;
grant execute on function puerta_registrar_envios(jsonb) to service_role;

-- ── 11. lo que pasó en la puerta de allá ────────────────────
--
-- Puerta es la verdad de la puerta. Por entrada (ref = id de acá):
--   · usada allá y válida acá → usada, con la hora de allá. Es lo que hace
--     que "Mis entradas" y los reportes de acá digan que entró.
--   · anulada allá → anulada acá. Sin devolución: la orden queda pagada,
--     la plata no se mueve.
--   · filtrada por Seguridad, todavía válida allá y con la marca puesta
--     hace más de puerta_config.filtro_espera → se encola la anulación
--     HACIA Puerta (motivo 'filtro_seguridad'). Es lo que se acordó con el
--     boliche: el filtro decide, el que no pasa no recupera, y queda anulada
--     en los dos lados. Allá nadie más la anula: marcar el filtro en Puerta
--     no cambia el estado y el escáner no mira la marca, así que sin esto la
--     persona volvía a la fila y entraba. Acá se anula cuando Puerta lo
--     confirma (registrar_envios), no antes: si Puerta contesta 'usada',
--     entró, y acá queda usada.
--     La espera es por cómo anda el filtro allá: la marca es un interruptor
--     (un segundo escaneo la saca) y muchas veces la persona entra segundos
--     después. Si Seguridad retira la marca o la persona entra antes de que
--     salga la anulación, la fila se cancela.
--   · válida allá y usada acá → válida otra vez (allá deshicieron el
--     ingreso). Solo si la marcó el sync (sin portero de acá).
-- Lo que acá ya está anulado no se resucita: una anulación de acá viaja
-- por la cola y Puerta se pone al día sola. Una usada acá no se anula
-- (misma regla que anular_entrada sin p_incluir_usadas) y una anulada acá
-- que allá entró tampoco se toca: las dos se cuentan para que alguien mire.
create or replace function puerta_aplicar_estados(p_entradas jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_usadas int; v_anuladas int; v_devueltas int; v_filtradas int; v_retiradas int;
        v_raras int; v_raras2 int; v_n int; v_espera interval;
        v_sync text := coalesce(current_setting('ticketazo.puerta_sync', true), '');
begin
  perform set_config('ticketazo.puerta_sync', 'on', true);   -- ver puerta_sync_activo
  select filtro_espera into v_espera from puerta_config where id;
  v_espera := coalesce(v_espera, interval '5 minutes');

  -- Se lee el JSON en cada paso en vez de pasarlo por una tabla temporal:
  -- son a lo sumo unos cientos de filas por minuto, y una tabla temporal
  -- por corrida es catálogo que se crea y se tira cada sesenta segundos.
  with p as (
    select distinct on (x.ref) x.ref, upper(x.code) as code, x.estado, x.used_at
      from jsonb_to_recordset(coalesce(p_entradas, '[]'::jsonb))
           as x(ref uuid, code text, estado text, used_at timestamptz)
     where x.ref is not null)
  update entradas e set estado = 'usada', used_at = coalesce(p.used_at, clock_timestamp())
    from p
   where e.id = p.ref and e.code = p.code and e.estado = 'valida' and p.estado = 'usada'
     and evento_espejo(e.evento_id);
  get diagnostics v_usadas = row_count;

  with p as (
    select distinct on (x.ref) x.ref, upper(x.code) as code, x.estado
      from jsonb_to_recordset(coalesce(p_entradas, '[]'::jsonb))
           as x(ref uuid, code text, estado text)
     where x.ref is not null)
  update entradas e set estado = 'anulada'
    from p
   where e.id = p.ref and e.code = p.code and e.estado = 'valida' and p.estado = 'anulada'
     and evento_espejo(e.evento_id);
  get diagnostics v_anuladas = row_count;

  -- El filtro: primero se cancela lo que ya no corresponde (Seguridad sacó
  -- la marca, o la persona entró, o allá ya está anulada), después se
  -- encola lo nuevo. Una fila cancelada se revive si la vuelven a marcar.
  with p as (
    select distinct on (x.ref) x.ref, x.estado, coalesce(x.filtrada, false) as filtrada
      from jsonb_to_recordset(coalesce(p_entradas, '[]'::jsonb))
           as x(ref uuid, estado text, filtrada boolean)
     where x.ref is not null)
  update puerta_envio s
     set estado = 'cancelado', resultado = 'filtro_retirado', actualizado_at = clock_timestamp()
    from p
   where s.entrada_id = p.ref and s.tipo = 'anular' and s.motivo = 'filtro_seguridad'
     and s.estado = 'pendiente' and not (p.filtrada and p.estado = 'valida');
  get diagnostics v_retiradas = row_count;

  with p as (
    select distinct on (x.ref) x.ref, upper(x.code) as code, x.estado,
           coalesce(x.filtrada, false) as filtrada, x.filtrada_at
      from jsonb_to_recordset(coalesce(p_entradas, '[]'::jsonb))
           as x(ref uuid, code text, estado text, filtrada boolean, filtrada_at timestamptz)
     where x.ref is not null)
  insert into puerta_envio (organizador_id, evento_id, entrada_id, tipo, motivo)
  select e.organizador_id, e.evento_id, e.id, 'anular', 'filtro_seguridad'
    from p join entradas e on e.id = p.ref and e.code = p.code
   where e.estado = 'valida' and p.estado = 'valida' and p.filtrada
     and p.filtrada_at <= clock_timestamp() - v_espera
     and evento_espejo(e.evento_id)
  on conflict (tipo, entrada_id) do update set
    estado = 'pendiente', motivo = 'filtro_seguridad', proximo_at = clock_timestamp(),
    resultado = null, ultimo_error = null, actualizado_at = clock_timestamp()
   where puerta_envio.estado = 'cancelado';
  get diagnostics v_filtradas = row_count;

  with p as (
    select distinct on (x.ref) x.ref, upper(x.code) as code, x.estado,
           coalesce(x.filtrada, false) as filtrada
      from jsonb_to_recordset(coalesce(p_entradas, '[]'::jsonb))
           as x(ref uuid, code text, estado text, filtrada boolean)
     where x.ref is not null)
  update entradas e set estado = 'valida', used_at = null
    from p
   where e.id = p.ref and e.code = p.code and e.estado = 'usada' and e.portero_id is null
     and p.estado = 'valida' and not p.filtrada
     and evento_espejo(e.evento_id);
  get diagnostics v_devueltas = row_count;

  select count(*) filter (where e.estado = 'usada' and x.estado = 'anulada'),
         count(*) filter (where e.estado = 'anulada' and x.estado = 'usada'),
         count(*)
    into v_raras, v_raras2, v_n
    from jsonb_to_recordset(coalesce(p_entradas, '[]'::jsonb)) as x(ref uuid, estado text)
    left join entradas e on e.id = x.ref;

  perform set_config('ticketazo.puerta_sync', v_sync, true);
  return jsonb_build_object('recibidas', v_n,
    'usadas', v_usadas, 'anuladas', v_anuladas, 'devueltas', v_devueltas,
    'filtradas_a_anular', v_filtradas, 'filtro_retirado', v_retiradas,
    'usadas_aca_anuladas_alla', v_raras, 'anuladas_aca_usadas_alla', v_raras2);
end $$;
revoke execute on function puerta_aplicar_estados(jsonb) from public, anon, authenticated;
grant execute on function puerta_aplicar_estados(jsonb) to service_role;

-- El informe de cada corrida, para saber sin abrir logs si el espejo anda.
create or replace function puerta_registrar_corrida(p_informe jsonb)
returns void language sql security definer set search_path = public as $$
  update puerta_config set ultima_corrida_at = clock_timestamp(), ultima_corrida = p_informe
   where id
$$;
revoke execute on function puerta_registrar_corrida(jsonb) from public, anon, authenticated;
grant execute on function puerta_registrar_corrida(jsonb) to service_role;

-- ── 12. nuestra puerta no controla estas fechas ─────────────
--
-- Si un portero o el operador abre la puerta de TICKETAZO en un espejo, la
-- puerta tiene que andar —padrón vacío y un aviso al escanear—, no tirar
-- un error: un raise en padron_puerta deja al teléfono creyendo que no hay
-- señal, decidiendo "sin red" con un padrón viejo. Y marcar 'usada' acá
-- dejaría las dos bases en desacuerdo sobre quién entró.
-- Las tres son las definiciones vivas (0056/0032/0034) con el corte al
-- principio, después del chequeo de permiso y de tenant.

create or replace function padron_puerta(p_evento uuid) returns jsonb
  language plpgsql stable security definer set search_path = public as $function$
declare
  v_org uuid := mi_organizador();
  v_nombre text; v_fecha date;
  v_total int; v_lista jsonb;
  -- Tope de cordura. Con más que esto el teléfono no es el lugar: el
  -- padrón se guarda entero en el navegador y bajarlo por una antena de
  -- feria tarda. Se avisa con `truncado` en vez de devolver una lista
  -- corta en silencio, que es la falla que este archivo viene a evitar.
  v_tope int := 20000;
begin
  if not (es_portero() or puede_editar()) then raise exception 'Sin permiso'; end if;

  select nombre, fecha into v_nombre, v_fecha
    from eventos where id = p_evento and organizador_id = v_org;
  if not found then
    raise exception 'EVENTO_INEXISTENTE: ese evento no es tuyo.';
  end if;

  -- Espejo de Puerta (0103): la puerta es la de allá. Padrón vacío, con ok.
  if evento_espejo(p_evento) then
    return jsonb_build_object(
      'ok', true, 'evento', p_evento, 'nombre', v_nombre, 'fecha', v_fecha,
      'generado_at', now(), 'total', 0, 'truncado', false,
      'entradas', '[]'::jsonb, 'espejo', 'puerta');
  end if;

  select count(*) into v_total
    from entradas where organizador_id = v_org and evento_id = p_evento;

  select coalesce(jsonb_agg(f order by f->>'c'), '[]'::jsonb) into v_lista
    from (
      select jsonb_build_object(
               'c', e.code,
               'n', e.cliente,
               't', coalesce(t.nombre, case when e.mesa_id is not null then 'Mesa' end),
               'e', e.estado,
               'u', e.used_at) as f
        from entradas e
        left join tipo_entrada t on t.id = e.tipo_id
       where e.organizador_id = v_org and e.evento_id = p_evento
       order by e.code
       limit v_tope
    ) s;

  return jsonb_build_object(
    'ok', true,
    'evento', p_evento,
    'nombre', v_nombre,
    'fecha', v_fecha,
    'generado_at', now(),
    'total', v_total,
    'truncado', v_total > v_tope,
    'entradas', v_lista);
end $function$;

create or replace function validar_entrada(p_evento uuid, p_code text) returns jsonb
  language plpgsql security definer set search_path = public as $function$
declare v_code text := upper(trim(coalesce(p_code, '')));
        v_id uuid; v_estado text;
begin
  if not (es_portero() or puede_editar()) then raise exception 'Sin permiso'; end if;

  -- Espejo de Puerta (0103): no se marca nada acá. 'error' con motivo es el
  -- cartel "NO SE PUDO" con el porqué; no es corte de red, así que la
  -- puerta no cae a decidir con el padrón local.
  if evento_espejo(p_evento)
     and exists (select 1 from eventos where id = p_evento and organizador_id = mi_organizador()) then
    return jsonb_build_object('resultado', 'error', 'code', v_code,
      'motivo', 'Esta fecha se controla con el escáner de Plataforma Puerta, no con esta puerta.');
  end if;

  -- El update ES la pregunta. No hay select antes: entre el select y el
  -- update cabe el otro portero.
  update entradas
     set estado = 'usada', used_at = now(), portero_id = auth.uid()
   where organizador_id = mi_organizador()
     and evento_id = p_evento
     and code = v_code
     and estado = 'valida'
  returning id into v_id;

  if v_id is not null then
    -- `validada` o `reingreso` según si esta entrada ya había cruzado la
    -- puerta alguna vez. La consulta cae justo en puerta_bitacora_entrada_idx.
    -- No se guarda used_at_previo: el update exigió estado = 'valida', y una
    -- entrada válida no tiene ingreso que guardar — es lo que la palabra
    -- significa. Esas dos columnas existen para deshacer, que es la única
    -- acción que borra algo.
    insert into puerta_bitacora (organizador_id, evento_id, entrada_id, accion,
                                 actor_id, estado_previo)
    select mi_organizador(), p_evento, v_id,
           case when exists (select 1 from puerta_bitacora b
                              where b.entrada_id = v_id
                                and b.accion in ('validada','reingreso'))
                then 'reingreso' else 'validada' end,
           auth.uid(), 'valida';
    return puerta_entrada(p_evento, v_code, 'valida');
  end if;

  -- No volvió fila. Recién ahora se averigua por qué, y cada motivo se
  -- responde distinto. Nada de esto se anota: no cambió nada.
  select estado into v_estado from entradas
   where organizador_id = mi_organizador() and evento_id = p_evento and code = v_code;

  if v_estado is null then
    return jsonb_build_object('resultado', 'no_existe', 'code', v_code);
  end if;
  -- 'usada' se devuelve con used_at, que es la hora del PRIMER ingreso:
  -- la fila no se tocó, así que sigue siendo la del que sí entró.
  return puerta_entrada(p_evento, v_code, v_estado);
end $function$;

create or replace function marcar_filtro_entrada(p_evento uuid, p_code text) returns jsonb
  language plpgsql security definer set search_path = public as $function$
declare v_code text := upper(trim(coalesce(p_code, '')));
        v_id uuid; v_estado text; v_used timestamptz; v_portero uuid;
begin
  if not (es_portero() or puede_editar()) then raise exception 'Sin permiso'; end if;

  -- Espejo de Puerta (0103): el filtro de Seguridad de estas fechas es el
  -- de allá, y es el que anula. Anotarlo acá dejaría un rechazo que Puerta
  -- no conoce.
  if evento_espejo(p_evento)
     and exists (select 1 from eventos where id = p_evento and organizador_id = mi_organizador()) then
    return jsonb_build_object('resultado', 'error', 'code', v_code, 'filtro', true,
      'motivo', 'Esta fecha se controla con el escáner de Plataforma Puerta, no con esta puerta.');
  end if;

  select id, estado, used_at, portero_id into v_id, v_estado, v_used, v_portero
    from entradas
   where organizador_id = mi_organizador() and evento_id = p_evento and code = v_code;

  if v_estado is null then
    -- No hay entrada a la cual colgarle la fila. Un code inventado no es un
    -- rechazo que alguien vaya a auditar: es un tipeo.
    return jsonb_build_object('resultado', 'no_existe', 'code', v_code, 'filtro', true);
  end if;

  -- Sigue sin tocar `entradas`, que es lo que promete el nombre: la persona no
  -- entra y la manilla le queda buena. Lo que cambia es que ahora el rechazo
  -- existe en algún lado — antes se lo llevaba el aire y a la mañana no había
  -- forma de saber a quién se rechazó ni cuántas veces.
  insert into puerta_bitacora (organizador_id, evento_id, entrada_id, accion,
                               actor_id, estado_previo, used_at_previo, portero_previo)
  values (mi_organizador(), p_evento, v_id, 'rechazada',
          auth.uid(), v_estado, v_used, v_portero);

  -- Devuelve el estado real para que el portero sepa qué está rechazando,
  -- aunque afuera se vea el mismo cartel que una falsa.
  return puerta_entrada(p_evento, v_code, v_estado) || jsonb_build_object('filtro', true);
end $function$;

-- ── 13. el reloj ────────────────────────────────────────────
--
-- Mismo patrón que barrer_pagos (0054): pg_net, y la cabecera secreta
-- leída del vault en cada corrida, nunca escrita acá. Reusa
-- `barrido_clave` / BARRIDO_CLAVE: es el mismo tipo de llamada (un trabajo
-- interno, nadie de afuera) y así no hay un secreto más que cargar en dos
-- lados. Sin el secreto la función contesta 403 y no hace nada.
-- La apikey es la anon key, pública por diseño (la misma de 0054 y de
-- app/config.js); sola no abre nada.
select cron.unschedule(jobid) from cron.job where jobname = 'puerta_sync';

select cron.schedule('puerta_sync', '* * * * *', $cron$
  select net.http_post(
    url     := 'https://mjotxzcddhqqpuhkcetl.supabase.co/functions/v1/puerta-sync',
    headers := jsonb_build_object(
                 'Content-Type', 'application/json',
                 'apikey',       'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im1qb3R4emNkZGhxcXB1aGtjZXRsIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODc4NTk2NzMsImV4cCI6MjEwMzQzNTY3M30.yym969pECvbp_01-vM4d5QCVEvUV_kPUmNhtp51a0g0',
                 'x-barrido',    coalesce((select decrypted_secret from vault.decrypted_secrets
                                            where name = 'barrido_clave'), '')),
    body    := '{}'::jsonb,
    timeout_milliseconds := 20000)
$cron$);

-- ── control ─────────────────────────────────────────────────
select * from chequeo_funciones_sin_guardia();   -- tiene que devolver vacío
