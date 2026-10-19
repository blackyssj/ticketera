-- ============================================================
-- 0108 — mesas v2: la mesa es una compra aparte, a nombre de quien
-- paga, con un recibo que NO es una entrada
--
-- Lo que pidió el dueño el 19/10 después de ver 0107 andando:
--
--   · La mesa y las entradas son dos compras distintas. Con 0107 iban en
--     el mismo carrito y la orden tenía un titular que podía no ser el
--     comprador; en la puerta eso terminaba en "¿y quién es Juana?".
--     Ahora quien paga ES el titular: nombre, carnet y correo.
--   · Una mesa por PERSONA y por evento, de cualquier tipo. 0107 decía
--     "una por compra", y con dos compras se tenían dos mesas.
--   · Una mesa puede no incluir entradas (hay locales que venden la mesa
--     y cada invitado paga su entrada). Hasta acá la base exigía al menos
--     una manilla por unidad.
--   · El QR de la mesa no deja entrar: abre un recibo. El guardia ve tipo,
--     lo que incluye, nombre, carnet y correo, y que ya se presentó si
--     alguien lo vuelve a mostrar. Para entrar se usa una entrada; las que
--     vienen con la mesa dicen de qué mesa son.
--   · La comisión del relacionador, separada: entradas, mesas y total.
--   · Un tablero de mesas y una lista de compradores de mesas, aparte de
--     la de entradas.
--
-- ── por qué el recibo vive en su tabla y no en `entradas` ──
-- Lo obvio era una fila más en `entradas` con una marca. Se descartó:
-- cuarenta funciones, el panel (que lee `entradas` directo para la tabla
-- "Por fase"), las Edge Functions y el correo cuentan esas filas como
-- manillas. Cada una que no se enterara de la marca contaría el recibo
-- como alguien que entra, y una de esas cuentas es la comisión (que es
-- plata). En `mesa_recibos` nada de lo que ya existe lo ve, y lo nuevo
-- lo pide por su nombre.
--
-- El código del recibo empieza con MESA. Los de `entradas` salen de un
-- alfabeto sin vocales (0007), así que nunca empiezan así: la puerta
-- sabe qué tiene enfrente con mirar el código, con señal o sin ella, y
-- los dos espacios de códigos no pueden chocar. El QR es el mismo
-- `EVT:<evento>:<code>` de siempre, para que el escáner lo lea sin otro
-- formato; lo que cambia es la respuesta.
--
-- ── qué pasa con lo que ya existe ──
-- Al escribir esto no había en producción ningún tipo 'mesa', ninguna
-- orden con titular ni ítems de mesa (consulta de solo lectura del
-- 19/10). No hay datos que migrar: cada cambio se activa recién con la
-- primera mesa. Para un evento sin mesas, compras, comisiones, padrón y
-- puerta devuelven exactamente lo de antes.
-- ============================================================

-- Toca `ordenes` (índices) y `tipo_entrada` (CHECK), que son del
-- checkout. Si una consulta larga las tiene tomadas, mejor fallar a los
-- 15 s y reintentar que dejar la venta esperando detrás del ALTER.
set local lock_timeout = '15s';

-- ── 1. una mesa puede incluir 0 entradas ────────────────────
-- El CHECK de 0004 venía en la columna y Postgres le puso nombre solo
-- (tipo_entrada_manillas_check). Se busca por lo que dice y no por ese
-- nombre: si alguna base lo tiene con otro, igual se va, y nunca quedan
-- dos reglas que se contradicen. El 0 queda SOLO para una mesa: una
-- entrada que no deja entrar a nadie no es un producto, es un error de
-- carga.
do $$
declare c record;
begin
  for c in select conname from pg_constraint
            where conrelid = 'public.tipo_entrada'::regclass and contype = 'c'
              and conname <> 'tipo_entrada_manillas_ck'
              and pg_get_constraintdef(oid) ~ '\mmanillas\M'
  loop
    execute format('alter table tipo_entrada drop constraint %I', c.conname);
  end loop;
  if not exists (select 1 from pg_constraint where conname = 'tipo_entrada_manillas_ck') then
    alter table tipo_entrada add constraint tipo_entrada_manillas_ck
      check (manillas >= 1 or (manillas = 0 and categoria = 'mesa')) not valid;
  end if;
end $$;
-- Todo lo que existe tiene manillas >= 1: valida en el acto.
alter table tipo_entrada validate constraint tipo_entrada_manillas_ck;

comment on column tipo_entrada.manillas is
  'Cuántas entradas emite una unidad de este tipo. 0 solo en una mesa (0108): la mesa no incluye entradas y cada invitado compra la suya.';

-- ── 2. el recibo de la mesa ─────────────────────────────────
-- Uno por mesa vendida, y como una orden con mesa lleva UNA sola mesa
-- (crear_orden), uno por orden: unique(orden_id) es la misma regla dicha
-- por la tabla.
--
-- tipo_nombre, incluye y entradas_incluidas se copian al emitir: un
-- recibo dice lo que se compró. Si el organizador corrige "Incluye"
-- después de vender, el recibo de quien ya pagó no cambia solo.
--
-- El titular NO se copia: está en la orden (0107) y una copia es otro
-- lugar donde un carnet puede quedar distinto. El estado tampoco: un
-- recibo vale mientras su orden esté pagada. anular_orden ya deja la
-- orden 'anulada' y con eso el recibo se lee anulado en el panel, en la
-- puerta y en el padrón, sin tocar esa función.
create table if not exists mesa_recibos (
  id                 uuid primary key default gen_random_uuid(),
  organizador_id     uuid not null references organizadores on delete restrict,
  evento_id          uuid not null references eventos on delete cascade,
  orden_id           uuid not null references ordenes on delete restrict,
  tipo_id            uuid not null references tipo_entrada on delete restrict,
  code               text not null,
  tipo_nombre        text not null,
  incluye            text,
  entradas_incluidas int  not null,
  -- La primera vez que se mostró en la puerta. No es un ingreso: es lo
  -- que deja decir "ya se presentó a las 23:40" si alguien lo muestra de
  -- nuevo (una captura reenviada, otra persona con el mismo correo).
  presentado_at      timestamptz,
  presentado_por     uuid references perfiles(id),
  created_at         timestamptz not null default now(),
  constraint mesa_recibos_code_ck check (code ~ '^MESA[23456789BCDFGHJKLMNPQRSTVWXZ]{8}$'),
  constraint mesa_recibos_entradas_ck check (entradas_incluidas >= 0),
  unique (evento_id, code),
  unique (orden_id)
);
create index if not exists mesa_recibos_tipo_idx on mesa_recibos (tipo_id);

-- Nadie la lee directo: el panel, la puerta y las Edge Functions pasan
-- por funciones que deciden quién ve qué (el carnet completo es dato de
-- un tercero). Sin policies a propósito.
alter table mesa_recibos enable row level security;
revoke all on mesa_recibos from anon, authenticated;
grant select, insert, update, delete on mesa_recibos to service_role;

comment on table mesa_recibos is
  'El recibo de cada mesa vendida (0108): su QR (EVT:<evento>:MESA…) abre el recibo en la puerta y NUNCA marca un ingreso. Vale mientras su orden esté pagada. tipo_nombre, incluye y entradas_incluidas son lo vendido, congelado al emitir.';

-- ── 3. una mesa por carnet y por evento ─────────────────────
-- El índice parcial es para buscar rápido las órdenes con mesa de un
-- carnet (solo las órdenes con mesa tienen titular, 0107). El único es el
-- tope de la base: dos órdenes PAGADAS con mesa del mismo carnet en el
-- mismo evento no pueden existir aunque algún camino se olvide de
-- preguntar. Las pendientes no pueden ir en un índice (vencen con el
-- reloj, y now() no entra en un índice): esas las frena crear_orden con
-- un candado. Al aplicar esto no hay ninguna fila con titular: los dos
-- se arman sobre nada.
create index if not exists ordenes_mesa_ci_idx
  on ordenes (evento_id, titular_ci) where titular_ci is not null;
create unique index if not exists ordenes_mesa_ci_pagada_uq
  on ordenes (evento_id, titular_ci) where titular_ci is not null and estado = 'pagada';

-- ── 4. crear_orden: la mesa sola, a nombre de quien paga, una por carnet ──
-- El cuerpo vivo de 0107 con los cambios marcados 0108:
--   a) una orden con mesa no lleva nada más (MESA_SOLA). Antes una General
--      podía ir en la misma compra.
--   b) el titular ES el comprador: nombre (el del comprador), carnet y
--      correo obligatorios. Se acepta el carnet como `ci`/`ci_ext` (lo
--      nuevo) o como `titular_ci`/`titular_ci_ext` (lo que manda el front
--      de 0107 hasta que se recargue); el nombre de `titular_nombre`, si
--      viene, se ignora.
--   c) una mesa por carnet y por evento, contando pagadas, en revisión y
--      pendientes vivas. Con un candado por (evento, carnet) para que dos
--      compras simultáneas no pasen las dos el chequeo.
-- La client_key sigue yendo primero: un reintento de una orden que ya
-- existe la devuelve tal cual, sin volver a validar nada.
create or replace function crear_orden(
  p_evento uuid, p_items jsonb, p_comprador jsonb default '{}'::jsonb,
  p_client_key uuid default null, p_ip_hash text default null,
  p_rrpp uuid default null
) returns jsonb
  language plpgsql volatile security definer set search_path = public as $function$
declare
  v_org uuid; v_fase uuid; v_tope int; v_estado text; v_org_row organizadores;
  v_orden uuid; v_sub numeric(12,2) := 0; v_fee numeric(12,2); v_entradas int := 0;
  v_precio_publico numeric(12,2);
  v_it jsonb; v_tipo uuid; v_mesa uuid; v_cant int;
  v_precio numeric(12,2); v_cupo int; v_disp int; v_n int; v_pend int;
  v_mesas int; v_cupo_total int;
  v_tit_nombre text; v_tit_ci text; v_tit_ext text;
  v_comprador text; v_email text; v_choque text;
begin
  select organizador_id, estado, tope_entradas_orden
    into v_org, v_estado, v_tope from eventos where id = p_evento;
  if not found then raise exception 'EVENTO_INEXISTENTE: %', p_evento; end if;
  if v_estado <> 'publicado' then raise exception 'EVENTO_NO_PUBLICADO: %', p_evento; end if;

  if p_client_key is not null then
    select id into v_orden from ordenes where client_key = p_client_key;
    if found then
      return (select jsonb_build_object('ok', true, 'orden', o.id, 'subtotal', o.subtotal,
                                        'fee', o.fee, 'total', o.total, 'repetida', true)
                from ordenes o where o.id = v_orden);
    end if;
  end if;

  if p_ip_hash is not null then
    select count(*) into v_pend from ordenes
     where ip_hash = p_ip_hash and estado = 'pendiente' and expira_at > now();
    if v_pend >= 5 then raise exception 'DEMASIADAS_ORDENES: % pendientes desde esta IP', v_pend; end if;
  end if;

  select * into v_org_row from organizadores where id = v_org;
  v_fase := fase_vigente(p_evento);

  -- 0107: cuántas mesas trae. Unidades de tipos 'mesa' de este evento, más
  -- las del camino viejo por mesa_id (la mesa física), que también son
  -- una reserva a nombre de alguien y no pueden ser la puerta de atrás.
  select coalesce(sum(case when nullif(x->>'mesa_id', '') is not null then 1
                           else coalesce((x->>'cantidad')::int, 1) end), 0)
    into v_mesas
    from jsonb_array_elements(p_items) x
    left join tipo_entrada t on t.id = nullif(x->>'tipo_id', '')::uuid
                            and t.evento_id = p_evento
   where nullif(x->>'mesa_id', '') is not null or t.categoria = 'mesa';

  if v_mesas > 1 then
    raise exception 'UNA_MESA: una mesa por compra y se pidieron %', v_mesas;
  end if;
  -- 0108 a) La mesa se compra sola. Con algo más al lado, la orden mezcla
  -- una reserva a nombre de alguien con entradas sueltas, y el recibo, la
  -- lista de compradores y la comisión tendrían que partirla en dos.
  if v_mesas = 1 and jsonb_array_length(p_items) > 1 then
    raise exception 'MESA_SOLA: la mesa se compra sola; las entradas van en otra compra';
  end if;

  v_comprador := p_comprador->>'nombre';
  if v_mesas = 1 then
    -- 0108 b) El titular es quien paga. Se normaliza acá aunque
    -- crear-orden ya lo haga: la base no confía en quien la llama, y los
    -- CHECK de `ordenes` exigen esta forma exacta.
    v_tit_nombre := btrim(left(regexp_replace(btrim(coalesce(p_comprador->>'nombre', '')),
                                              '\s+', ' ', 'g'), 80));
    v_tit_ci := regexp_replace(upper(regexp_replace(
                  coalesce(nullif(btrim(p_comprador->>'ci'), ''), p_comprador->>'titular_ci', ''),
                  '[\s.]', '', 'g')), '^-+|-+$', '', 'g');
    v_tit_ext := nullif(upper(btrim(coalesce(nullif(btrim(p_comprador->>'ci_ext'), ''),
                                             p_comprador->>'titular_ci_ext', ''))), '');
    -- Los alias que la gente escribe: Beni con E, Pando con A o N.
    v_tit_ext := case v_tit_ext when 'BE' then 'BN' when 'PA' then 'PD' when 'PN' then 'PD'
                                else v_tit_ext end;
    if v_tit_nombre !~ '^\S+( \S+)+$' or v_tit_ci = '' then
      raise exception 'FALTA_TITULAR: la mesa va a nombre de quien la compra: falta su nombre y apellido o su carnet';
    end if;
    -- El carnet no va en el mensaje: los errores terminan en logs.
    if v_tit_ci !~ '^(E-)?[0-9]{5,10}(-[0-9A-Z]{2})?$'
       or (v_tit_ext is not null
           and v_tit_ext not in ('LP','CB','SC','OR','PT','CH','TJ','BN','PD')) then
      raise exception 'CI_INVALIDO: el carnet del titular no tiene un formato valido';
    end if;
    -- El QR de la mesa y el recibo llegan por correo: sin correo no hay
    -- a dónde mandarlos.
    v_email := btrim(coalesce(p_comprador->>'email', ''));
    if v_email !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]{2,}$' then
      raise exception 'FALTA_CORREO: a la mesa le llegan el QR y el recibo por correo';
    end if;
    v_comprador := v_tit_nombre;

    -- 0108 c) Una mesa por carnet y por evento. El candado va por (evento,
    -- carnet) y no por evento: dos personas distintas compran a la vez sin
    -- esperarse. Es de transacción: se suelta al confirmar, cuando la orden
    -- nueva ya es visible para la compra que estaba esperando. La extensión
    -- NO entra en la cuenta: es opcional, y con ella adentro alcanzaba con
    -- escribirla en una compra y no en la otra.
    perform pg_advisory_xact_lock(hashtextextended('mesa:' || p_evento::text || ':' || v_tit_ci, 0));

    -- El que vuelve atrás y elige OTRA mesa antes de pagar es la misma
    -- persona, no una segunda mesa: su reserva anterior se da por vencida
    -- y sigue. Solo si es su correo y si esa reserva nunca llegó a la
    -- pasarela (pago_ref null): una que ya tiene QR de cobro puede estar
    -- pagándose en este momento.
    update ordenes set estado = 'vencida'
     where evento_id = p_evento and titular_ci = v_tit_ci
       and estado = 'pendiente' and expira_at > now()
       and pago_ref is null
       and lower(btrim(coalesce(comprador_email, ''))) = lower(v_email);

    select estado into v_choque from ordenes
     where evento_id = p_evento and titular_ci = v_tit_ci
       and (estado in ('pagada', 'revision_manual')
            or (estado = 'pendiente' and expira_at > now()))
     order by case estado when 'pagada' then 1 when 'revision_manual' then 2 else 3 end
     limit 1;
    if v_choque in ('pagada', 'revision_manual') then
      raise exception 'YA_TIENE_MESA: ese carnet ya tiene una mesa en este evento';
    elsif v_choque = 'pendiente' then
      raise exception 'MESA_EN_CURSO: ese carnet tiene una reserva de mesa esperando el pago';
    end if;
  else
    -- Sin mesa no hay titular, aunque el navegador mande uno.
    v_tit_nombre := null; v_tit_ci := null; v_tit_ext := null;
  end if;

  insert into ordenes (organizador_id, evento_id, client_key, expira_at,
                       comprador_nombre, comprador_email, comprador_telefono,
                       subtotal, fee, total, ip_hash, rrpp_id,
                       titular_nombre, titular_ci, titular_ci_ext)
  values (v_org, p_evento, p_client_key, now() + interval '10 minutes',
          v_comprador, p_comprador->>'email', p_comprador->>'telefono',
          0, 0, 0, p_ip_hash, p_rrpp,
          v_tit_nombre, v_tit_ci, v_tit_ext)
  returning id into v_orden;

  for v_it in select * from jsonb_array_elements(p_items) loop
    v_tipo := nullif(v_it->>'tipo_id','')::uuid;
    v_mesa := nullif(v_it->>'mesa_id','')::uuid;
    v_cant := coalesce((v_it->>'cantidad')::int, 1);
    if (v_tipo is null) = (v_mesa is null) then
      raise exception 'ITEM_INVALIDO: cada item lleva tipo_id o mesa_id, no los dos ni ninguno';
    end if;

    if v_tipo is not null then
      if v_fase is null then raise exception 'SIN_FASE: el evento no tiene fase abierta'; end if;
      if v_cant < 1 then raise exception 'ITEM_INVALIDO: cantidad %', v_cant; end if;
      -- 0107 c) Con tope de evento, dos compras de la misma mesa en fases
      -- distintas no se cruzan en el candado del precio (es otra fila de
      -- fase_precio). Se toma la fila del tipo ANTES que la del precio, en
      -- el mismo orden que guardar_mesa, para no armar un abrazo mortal.
      -- NO KEY UPDATE y no UPDATE: no choca con el FOR KEY SHARE que toman
      -- los inserts de entradas y orden_items al chequear la FK.
      select cupo_total into v_cupo_total from tipo_entrada where id = v_tipo;
      if v_cupo_total is not null then
        perform 1 from tipo_entrada where id = v_tipo for no key update;
      end if;
      select fp.precio, fp.cupo into v_precio, v_cupo
        from fase_precio fp join tipo_entrada te on te.id = fp.tipo_id
       where fp.fase_id = v_fase and fp.tipo_id = v_tipo and te.activo
       for update of fp;
      if not found then raise exception 'TIPO_NO_VENDIBLE: ese tipo no se vende en la fase abierta'; end if;
      if v_cupo is not null or v_cupo_total is not null then
        v_disp := disponibilidad_tipo(v_fase, v_tipo);
        if v_disp < v_cant then raise exception 'SIN_CUPO: quedan % y se pidieron %', v_disp, v_cant; end if;
      end if;
      insert into orden_items (organizador_id, orden_id, tipo_id, fase_id, cantidad, precio_unitario)
      values (v_org, v_orden, v_tipo, v_fase, v_cant, v_precio);
      v_sub := v_sub + v_precio * v_cant;
      v_entradas := v_entradas + v_cant;
    else
      update mesas set estado = 'bloqueada', orden_id = v_orden, updated_at = now()
       where id = v_mesa and evento_id = p_evento and estado = 'disponible'
      returning precio into v_precio;
      get diagnostics v_n = row_count;
      if v_n = 0 then raise exception 'MESA_TOMADA: la mesa % ya no esta disponible', v_mesa; end if;
      insert into orden_items (organizador_id, orden_id, mesa_id, cantidad, precio_unitario)
      values (v_org, v_orden, v_mesa, 1, v_precio);
      v_sub := v_sub + v_precio;
    end if;
  end loop;

  if v_sub = 0 and v_entradas = 0 then raise exception 'ORDEN_VACIA: no se pidio nada'; end if;
  if v_entradas > v_tope then raise exception 'TOPE: % entradas, el maximo es %', v_entradas, v_tope; end if;

  -- Sin nada que cobrar no hay cargo por servicio (0046).
  if v_sub = 0 then
    v_fee := 0;
    -- 0108: sin esto un precio_publico nulo rompía el update de abajo
    -- (total not null) en cuanto algo de Bs 0 llegaba hasta acá.
    v_precio_publico := 0;
  elsif v_org_row.comision_modo = 'adentro' then
    /* El precio publicado es lo que paga el comprador, y de ahí sale
       nuestra parte. Se redondea a centavos y no a bolivianos enteros
       como en el otro modo: ahí el redondeo lo absorbe el comprador —un
       peso más en el total— y acá lo absorbería el organizador, que es
       de quien estamos descontando. */
    v_fee := least(
      greatest(round(v_sub * v_org_row.fee_pct, 2) + v_org_row.fee_fijo_transaccion,
               v_org_row.fee_piso),
      v_sub);   -- nunca más que el precio: un cargo mayor deja al organizador debiendo
    v_precio_publico := v_sub;
    v_sub := round(v_sub - v_fee, 2);
  else
    v_fee := greatest(round(v_sub * v_org_row.fee_pct) + v_org_row.fee_fijo_transaccion,
                      v_org_row.fee_piso);
    v_precio_publico := v_sub + v_fee;
  end if;

  /* `subtotal` significa siempre LO DEL ORGANIZADOR y `total` siempre LO
     QUE PAGA EL COMPRADOR, en los dos modos. Esa invariante es lo que deja
     intacto todo lo de abajo —liquidacion, disponible_de, el cierre— sin
     que ninguno tenga que preguntar en qué modo está el organizador. Lo
     único que cambia entre modos es de dónde sale cada uno. */
  update ordenes set subtotal = v_sub, fee = v_fee, total = v_precio_publico
   where id = v_orden;

  return jsonb_build_object('ok', true, 'orden', v_orden, 'subtotal', v_sub,
                            'fee', v_fee, 'total', v_precio_publico, 'repetida', false);
end $function$;

revoke execute on function crear_orden(uuid, jsonb, jsonb, uuid, text, uuid) from anon, public, authenticated;

comment on function crear_orden(uuid, jsonb, jsonb, uuid, text, uuid) is
  'Crea la orden y congela los precios. Segun organizadores.comision_modo el cargo por servicio se le suma al comprador o sale de adentro del precio; en los dos casos subtotal queda siendo lo del organizador, fee lo de TICKETAZO y total lo que se cobra. Una orden con mesa lleva esa mesa sola (MESA_SOLA, UNA_MESA) y va a nombre del comprador: p_comprador trae nombre y apellido, ci, ci_ext opcional y email (FALTA_TITULAR / CI_INVALIDO / FALTA_CORREO). Una mesa por carnet y por evento contando pagadas, en revision y pendientes vivas (YA_TIENE_MESA / MESA_EN_CURSO); la reserva sin pagar del mismo carnet y correo se reemplaza (0108).';

-- ── 5. emitir_orden: la mesa emite su recibo y sus entradas, de 0 a N ──
-- El cuerpo vivo de 0038 (la última definición; 0051 le dejó el execute
-- solo a service_role) con tres cambios marcados 0108:
--   a) una mesa de 0 entradas no emite ninguna y la orden queda pagada
--      igual. `greatest(manillas, 1)` estaba para que un tipo mal cargado
--      no dejara una compra cobrada sin entradas; ese papel ahora lo
--      cumple el CHECK de manillas, que solo deja el 0 en una mesa.
--   b) cada mesa emite su recibo (mesa_recibos), con lo vendido congelado.
--   c) una mesa por carnet también al emitir. crear_orden ya lo frenó al
--      reservar, pero una reserva vencida puede pagarse igual: barrer-pagos
--      rescata durante tres días las 'vencida' que la pasarela da por
--      cobradas (0041). Si para entonces ese carnet ya tiene otra mesa
--      pagada, esta no se emite: queda en revisión manual con la plata
--      anotada, y una persona decide (anularla y devolver, o anular la
--      otra). Emitirla sería la segunda mesa que el dueño pidió que no
--      exista; el índice único de arriba es el que lo garantiza si algún
--      camino se olvidara de preguntar.
-- El candado del carnet se toma ANTES que el de la fila, en el mismo orden
-- que crear_orden (candado y después update de la reserva reemplazada):
-- al revés, una compra y una emisión del mismo carnet se trababan.
create or replace function emitir_orden(
  p_orden uuid, p_monto_cobrado numeric default null, p_pago_ref text default null,
  p_desde_revision boolean default false
) returns jsonb
  language plpgsql volatile security definer set search_path = public as $function$
declare o ordenes; v_n int; v_it record; i int; v_manillas int; v_canal text;
        v_t tipo_entrada; v_ci text; v_ev uuid; v_recibo text;
begin
  select titular_ci, evento_id into v_ci, v_ev from ordenes where id = p_orden;
  if v_ci is not null then
    perform pg_advisory_xact_lock(hashtextextended('mesa:' || v_ev::text || ':' || v_ci, 0));
  end if;

  select * into o from ordenes where id = p_orden for update;
  if not found then raise exception 'ORDEN_INEXISTENTE: %', p_orden; end if;

  if o.estado = 'pagada' then
    select count(*) into v_n from entradas where orden_id = p_orden;
    return jsonb_build_object('ok', true, 'orden', p_orden, 'entradas', v_n, 'repetida', true,
                              'recibo', (select code from mesa_recibos where orden_id = p_orden));
  end if;
  if o.estado = 'anulada' then
    return jsonb_build_object('ok', false, 'motivo', 'ANULADA');
  end if;
  if o.estado = 'revision_manual' and not coalesce(p_desde_revision, false) then
    return jsonb_build_object('ok', false, 'motivo', 'REVISION_MANUAL');
  end if;

  -- Solo una reserva viva puede vencer. Una orden en revisión resuelta ya
  -- pasó por caja: su expira_at es historia, no una regla.
  if o.estado = 'pendiente' and o.expira_at <= now() then
    update ordenes set estado = 'vencida' where id = p_orden and estado = 'pendiente';
    return jsonb_build_object('ok', false, 'motivo', 'VENCIDA');
  end if;

  if p_monto_cobrado is not null and p_monto_cobrado <> o.total then
    update ordenes set estado = 'revision_manual', pago_ref = coalesce(p_pago_ref, pago_ref),
                       monto_cobrado = p_monto_cobrado
     where id = p_orden;
    return jsonb_build_object('ok', false, 'motivo', 'MONTO',
                              'esperado', o.total, 'cobrado', p_monto_cobrado);
  end if;

  -- 0108 c) Otra mesa pagada del mismo carnet en este evento. Va también
  -- cuando la confirma una persona desde la revisión: para quedarse con
  -- esta, primero hay que anular la otra.
  if o.titular_ci is not null and exists (
       select 1 from ordenes x
        where x.evento_id = o.evento_id and x.titular_ci = o.titular_ci
          and x.id <> o.id and x.estado = 'pagada') then
    update ordenes set estado = 'revision_manual', pago_ref = coalesce(p_pago_ref, pago_ref),
                       monto_cobrado = coalesce(p_monto_cobrado, monto_cobrado)
     where id = p_orden;
    return jsonb_build_object('ok', false, 'motivo', 'MESA_DUPLICADA');
  end if;

  -- Se decide una vez, antes del bucle: todas las entradas de una orden
  -- vienen del mismo lugar.
  v_canal := case when o.rrpp_id is not null then 'rrpp' else 'publico' end;

  for v_it in select * from orden_items where orden_id = p_orden loop
    if v_it.tipo_id is not null then
      select * into v_t from tipo_entrada where id = v_it.tipo_id;
      -- cuánta gente entra con UNA unidad de este tipo. 0108 a): una mesa
      -- puede decir 0 y el bucle de abajo no da vueltas.
      v_manillas := case when v_t.categoria = 'mesa' then greatest(coalesce(v_t.manillas, 0), 0)
                         else greatest(coalesce(v_t.manillas, 1), 1) end;
      for i in 1 .. (v_it.cantidad * v_manillas) loop
        insert into entradas (organizador_id, evento_id, orden_id, code, canal,
                              tipo_id, fase_id, rrpp_id, cliente, precio)
        values (o.organizador_id, o.evento_id, p_orden, nuevo_code(), v_canal,
                v_it.tipo_id, v_it.fase_id, o.rrpp_id, o.comprador_nombre,
                v_it.precio_unitario);
      end loop;

      -- 0108 b) El recibo. MESA + ocho del mismo alfabeto que las
      -- entradas: no choca con ninguna entrada (esas no llevan vocales) y
      -- se reintenta en el rarísimo caso de repetir uno del mismo evento.
      if v_t.categoria = 'mesa' then
        loop
          v_recibo := 'MESA' || left(nuevo_code(), 8);
          exit when not exists (select 1 from mesa_recibos
                                 where evento_id = o.evento_id and code = v_recibo);
        end loop;
        insert into mesa_recibos (organizador_id, evento_id, orden_id, tipo_id, code,
                                  tipo_nombre, incluye, entradas_incluidas)
        values (o.organizador_id, o.evento_id, p_orden, v_t.id, v_recibo,
                v_t.nombre, v_t.incluye, v_manillas);
      end if;
    else
      insert into entradas (organizador_id, evento_id, orden_id, code, canal,
                            mesa_id, rrpp_id, cliente, precio)
      select o.organizador_id, o.evento_id, p_orden, nuevo_code(), v_canal,
             m.id, o.rrpp_id, o.comprador_nombre, 0
        from mesas m, generate_series(1, m.manillas) where m.id = v_it.mesa_id;
      update mesas set estado = 'pagada', updated_at = now() where id = v_it.mesa_id;
    end if;
  end loop;

  update ordenes set estado = 'pagada', pagada_at = now(),
                     pago_ref = coalesce(p_pago_ref, pago_ref)
   where id = p_orden;
  select count(*) into v_n from entradas where orden_id = p_orden;
  return jsonb_build_object('ok', true, 'orden', p_orden, 'entradas', v_n, 'repetida', false,
                            'recibo', v_recibo);
end $function$;
-- Los mismos permisos que dejó 0051: sin grant a authenticated, porque la
-- emisión la disparan las Edge Functions; un admin con execute emitiría
-- cualquier orden sin que se cobre nada.
revoke execute on function emitir_orden(uuid, numeric, text, boolean) from public, anon, authenticated;
grant execute on function emitir_orden(uuid, numeric, text, boolean) to service_role;

comment on function emitir_orden(uuid, numeric, text, boolean) is
  'Emite las entradas de una orden y la deja pagada. Idempotente: repetirla no duplica nada. Se niega con VENCIDA si la reserva expiro sin pagarse, con MONTO si la pasarela cobro otra cifra (y ahi la manda a revision_manual guardando monto_cobrado), con MESA_DUPLICADA si el carnet ya tiene otra mesa pagada en el evento (tambien a revision_manual), y con REVISION_MANUAL o ANULADA segun el estado. Una mesa emite su recibo (mesa_recibos, devuelto en `recibo`) y de 0 a N entradas (0108). Sin grant a authenticated: la llaman las Edge Functions con service_role.';

-- ── 6. guardar_mesa: de 0 a 50 entradas incluidas ───────────
-- El cuerpo vivo de 0107 con dos cambios marcados 0108: `personas` (cuántas
-- entradas incluye) arranca en 0, y el aviso de MESA_CON_VENTAS dice "sin
-- entradas" en vez de "con 0 personas". Lo demás, letra por letra.
create or replace function guardar_mesa(p_evento uuid, p_tipo uuid, p_datos jsonb) returns jsonb
  language plpgsql volatile security definer set search_path = public as $function$
declare
  v_org uuid := mi_organizador();
  v_t tipo_entrada;
  v_nombre text; v_desc text; v_incluye text;
  v_personas int; v_precio numeric(12,2); v_cantidad int; v_comision numeric(12,2);
  v_fases uuid[]; v_malas int; v_id uuid; v_tocar_precio boolean;
begin
  if not puede_editar() then raise exception 'Sin permiso'; end if;
  -- El mismo mensaje para "no es tuyo" que para "no existe": si no, esta
  -- función diría qué uuids hay en la base del vecino.
  if v_org is null or not exists (select 1 from eventos
                                   where id = p_evento and organizador_id = v_org) then
    raise exception 'No encontramos ese evento';
  end if;
  if evento_espejo(p_evento) then
    return jsonb_build_object('ok', false, 'motivo',
      'Las mesas de este evento se venden en Plataforma Puerta. Acá no se cargan.');
  end if;

  if p_tipo is not null then
    select * into v_t from tipo_entrada
     where id = p_tipo and evento_id = p_evento and organizador_id = v_org;
    if not found then raise exception 'No encontramos esa mesa'; end if;
    if v_t.categoria <> 'mesa' then
      return jsonb_build_object('ok', false, 'motivo',
        'Ese producto se vende como entrada, no como mesa. Creá la mesa aparte.');
    end if;
  end if;

  begin
    v_nombre   := btrim(regexp_replace(coalesce(p_datos->>'nombre', ''), '\s+', ' ', 'g'));
    v_desc     := nullif(btrim(coalesce(p_datos->>'descripcion', '')), '');
    v_incluye  := nullif(btrim(coalesce(p_datos->>'incluye', '')), '');
    v_personas := (p_datos->>'personas')::int;
    v_precio   := (p_datos->>'precio')::numeric(12,2);
    v_cantidad := nullif(btrim(coalesce(p_datos->>'cantidad', '')), '')::int;
    v_comision := nullif(btrim(coalesce(p_datos->>'comision', '')), '')::numeric(12,2);
    -- Sin el dato, como antes: el precio va a todas las fases marcadas.
    -- El panel lo manda en false cuando el organizador no tocó el precio.
    v_tocar_precio := coalesce((p_datos->>'tocar_precio')::boolean, true);
    if jsonb_typeof(p_datos->'fases') = 'array' then
      select coalesce(array_agg(distinct x::uuid), '{}') into v_fases
        from jsonb_array_elements_text(p_datos->'fases') x;
    end if;
  exception when others then
    return jsonb_build_object('ok', false, 'motivo',
      'Revisá los números: entradas, precio, cantidad y comisión van en cifras.');
  end;

  if char_length(v_nombre) not between 2 and 60 then
    return jsonb_build_object('ok', false, 'motivo', 'Poné un nombre de 2 a 60 letras.');
  end if;
  if char_length(coalesce(v_desc, '')) > 220 or char_length(coalesce(v_incluye, '')) > 220 then
    return jsonb_build_object('ok', false, 'motivo',
      'La frase y lo que incluye van de hasta 220 letras cada una.');
  end if;
  -- 0108: 0 es una mesa que no incluye entradas. Vacío sigue siendo un
  -- error: "no dijo" y "no incluye" no son lo mismo.
  if v_personas is null or v_personas not between 0 and 50 then
    return jsonb_build_object('ok', false, 'motivo',
      'Cuántas entradas incluye la mesa: de 0 a 50. Poné 0 si no incluye entradas.');
  end if;
  if v_precio is null or v_precio < 0 or v_precio > 1000000 then
    return jsonb_build_object('ok', false, 'motivo', 'Poné el precio en Bs (0 si es gratis).');
  end if;
  if v_cantidad is not null and v_cantidad not between 1 and 10000 then
    return jsonb_build_object('ok', false, 'motivo',
      'Cuántas hay: dejalo vacío si no hay tope, o poné de 1 a 10000.');
  end if;
  if v_comision is not null and (v_comision < 0 or v_comision > 100000) then
    return jsonb_build_object('ok', false, 'motivo',
      'La comisión por mesa va en Bs, desde 0. Vacía usa la de cada relacionador.');
  end if;

  -- Sin fases elegidas: todas las activas del evento, que es lo que quiere
  -- casi siempre el que crea una mesa — si la fase avanza y la mesa no
  -- tiene precio en la nueva, desaparece de la página sin avisar.
  if v_fases is null then
    select coalesce(array_agg(id), '{}') into v_fases
      from evento_fase where evento_id = p_evento and activo;
  end if;
  select count(*) into v_malas from unnest(v_fases) f
   where not exists (select 1 from evento_fase ef where ef.id = f and ef.evento_id = p_evento);
  if v_malas > 0 then
    return jsonb_build_object('ok', false, 'motivo', 'Alguna de las fases no es de este evento.');
  end if;

  -- emitir_orden lee las entradas del tipo al EMITIR (0038): cambiarlas con
  -- compras hechas cambiaría cuántas recibe una orden que ya se vendió con
  -- otra cantidad. Antes de que haya ventas, se cambia libre.
  if p_tipo is not null and v_personas <> v_t.manillas
     and (exists (select 1 from orden_items where tipo_id = p_tipo)
          or exists (select 1 from entradas where evento_id = p_evento and tipo_id = p_tipo)) then
    return jsonb_build_object('ok', false, 'codigo', 'MESA_CON_VENTAS', 'motivo',
      format('«%s» ya tiene compras %s. Para cambiar cuántas entradas incluye, creá otra mesa.',
             v_t.nombre,
             case when v_t.manillas = 0 then 'sin entradas incluidas'
                  when v_t.manillas = 1 then 'con 1 entrada incluida'
                  else format('con %s entradas incluidas', v_t.manillas) end));
  end if;

  begin
    if p_tipo is null then
      insert into tipo_entrada (organizador_id, evento_id, nombre, descripcion, incluye,
                                manillas, categoria, cupo_total, comision_rrpp, orden)
      values (v_org, p_evento, v_nombre, v_desc, v_incluye,
              v_personas, 'mesa', v_cantidad, v_comision,
              coalesce((select max(orden) from tipo_entrada where evento_id = p_evento), 0) + 1)
      returning id into v_id;
    else
      update tipo_entrada
         set nombre = v_nombre, descripcion = v_desc, incluye = v_incluye,
             manillas = v_personas, cupo_total = v_cantidad, comision_rrpp = v_comision
       where id = p_tipo
      returning id into v_id;
    end if;
  exception when unique_violation then
    return jsonb_build_object('ok', false, 'motivo', 'Ya hay un producto con ese nombre en este evento.');
  end;

  -- Solo las filas de ESTA mesa: fuera de las fases desmarcadas, y el
  -- precio en las marcadas. El cupo de la fase va igual al tope del evento
  -- para que la grilla y la portada digan cuántas quedan; el que manda es
  -- cupo_total, que suma todas las fases.
  delete from fase_precio fp
   using evento_fase ef
   where fp.fase_id = ef.id and ef.evento_id = p_evento
     and fp.tipo_id = v_id
     and not (fp.fase_id = any(v_fases));

  -- Una fase recién marcada entra con el precio y el tope del formulario.
  -- Una que ya tenía fila NO se aplana (0107): el precio cambia solo si el
  -- organizador lo cambió (tocar_precio) y el cupo de la fase sigue al
  -- nuevo cupo_total solo si era el espejo del anterior. v_t es la mesa
  -- ANTES del update.
  insert into fase_precio (organizador_id, fase_id, tipo_id, precio, cupo)
  select v_org, f, v_id, v_precio, v_cantidad from unnest(v_fases) f
  on conflict (fase_id, tipo_id) do update
    set precio = case when v_tocar_precio then excluded.precio else fase_precio.precio end,
        cupo   = case when fase_precio.cupo is not distinct from v_t.cupo_total
                      then excluded.cupo else fase_precio.cupo end;

  return jsonb_build_object('ok', true, 'tipo_id', v_id,
    'motivo', case when p_tipo is null then format('Listo: «%s» ya está en la grilla.', v_nombre)
                   else format('«%s» guardada.', v_nombre) end);
end $function$;
revoke execute on function guardar_mesa(uuid, uuid, jsonb) from public, anon;
grant execute on function guardar_mesa(uuid, uuid, jsonb) to authenticated;

comment on function guardar_mesa(uuid, uuid, jsonb) is
  'Crea (p_tipo null) o edita una mesa o combo: tipo_entrada con categoria mesa, personas = entradas incluidas (0 a 50; 0 = la mesa no incluye entradas, 0108), descripcion, incluye, cupo_total, comision_rrpp y su precio en las fases de p_datos.fases (todas las activas si no viene). Toca solo los precios de esa mesa. Editando, una fase que ya tenia fila conserva su precio si p_datos.tocar_precio es false y su cupo solo sigue a cupo_total si era el espejo del anterior. Exige puede_editar(); rechaza espejos de Puerta y cambiar las entradas incluidas con compras hechas (0107).';

-- ── 7. una cortesía de una mesa sin entradas no tiene qué regalar ──
-- El cuerpo vivo de 0067 con una guarda más. Sin ella, `greatest(manillas,
-- 1)` convertía el 0 en 1 y salían manillas sueltas de una mesa que no
-- incluye entradas: QRs que pasan el molinete y que nadie vendió. Las
-- mesas con entradas siguen como hoy (salen sus manillas, sin recibo: no
-- hay titular ni orden).
create or replace function emitir_cortesias(p_evento uuid, p_tipo uuid, p_cantidad integer,
                                            p_para text, p_motivo text)
returns jsonb
  language plpgsql security definer set search_path = public as $function$
declare
  v_org    uuid := mi_organizador();
  v_motivo text := btrim(coalesce(p_motivo, ''));
  v_para   text := btrim(coalesce(p_para, ''));
  v_tope   int  := 50;
  v_tipo   tipo_entrada;
  v_fase   uuid; v_manillas int; v_disp int; v_pide int;
  v_codes  text[] := '{}'; v_code text; i int;
begin
  if not puede_editar() then raise exception 'Sin permiso'; end if;
  if v_motivo = '' then
    raise exception 'MOTIVO_REQUERIDO: una cortesía sin motivo es una entrada que nadie firmó.';
  end if;
  -- A nombre de quién van no es adorno: es lo que la puerta lee en el
  -- cartel cuando escanea. Una cortesía a nombre de nadie es una manilla
  -- que cualquiera puede reclamar.
  if v_para = '' then
    raise exception 'PARA_REQUERIDO: decí a nombre de quién van (la prensa, el DJ, la marca).';
  end if;
  if p_cantidad is null or p_cantidad < 1 then
    raise exception 'CANTIDAD_INVALIDA: son cortesías de a una para arriba, llegó %.', coalesce(p_cantidad, 0);
  end if;
  if p_cantidad > v_tope then
    raise exception 'TOPE_CORTESIAS: el máximo por vez son % manillas y se pidieron %. Si de verdad son más, van en varias tandas.', v_tope, p_cantidad;
  end if;
  -- Tenant y evento, adentro y con la misma respuesta para "no existe"
  -- que para "no es tuyo": así no sirve de oráculo de qué uuids hay en la
  -- base del vecino.
  if not exists (select 1 from eventos ev
                  where ev.id = p_evento and ev.organizador_id = v_org) then
    raise exception 'Sin permiso';
  end if;
  select * into v_tipo from tipo_entrada
   where id = p_tipo and evento_id = p_evento and organizador_id = v_org;
  if not found then
    raise exception 'TIPO_INEXISTENTE: ese producto no es de este evento.';
  end if;
  -- 0108
  if v_tipo.categoria = 'mesa' and v_tipo.manillas = 0 then
    raise exception 'MESA_SIN_ENTRADAS: «%» no incluye entradas, así que no hay nada que regalar. Regalá entradas de otro tipo.', v_tipo.nombre;
  end if;
  v_fase := fase_vigente(p_evento);
  if v_fase is null then
    raise exception 'SIN_FASE: este evento no tiene ninguna fase abierta hoy, así que no hay contra qué descontar el cupo. Abrí una fase y volvé.';
  end if;
  v_manillas := greatest(coalesce(v_tipo.manillas, 1), 1);
  v_pide := ceil(p_cantidad::numeric / v_manillas)::int;
  v_disp := disponibilidad_tipo(v_fase, p_tipo);
  if v_disp is not null and v_pide > v_disp then
    raise exception 'SIN_CUPO: de % % y estas cortesías necesitan %.',
      v_tipo.nombre,
      case when v_disp = 1 then 'queda 1 unidad' else format('quedan %s unidades', v_disp) end,
      case when v_pide = 1 then '1' else v_pide::text end;
  end if;
  for i in 1 .. p_cantidad loop
    insert into entradas (organizador_id, evento_id, orden_id, code, canal,
                          tipo_id, fase_id, cliente, precio)
    values (v_org, p_evento, null, nuevo_code(), 'cortesia',
            p_tipo, v_fase, v_para, 0)
    returning code into v_code;
    v_codes := v_codes || v_code;
  end loop;
  insert into admin_bitacora (organizador_id, evento_id, accion,
                              motivo, actor_id, detalle)
  values (v_org, p_evento, 'cortesias_emitidas', v_motivo, auth.uid(),
          jsonb_build_object(
            'para',             v_para,
            'cantidad',         p_cantidad,
            'tipo_id',          p_tipo,
            'tipo',             v_tipo.nombre,
            'fase_id',          v_fase,
            'unidades_de_cupo', v_pide,
            'codes',            to_jsonb(v_codes)));
  return jsonb_build_object('ok', true, 'evento', p_evento,
    'tipo_id', p_tipo, 'tipo', v_tipo.nombre, 'fase_id', v_fase,
    'cantidad', p_cantidad, 'para', v_para, 'codes', to_jsonb(v_codes),
    'quedan', disponibilidad_tipo(v_fase, p_tipo),
    'motivo', format('%s %s de %s a nombre de %s.',
      p_cantidad,
      case when p_cantidad = 1 then 'cortesía' else 'cortesías' end,
      v_tipo.nombre, v_para));
end $function$;
revoke execute on function emitir_cortesias(uuid, uuid, integer, text, text) from public, anon;
grant execute on function emitir_cortesias(uuid, uuid, integer, text, text) to authenticated;

-- ── 8. la puerta ─────────────────────────────────────────────
-- puerta_entrada: el cuerpo de 0107 con una sola diferencia en las
-- entradas de una mesa: el tipo se lee "Entrada · Mesa VIP" y viene
-- `mesa` aparte. El guardia tiene que saber que es una ENTRADA (pasa) y
-- de qué mesa es, sin confundirla con el recibo, que no pasa.
create or replace function puerta_entrada(p_evento uuid, p_code text, p_resultado text)
returns jsonb
  language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
           'resultado', p_resultado,
           'code',      e.code,
           'cliente',   e.cliente,
           'tipo',      case when t.categoria = 'mesa' then 'Entrada · ' || t.nombre
                             else coalesce(t.nombre, case when e.mesa_id is not null then 'Mesa' end) end,
           'mesa',      case when t.categoria = 'mesa' then t.nombre end,
           'canal',     e.canal,
           'estado',    e.estado,
           'used_at',   e.used_at,
           'entrada',   e.id,
           'titular',   case when t.categoria = 'mesa' or e.mesa_id is not null
                             then o.titular_nombre end,
           'titular_ci', case when (t.categoria = 'mesa' or e.mesa_id is not null)
                                   and o.titular_ci is not null
                              then o.titular_ci || coalesce(' ' || o.titular_ci_ext, '') end)
    from entradas e
    left join tipo_entrada t on t.id = e.tipo_id
    left join ordenes o on o.id = e.orden_id and o.organizador_id = e.organizador_id
   where e.organizador_id = mi_organizador()
     and e.evento_id = p_evento
     and e.code = upper(trim(p_code))
$$;
revoke execute on function puerta_entrada(uuid, text, text) from public, anon, authenticated;

comment on function puerta_entrada(uuid, text, text) is
  'La ficha de una entrada para la pantalla de la puerta, con el resultado que le pase quien llama. En las entradas de una mesa el tipo dice "Entrada · <mesa>", trae `mesa` y titular/titular_ci (carnet completo: es la puerta en linea) (0107, 0108). Cuerpo compartido de validar/filtro/descheckin. No se expone.';

-- recibo_puerta: la ficha del recibo de una mesa. Lo que el dueño pidió que
-- vea el guardia: tipo, lo que incluye, nombre, carnet y correo. Con
-- p_presentar anota la PRIMERA vez que se mostró (y quién lo escaneó);
-- las siguientes devuelven ya_presentado con esa hora. Nunca toca
-- `entradas`: un recibo no es un ingreso.
--
-- El update pide presentado_at null en el WHERE: dos puertas que lo
-- escanean a la vez no se pisan la hora, la segunda espera y ve la de la
-- primera.
create or replace function recibo_puerta(p_evento uuid, p_code text, p_presentar boolean)
returns jsonb
  language plpgsql volatile security definer set search_path = public as $function$
declare
  v_org uuid := mi_organizador();
  v_code text := upper(btrim(coalesce(p_code, '')));
  r mesa_recibos; o ordenes; v_previo timestamptz; v_estado text; v_ent jsonb; v_n int;
begin
  select * into r from mesa_recibos
   where organizador_id = v_org and evento_id = p_evento and code = v_code;
  if not found then
    return jsonb_build_object('resultado', 'no_existe', 'code', v_code);
  end if;
  select * into o from ordenes where id = r.orden_id and organizador_id = v_org;
  v_estado := case when o.estado = 'pagada' then 'valida' else 'anulada' end;
  v_previo := r.presentado_at;

  if p_presentar and v_estado = 'valida' and r.presentado_at is null then
    update mesa_recibos set presentado_at = now(), presentado_por = auth.uid()
     where id = r.id and presentado_at is null;
    get diagnostics v_n = row_count;
    select presentado_at into r.presentado_at from mesa_recibos where id = r.id;
    -- Si la otra puerta ganó por milisegundos, esta es la segunda.
    if v_n = 0 then v_previo := r.presentado_at; end if;
  end if;

  select jsonb_build_object('total',  count(*) filter (where e.estado <> 'anulada'),
                            'usadas', count(*) filter (where e.estado = 'usada'))
    into v_ent from entradas e where e.orden_id = r.orden_id;

  return jsonb_build_object(
    'resultado',          'recibo_mesa',
    'recibo',             true,
    'code',               r.code,
    'estado',             v_estado,
    'tipo',               r.tipo_nombre,
    'incluye',            r.incluye,
    'entradas_incluidas', r.entradas_incluidas,
    'cliente',            o.titular_nombre,
    'titular',            o.titular_nombre,
    -- Completo: es la puerta en línea, con un portero logueado, y se
    -- compara contra el carnet en la mano.
    'titular_ci',         o.titular_ci || coalesce(' ' || o.titular_ci_ext, ''),
    'email',              o.comprador_email,
    'presentado_at',      r.presentado_at,
    'ya_presentado',      v_previo is not null,
    'entradas',           v_ent);
end $function$;
revoke execute on function recibo_puerta(uuid, text, boolean) from public, anon, authenticated;

comment on function recibo_puerta(uuid, text, boolean) is
  'La ficha del recibo de una mesa para la puerta (0108): resultado recibo_mesa, estado valida/anulada (sigue a la orden), tipo, incluye, entradas_incluidas, titular, titular_ci completo, email, presentado_at y ya_presentado. Con p_presentar anota la primera presentacion. Nunca marca un ingreso. No se expone: la llaman validar_entrada y marcar_filtro_entrada.';

-- validar_entrada: el cuerpo vivo de 0103 con el desvío al recibo al
-- principio. Un código MESA… no es una entrada: se muestra el recibo y
-- se anota que se presentó, y la función vuelve sin haber tocado
-- `entradas`. Una puerta vieja (sin la pantalla de recibo) recibe un
-- resultado que no conoce y lo dibuja como "NO SE PUDO": en rojo, que es
-- lo seguro.
create or replace function validar_entrada(p_evento uuid, p_code text)
returns jsonb
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

  -- 0108: el recibo de una mesa abre el recibo, nunca el molinete.
  if v_code like 'MESA%' then
    return recibo_puerta(p_evento, v_code, true);
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
revoke execute on function validar_entrada(uuid, text) from public, anon;
grant execute on function validar_entrada(uuid, text) to authenticated;

-- marcar_filtro_entrada: el cuerpo vivo de 0103. Con filtro puesto un
-- recibo se muestra sin anotar la presentación: el filtro no consume
-- nada, y "ya se presentó" tiene que ser la hora en que la persona llegó
-- a la mesa, no la de un control de seguridad.
create or replace function marcar_filtro_entrada(p_evento uuid, p_code text)
returns jsonb
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

  -- 0108
  if v_code like 'MESA%' then
    return recibo_puerta(p_evento, v_code, false) || jsonb_build_object('filtro', true);
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
  -- existe en algún lado.
  insert into puerta_bitacora (organizador_id, evento_id, entrada_id, accion,
                               actor_id, estado_previo, used_at_previo, portero_previo)
  values (mi_organizador(), p_evento, v_id, 'rechazada',
          auth.uid(), v_estado, v_used, v_portero);

  -- Devuelve el estado real para que el portero sepa qué está rechazando,
  -- aunque afuera se vea el mismo cartel que una falsa.
  return puerta_entrada(p_evento, v_code, v_estado) || jsonb_build_object('filtro', true);
end $function$;
revoke execute on function marcar_filtro_entrada(uuid, text) from public, anon;
grant execute on function marcar_filtro_entrada(uuid, text) to authenticated;

-- sincronizar_puerta: el cuerpo vivo de 0039 con los recibos. Sin señal la
-- puerta anota que un recibo se presentó y lo sube con la cola de los
-- ingresos, con su hora. Acá se guarda la MÁS TEMPRANA entre la que ya
-- había y la del teléfono: es la primera presentación, y la puerta con
-- señal pudo haberla anotado más tarde que la que estaba a ciegas. Un
-- recibo nunca cuenta como ingreso ni como conflicto: vuelve con
-- resultado 'recibo_mesa' y se cuenta aparte.
create or replace function sincronizar_puerta(p_evento uuid, p_ingresos jsonb)
returns jsonb
  language plpgsql security definer set search_path = public as $function$
declare
  v_org uuid := mi_organizador();
  r record; v_id uuid; v_estado text; v_at timestamptz; v_used timestamptz;
  v_res jsonb := '[]'::jsonb;
  v_ok int := 0; v_conf int := 0; v_otro int := 0; v_rec int := 0;
begin
  if not (es_portero() or puede_editar()) then raise exception 'Sin permiso'; end if;

  if jsonb_typeof(coalesce(p_ingresos, 'null'::jsonb)) <> 'array' then
    raise exception 'INGRESOS_INVALIDOS: se espera una lista.';
  end if;
  -- Un tope por llamada para que un teléfono con la noche entera guardada
  -- no mande una transacción de veinte minutos. El escáner corta en tandas.
  if jsonb_array_length(p_ingresos) > 500 then
    raise exception 'DEMASIADOS: mandá de a 500 como mucho.';
  end if;

  if not exists (select 1 from eventos where id = p_evento and organizador_id = v_org) then
    raise exception 'EVENTO_INEXISTENTE: ese evento no es tuyo.';
  end if;

  for r in
    select upper(btrim(x->>'code')) as code,
           (x->>'at')::timestamptz  as at
      from jsonb_array_elements(p_ingresos) x
     where btrim(coalesce(x->>'code','')) <> ''
     -- El que escaneó primero gana. Sin este orden, gana el que se
     -- reconectó primero, que no tiene nada que ver con quién entró.
     order by (x->>'at')::timestamptz nulls last
  loop
    -- La hora del teléfono se acepta solo si es creíble.
    v_at := case
              when r.at is null then now()
              when r.at > now() + interval '5 minutes' then now()
              when r.at < now() - interval '2 days'    then now()
              else r.at
            end;

    -- 0108: el recibo de una mesa. Se anota la presentación si la orden
    -- sigue pagada, y nunca se toca `entradas`.
    if r.code like 'MESA%' then
      update mesa_recibos m
         set presentado_at = v_at, presentado_por = auth.uid()
       where m.organizador_id = v_org and m.evento_id = p_evento and m.code = r.code
         and (m.presentado_at is null or m.presentado_at > v_at)
         and exists (select 1 from ordenes o where o.id = m.orden_id and o.estado = 'pagada');
      select m.presentado_at into v_used from mesa_recibos m
       where m.organizador_id = v_org and m.evento_id = p_evento and m.code = r.code;
      if not found then
        v_otro := v_otro + 1;
        v_res := v_res || jsonb_build_object('code', r.code, 'resultado', 'no_existe');
      else
        v_rec := v_rec + 1;
        v_res := v_res || jsonb_build_object('code', r.code, 'resultado', 'recibo_mesa',
                                             'presentado_at', v_used);
      end if;
      continue;
    end if;

    update entradas
       set estado = 'usada', used_at = v_at, portero_id = auth.uid()
     where organizador_id = v_org
       and evento_id = p_evento
       and code = r.code
       and estado = 'valida'
    returning id into v_id;

    if v_id is not null then
      v_ok := v_ok + 1;
      v_res := v_res || jsonb_build_object('code', r.code, 'resultado', 'valida');
      continue;
    end if;

    select estado, used_at into v_estado, v_used
      from entradas
     where organizador_id = v_org and evento_id = p_evento and code = r.code;

    if v_estado is null then
      v_otro := v_otro + 1;
      v_res := v_res || jsonb_build_object('code', r.code, 'resultado', 'no_existe');
    elsif v_estado = 'usada' then
      -- Alguien más ya lo había consumido. Es el caso que importa: esa
      -- persona ya está adentro y entró dos veces con la misma manilla.
      v_conf := v_conf + 1;
      v_res := v_res || jsonb_build_object('code', r.code, 'resultado', 'usada',
                                           'used_at', v_used);
    else
      v_otro := v_otro + 1;
      v_res := v_res || jsonb_build_object('code', r.code, 'resultado', v_estado);
    end if;
  end loop;

  return jsonb_build_object(
    'ok', true, 'aplicados', v_ok, 'conflictos', v_conf, 'otros', v_otro,
    'recibos', v_rec, 'detalle', v_res);
end $function$;
revoke execute on function sincronizar_puerta(uuid, jsonb) from public, anon;
grant execute on function sincronizar_puerta(uuid, jsonb) to authenticated;

-- padron_puerta: la definición viva de 0107 con dos cambios marcados 0108:
--   · `recibos`, la lista de recibos de mesa del evento, para que sin señal
--     el guardia vea lo mismo que con señal. Con el carnet COMPLETO y el
--     correo: lo pidió el dueño a propósito (el guardia compara contra el
--     carnet en la mano), y deja sin efecto, solo para los recibos, el
--     enmascarado que 0107 eligió para el padrón. Las entradas de la mesa
--     siguen enmascaradas como en 0107.
--   · en las entradas de una mesa, t = "Entrada · <mesa>", lo mismo que
--     dice la puerta en línea.
-- Claves cortas como el resto: c=code, t=tipo, i=incluye, k=entradas
-- incluidas, n=titular, d=carnet, m=correo, e=estado, p=presentado_at.
-- Van aparte de `entradas` y no adentro con una marca: una puerta con el
-- JavaScript viejo indexa `entradas` y le daría PASA a un recibo.
create or replace function padron_puerta(p_evento uuid) returns jsonb
  language plpgsql stable security definer set search_path = public as $function$
declare
  v_org uuid := mi_organizador();
  v_nombre text; v_fecha date;
  v_total int; v_lista jsonb; v_recibos jsonb;
  -- Tope de cordura. Con más que esto el teléfono no es el lugar: el
  -- padrón se guarda entero en el navegador y bajarlo por una antena de
  -- feria tarda. Se avisa con `truncado` en vez de devolver una lista
  -- corta en silencio.
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
      'entradas', '[]'::jsonb, 'recibos', '[]'::jsonb, 'espejo', 'puerta');
  end if;

  select count(*) into v_total
    from entradas where organizador_id = v_org and evento_id = p_evento;

  select coalesce(jsonb_agg(f order by f->>'c'), '[]'::jsonb) into v_lista
    from (
      select jsonb_build_object(
               'c', e.code,
               'n', e.cliente,
               't', case when t.categoria = 'mesa' then 'Entrada · ' || t.nombre
                         else coalesce(t.nombre, case when e.mesa_id is not null then 'Mesa' end) end,
               'e', e.estado,
               'u', e.used_at)
             || case when t.categoria = 'mesa' or e.mesa_id is not null then
                  coalesce((select jsonb_build_object(
                                     'tn', o.titular_nombre,
                                     'td', '••' || right(substring(o.titular_ci from '[0-9]{5,10}'), 4)
                                           || coalesce(' ' || o.titular_ci_ext, ''))
                              from ordenes o
                             where o.id = e.orden_id and o.organizador_id = v_org
                               and o.titular_nombre is not null), '{}'::jsonb)
                else '{}'::jsonb end as f
        from entradas e
        left join tipo_entrada t on t.id = e.tipo_id
       where e.organizador_id = v_org and e.evento_id = p_evento
       order by e.code
       limit v_tope
    ) s;

  select coalesce(jsonb_agg(jsonb_build_object(
           'c', r.code,
           't', r.tipo_nombre,
           'i', r.incluye,
           'k', r.entradas_incluidas,
           'n', o.titular_nombre,
           'd', o.titular_ci || coalesce(' ' || o.titular_ci_ext, ''),
           'm', o.comprador_email,
           'e', case when o.estado = 'pagada' then 'valida' else 'anulada' end,
           'p', r.presentado_at) order by r.code), '[]'::jsonb)
    into v_recibos
    from mesa_recibos r
    join ordenes o on o.id = r.orden_id and o.organizador_id = v_org
   where r.organizador_id = v_org and r.evento_id = p_evento;

  return jsonb_build_object(
    'ok', true,
    'evento', p_evento,
    'nombre', v_nombre,
    'fecha', v_fecha,
    'generado_at', now(),
    'total', v_total,
    'truncado', v_total > v_tope,
    'entradas', v_lista,
    'recibos', v_recibos);
end $function$;
revoke execute on function padron_puerta(uuid) from anon, public;
grant execute on function padron_puerta(uuid) to authenticated;

comment on function padron_puerta(uuid) is
  'La lista entera de entradas de un evento para que la puerta pueda trabajar sin señal, y aparte los recibos de mesa (0108). Vuelve como un jsonb y no como filas porque PostgREST corta en 1000 sin avisar. Entradas: c=code, n=cliente, t=tipo, e=estado, u=used_at; en las de una mesa tn=titular y td=carnet enmascarado (0107). Recibos: c, t=tipo, i=incluye, k=entradas incluidas, n=titular, d=carnet completo, m=correo, e=valida/anulada, p=presentado_at. Espejo de Puerta: padron vacio (0103).';

-- ── 9. la comisión: entradas, mesas y total, por separado ───
-- ventas_rrpp_base (0026, 0107) sigue siendo la única cuenta. Cambian dos
-- cosas:
--   · las mesas se cuentan de lo COMPRADO (orden_items de órdenes
--     pagadas), no de las manillas: una mesa de 0 entradas no tiene
--     manillas y con la cuenta de 0107 no le pagaba nada al relacionador
--     ni aparecía en sus ventas. Una mesa deja de contar cuando se anula
--     la compra (anular_orden la deja 'anulada'), no cuando se anulan sus
--     entradas de a una: sigue habiendo una mesa vendida.
--   · sale `comision_entradas` (sueltas × comisión de la persona) al lado
--     de `comision_mesas`, y `comision` es la suma. Que cada pantalla la
--     reste por su cuenta es cómo dos pantallas muestran dos números.
-- Para quien solo vendió entradas es la cuenta de siempre, al centavo.
--
-- Cambiar las columnas de salida es drop + create (invariante 4). Quienes
-- la llaman (plpgsql y sql sin BEGIN ATOMIC) la resuelven por nombre al
-- correr, y todos piden columnas por nombre: ninguno se rompe.
drop function if exists ventas_rrpp_base(uuid, uuid);
create function ventas_rrpp_base(p_evento uuid, p_perfil uuid)
returns table (
  perfil_id         uuid,
  evento_id         uuid,
  evento_nombre     text,
  evento_fecha      date,
  entradas          int,
  recaudado         numeric(12,2),
  comision_unitaria numeric(12,2),
  comision          numeric(12,2),
  sueltas           int,
  mesas             int,
  comision_mesas    numeric(12,2),
  comision_entradas numeric(12,2)
)
  language sql stable security definer set search_path = public as $$
  with ordenes_rrpp as (
    select o.id, o.evento_id, o.rrpp_id, o.subtotal,
           coalesce(e.validas, 0)      as validas,
           coalesce(e.validas_mesa, 0) as validas_mesa,
           coalesce(m.unidades, 0)     as mesas,
           coalesce(m.comision, 0)     as comision_mesas
      from ordenes o
      -- las manillas válidas, y cuáles de ellas vinieron con una mesa
      left join lateral (
        select count(*)::int as validas,
               count(*) filter (where t.categoria = 'mesa')::int as validas_mesa
          from entradas e
          left join tipo_entrada t on t.id = e.tipo_id
         where e.orden_id = o.id and e.estado <> 'anulada'
      ) e on true
      -- 0108: las mesas, de lo comprado
      left join lateral (
        select sum(i.cantidad)::int as unidades,
               sum(i.cantidad * coalesce(t.comision_rrpp,
                                         comision_de(o.rrpp_id, o.evento_id))) as comision
          from orden_items i
          join tipo_entrada t on t.id = i.tipo_id and t.categoria = 'mesa'
         where i.orden_id = o.id
      ) m on true
     where o.organizador_id = mi_organizador()   -- el corte de tenant, siempre
       and o.estado = 'pagada'                   -- pendiente o vencida no es venta
       and o.rrpp_id is not null
       and (p_evento is null or o.evento_id = p_evento)
       and (p_perfil is null or o.rrpp_id = p_perfil)
  ),
  por_evento as (
    select r.rrpp_id, r.evento_id,
           sum(r.validas)::int as entradas,
           sum(r.validas - r.validas_mesa)::int as sueltas,
           sum(r.mesas)::int as mesas,
           sum(r.comision_mesas) as comision_mesas,
           sum(r.subtotal)::numeric(12,2) as recaudado
      from ordenes_rrpp r
     -- Una compra de entradas con todas anuladas no es venta (como
     -- siempre). Una mesa pagada sí, aunque no incluya ninguna entrada.
     where r.validas > 0 or r.mesas > 0
     group by r.rrpp_id, r.evento_id
  )
  select pe.rrpp_id, pe.evento_id, ev.nombre, ev.fecha,
         pe.entradas, pe.recaudado,
         comision_de(pe.rrpp_id, pe.evento_id)::numeric(12,2),
         (pe.sueltas * comision_de(pe.rrpp_id, pe.evento_id) + pe.comision_mesas)::numeric(12,2),
         pe.sueltas, pe.mesas, pe.comision_mesas::numeric(12,2),
         (pe.sueltas * comision_de(pe.rrpp_id, pe.evento_id))::numeric(12,2)
    from por_evento pe
    join eventos ev on ev.id = pe.evento_id
   where ev.organizador_id = mi_organizador()
$$;
revoke execute on function ventas_rrpp_base(uuid, uuid) from public, anon, authenticated;

comment on function ventas_rrpp_base(uuid, uuid) is
  'Cuerpo compartido de mis_ventas(), ventas_por_rrpp(), la liquidacion y el cierre: una fila por (relacionador, evento) con manillas validas, recaudado y comision. comision = comision_entradas (sueltas x comision_de) + comision_mesas (por mesa comprada en ordenes pagadas: tipo.comision_rrpp o comision_de) (0107, 0108). Acota por mi_organizador() adentro, no por parametro. No se expone.';

-- mis_ventas: la de 0107 con comision_entradas.
create or replace function mis_ventas(p_evento uuid default null) returns jsonb
  language plpgsql stable security definer set search_path = public as $function$
declare v_yo uuid := auth.uid();
begin
  if v_yo is null then return '[]'::jsonb; end if;

  -- El corte mira el ROL y no `puede_editar()`: un admin que además vende
  -- por su propio link tiene que seguir viendo lo suyo. Lo que la bandera
  -- apaga es la pantalla del relacionador, no la contabilidad.
  if mi_rol() = 'rrpp'
     and not coalesce((select rrpp_ve_ventas from organizadores
                        where id = mi_organizador()), true) then
    return '[]'::jsonb;
  end if;

  return (
    select coalesce(jsonb_agg(jsonb_build_object(
             'evento_id',         v.evento_id,
             'evento_nombre',     v.evento_nombre,
             'evento_fecha',      v.evento_fecha,
             'entradas',          v.entradas,
             'recaudado',         v.recaudado,
             'comision_unitaria', v.comision_unitaria,
             'comision',          v.comision,
             'sueltas',           v.sueltas,
             'mesas',             v.mesas,
             'comision_mesas',    v.comision_mesas,
             'comision_entradas', v.comision_entradas)
           order by v.comision desc, v.evento_fecha desc), '[]'::jsonb)
      from ventas_rrpp_base(p_evento, v_yo) v);
end $function$;
revoke execute on function mis_ventas(uuid) from anon, public;
grant execute on function mis_ventas(uuid) to authenticated;

-- ventas_por_rrpp: la de 0107 con comision_entradas.
create or replace function ventas_por_rrpp(p_evento uuid) returns jsonb
  language plpgsql stable security definer set search_path = public as $function$
begin
  if not puede_editar() then raise exception 'Sin permiso'; end if;

  return (
    select coalesce(jsonb_agg(jsonb_build_object(
             'perfil_id',         v.perfil_id,
             'nombre',            p.nombre,
             'slug',              p.slug,
             'evento_id',         v.evento_id,
             'evento_nombre',     v.evento_nombre,
             'evento_fecha',      v.evento_fecha,
             'entradas',          v.entradas,
             'recaudado',         v.recaudado,
             'comision_unitaria', v.comision_unitaria,
             'comision',          v.comision,
             'sueltas',           v.sueltas,
             'mesas',             v.mesas,
             'comision_mesas',    v.comision_mesas,
             'comision_entradas', v.comision_entradas)
           order by v.comision desc, p.nombre), '[]'::jsonb)
      from ventas_rrpp_base(p_evento, null) v
      -- el join también acota por organizador: esta función corre como
      -- definer, así que la RLS de perfiles no la frena.
      join perfiles p on p.id = v.perfil_id and p.organizador_id = mi_organizador());
end $function$;
revoke execute on function ventas_por_rrpp(uuid) from anon, public;
grant execute on function ventas_por_rrpp(uuid) to authenticated;

-- ── 10. el pago de comisiones también distingue ─────────────
-- La línea de la liquidación es lo que se le paga a cada relacionador al
-- cerrar (0034) y lo que pagar_comision marca. Con las dos partes
-- guardadas en la línea, "le pagué 480" se puede leer como "330 por
-- entradas y 150 por dos mesas" un mes después, sin recalcular contra una
-- base que cambió. Nullable: las líneas de cierres anteriores no las
-- tienen y no se inventan.
alter table liquidacion_linea
  add column if not exists sueltas           int,
  add column if not exists mesas             int,
  add column if not exists comision_entradas numeric(12,2),
  add column if not exists comision_mesas    numeric(12,2);

comment on column liquidacion_linea.comision_entradas is
  'Parte de la comision por entradas sueltas (sueltas x comision_unitaria) al cerrar (0108). Null en cierres anteriores.';
comment on column liquidacion_linea.comision_mesas is
  'Parte de la comision por mesas vendidas al cerrar (0108). Null en cierres anteriores. comision = comision_entradas + comision_mesas.';

-- cerrar_evento: el cuerpo vivo de 0034 con las cuatro columnas en la línea.
create or replace function cerrar_evento(p_evento uuid, p_motivo text) returns jsonb
  language plpgsql security definer set search_path = public as $function$
declare
  v_org    uuid := mi_organizador();
  v_yo     uuid := auth.uid();
  v_motivo text := btrim(coalesce(p_motivo, ''));
  e eventos; v_liq uuid; v_ver int;
  v_bruto numeric(12,2); v_fee numeric(12,2); v_ent int; v_ord int;
  v_com numeric(12,2) := 0; v_pend int; v_rev int;
  v_com_ent numeric(12,2); v_com_mes numeric(12,2);
begin
  if not puede_editar() then raise exception 'Sin permiso'; end if;
  if v_motivo = '' then
    raise exception 'MOTIVO_REQUERIDO: sin motivo no se cierra. El cierre es con lo que se le paga a la gente; dentro de un mes nadie se acuerda por qué se cerró ese día.';
  end if;
  -- for update: dos cierres a la vez sobre el mismo evento se serializan
  -- acá, y el segundo ve el estado que dejó el primero.
  select * into e from eventos where id = p_evento and organizador_id = v_org for update;
  if not found then raise exception 'EVENTO_INEXISTENTE: %', p_evento; end if;
  if e.estado = 'cerrado' then
    raise exception 'YA_CERRADO: este evento ya se cerró. Reabrilo si hay que rehacer la liquidación.';
  end if;
  -- Plata sin resolver. No frena el cierre —a veces hay que cerrar igual—
  -- pero viaja en la respuesta para que la pantalla lo muestre antes de
  -- que alguien firme una transferencia con la cuenta a medio hacer.
  select count(*) into v_rev  from ordenes
   where evento_id = p_evento and estado = 'revision_manual';
  select count(*) into v_pend from ordenes
   where evento_id = p_evento and estado = 'pendiente' and expira_at > now();
  select coalesce(sum(subtotal),0), coalesce(sum(fee),0), count(*)
    into v_bruto, v_fee, v_ord
    from ordenes where evento_id = p_evento and estado = 'pagada';
  select count(*) into v_ent
    from entradas where evento_id = p_evento and estado <> 'anulada';
  select coalesce(version,0) + 1 into v_ver from liquidacion
   where evento_id = p_evento order by version desc limit 1;
  v_ver := coalesce(v_ver, 1);
  update liquidacion set vigente = false where evento_id = p_evento and vigente;
  insert into liquidacion (organizador_id, evento_id, version, vigente, bruto, fee,
                           cobrado, comisiones, neto, entradas, ordenes,
                           cerrada_por, motivo, detalle)
  values (v_org, p_evento, v_ver, true, v_bruto, v_fee, v_bruto + v_fee, 0,
          v_bruto, v_ent, v_ord, v_yo, v_motivo,
          jsonb_build_object('revision_manual_al_cerrar', v_rev,
                             'pendientes_vivas_al_cerrar', v_pend))
  returning id into v_liq;
  -- Las líneas salen de ventas_rrpp_base(), el MISMO cuerpo que usan
  -- mis_ventas() y ventas_por_rrpp() (0026). Recalcular la comisión acá
  -- sería un segundo lugar donde vive la misma cuenta.
  insert into liquidacion_linea (organizador_id, liquidacion_id, perfil_id, nombre, slug,
                                 entradas, recaudado, comision_unitaria, comision,
                                 sueltas, mesas, comision_entradas, comision_mesas)
  select v_org, v_liq, v.perfil_id, p.nombre, p.slug,
         v.entradas, v.recaudado, v.comision_unitaria, v.comision,
         v.sueltas, v.mesas, v.comision_entradas, v.comision_mesas
    from ventas_rrpp_base(p_evento, null) v
    join perfiles p on p.id = v.perfil_id and p.organizador_id = v_org;
  select coalesce(sum(comision),0), coalesce(sum(comision_entradas),0), coalesce(sum(comision_mesas),0)
    into v_com, v_com_ent, v_com_mes
    from liquidacion_linea where liquidacion_id = v_liq;
  update liquidacion set comisiones = v_com, neto = v_bruto where id = v_liq;
  update eventos set estado = 'cerrado' where id = p_evento;
  insert into admin_bitacora (organizador_id, evento_id, accion, motivo, actor_id, detalle)
  values (v_org, p_evento, 'evento_cerrado', v_motivo, v_yo,
          jsonb_build_object('liquidacion', v_liq, 'version', v_ver,
                             'bruto', v_bruto, 'fee', v_fee, 'comisiones', v_com,
                             'comisiones_entradas', v_com_ent, 'comisiones_mesas', v_com_mes));
  return jsonb_build_object('ok', true, 'liquidacion', v_liq, 'version', v_ver,
    'bruto', v_bruto, 'fee', v_fee, 'comisiones', v_com, 'neto', v_bruto,
    'comisiones_entradas', v_com_ent, 'comisiones_mesas', v_com_mes,
    'entradas', v_ent, 'ordenes', v_ord,
    'sin_resolver', jsonb_build_object('revision_manual', v_rev, 'pendientes_vivas', v_pend),
    'motivo', format('Evento cerrado. Quedan %s Bs para el organizador y %s Bs en comisiones.',
                     v_bruto, v_com));
end $function$;
revoke execute on function cerrar_evento(uuid, text) from public, anon;
grant execute on function cerrar_evento(uuid, text) to authenticated;

-- liquidacion_evento: el cuerpo vivo de 0034 con la partición en `hoy`, en
-- la foto y en cada línea. Las líneas de un cierre anterior a 0108 traen
-- null en las partes: la pantalla muestra solo el total, que es lo que se
-- sabía cuando se cerró.
create or replace function liquidacion_evento(p_evento uuid) returns jsonb
  language plpgsql stable security definer set search_path = public as $function$
declare
  v_org uuid := mi_organizador();
  q liquidacion; e eventos;
  v_bruto numeric(12,2); v_fee numeric(12,2); v_ent int; v_ord int; v_com numeric(12,2);
  v_com_ent numeric(12,2); v_com_mes numeric(12,2);
begin
  if not puede_editar() then raise exception 'Sin permiso'; end if;
  select * into e from eventos where id = p_evento and organizador_id = v_org;
  if not found then return '{}'::jsonb; end if;
  -- lo que dicen los datos AHORA
  select coalesce(sum(subtotal),0), coalesce(sum(fee),0), count(*)
    into v_bruto, v_fee, v_ord
    from ordenes where evento_id = p_evento and estado = 'pagada';
  select count(*) into v_ent
    from entradas where evento_id = p_evento and estado <> 'anulada';
  select coalesce(sum(comision),0), coalesce(sum(comision_entradas),0), coalesce(sum(comision_mesas),0)
    into v_com, v_com_ent, v_com_mes
    from ventas_rrpp_base(p_evento, null);
  select * into q from liquidacion where evento_id = p_evento and vigente;
  return jsonb_build_object(
    'evento', jsonb_build_object('id', e.id, 'nombre', e.nombre, 'fecha', e.fecha,
                                 'estado', e.estado, 'cerrado', e.estado = 'cerrado'),
    'hoy', jsonb_build_object('bruto', v_bruto, 'fee', v_fee, 'cobrado', v_bruto + v_fee,
                              'comisiones', v_com, 'neto', v_bruto,
                              'comisiones_entradas', v_com_ent, 'comisiones_mesas', v_com_mes,
                              'entradas', v_ent, 'ordenes', v_ord),
    'sin_resolver', jsonb_build_object(
      'revision_manual', (select count(*) from ordenes
         where evento_id = p_evento and estado = 'revision_manual'),
      'pendientes_vivas', (select count(*) from ordenes
         where evento_id = p_evento and estado = 'pendiente' and expira_at > now())),
    'foto', case when q.id is null then null else jsonb_build_object(
      'id', q.id, 'version', q.version, 'cerrada_at', q.cerrada_at, 'motivo', q.motivo,
      'cerrada_por', (select nombre from perfiles where id = q.cerrada_por),
      'bruto', q.bruto, 'fee', q.fee, 'cobrado', q.cobrado,
      'comisiones', q.comisiones, 'neto', q.neto,
      'comisiones_entradas', (select sum(l.comision_entradas) from liquidacion_linea l
                               where l.liquidacion_id = q.id),
      'comisiones_mesas',    (select sum(l.comision_mesas) from liquidacion_linea l
                               where l.liquidacion_id = q.id),
      'entradas', q.entradas, 'ordenes', q.ordenes, 'detalle', q.detalle,
      -- La diferencia, ya restada. Que cada pantalla la calcule por su
      -- cuenta es cómo dos pantallas muestran dos diferencias distintas.
      'difiere', (q.bruto <> v_bruto or q.comisiones <> v_com or q.entradas <> v_ent),
      'diferencia', jsonb_build_object('bruto', v_bruto - q.bruto,
                                       'comisiones', v_com - q.comisiones,
                                       'entradas', v_ent - q.entradas),
      'lineas', coalesce((
        select jsonb_agg(jsonb_build_object(
                 'id', l.id, 'perfil_id', l.perfil_id, 'nombre', l.nombre, 'slug', l.slug,
                 'entradas', l.entradas, 'recaudado', l.recaudado,
                 'comision_unitaria', l.comision_unitaria, 'comision', l.comision,
                 'sueltas', l.sueltas, 'mesas', l.mesas,
                 'comision_entradas', l.comision_entradas, 'comision_mesas', l.comision_mesas,
                 'pagada', l.pagada_at is not null, 'pagada_at', l.pagada_at,
                 'pagado_monto', l.pagado_monto, 'pagado_nota', l.pagado_nota,
                 'pagada_por', (select nombre from perfiles where id = l.pagada_por))
               order by l.comision desc, l.nombre)
          from liquidacion_linea l where l.liquidacion_id = q.id), '[]'::jsonb)) end);
end $function$;
revoke execute on function liquidacion_evento(uuid) from public, anon;
grant execute on function liquidacion_evento(uuid) to authenticated;

-- pagar_comision: el cuerpo vivo de 0034. El pago sigue siendo de la línea
-- entera (una transferencia por persona); lo que cambia es que la
-- bitácora y la respuesta dicen cuánto de eso fue por entradas y cuánto
-- por mesas.
create or replace function pagar_comision(p_linea uuid, p_monto numeric default null,
                                          p_nota text default null)
returns jsonb
  language plpgsql security definer set search_path = public as $function$
declare
  v_org uuid := mi_organizador();
  v_yo  uuid := auth.uid();
  l liquidacion_linea; v_prev record;
begin
  if not puede_editar() then raise exception 'Sin permiso'; end if;
  update liquidacion_linea
     set pagada_at    = clock_timestamp(),
         pagada_por   = v_yo,
         pagado_monto = coalesce(p_monto, comision),
         pagado_nota  = nullif(btrim(coalesce(p_nota, '')), '')
   where id = p_linea
     and organizador_id = v_org
     and pagada_at is null          -- ← el candado, adentro
  returning * into l;
  if found then
    insert into admin_bitacora (organizador_id, evento_id, accion, motivo, actor_id, detalle)
    select v_org, q.evento_id, 'comision_pagada',
           coalesce(nullif(btrim(coalesce(p_nota,'')),''),
                    format('Comisión de %s pagada', l.nombre)),
           v_yo,
           jsonb_build_object('linea', l.id, 'perfil', l.perfil_id, 'nombre', l.nombre,
                              'entradas', l.entradas, 'monto', l.pagado_monto,
                              'comision', l.comision,
                              'comision_entradas', l.comision_entradas,
                              'comision_mesas', l.comision_mesas,
                              'sueltas', l.sueltas, 'mesas', l.mesas)
      from liquidacion q where q.id = l.liquidacion_id;
    return jsonb_build_object('ok', true, 'linea', l.id, 'monto', l.pagado_monto,
      'comision_entradas', l.comision_entradas, 'comision_mesas', l.comision_mesas,
      'motivo', format('Pagado: %s Bs a %s.', l.pagado_monto, l.nombre));
  end if;
  -- No devolvió fila. Recién acá se averigua por qué.
  select ll.pagada_at, ll.pagado_monto, ll.nombre, p.nombre as quien
    into v_prev
    from liquidacion_linea ll
    left join perfiles p on p.id = ll.pagada_por
   where ll.id = p_linea and ll.organizador_id = v_org;
  if not found then raise exception 'LINEA_INEXISTENTE: esa línea no es de tu liquidación.'; end if;
  return jsonb_build_object('ok', false, 'ya_pagada', true,
    'pagada_at', v_prev.pagada_at, 'monto', v_prev.pagado_monto,
    'motivo', format('La comisión de %s ya se pagó%s: %s Bs.',
                     v_prev.nombre,
                     case when v_prev.quien is not null then ', la marcó ' || v_prev.quien else '' end,
                     v_prev.pagado_monto));
end $function$;
revoke execute on function pagar_comision(uuid, numeric, text) from public, anon;
grant execute on function pagar_comision(uuid, numeric, text) to authenticated;

-- ── 11. el panel: tablero de mesas y compradores de mesas ───
-- tablero_mesas: la tabla "Por fase" del Resumen pero por tipo de mesa.
-- (No se llama mesas_evento porque ese nombre ya es el plano de mesas
-- físicas de 0005/0033, que el relacionador usa para vender.)
-- Cuántas hay (el tope del evento, null = sin tope), cuántas se vendieron
-- (pagadas), cuántas están en pago ahora (reservadas, que vencen solas),
-- cuántas quedan sin vender, cuánto se recaudó y si incluyen entradas.
-- `recaudado` es al precio que pagó cada comprador, igual que "Por fase";
-- `neto` es lo del organizador (subtotal de esas órdenes: con MESA_SOLA
-- cada una lleva solo esa mesa). Solo admin y staff, como el Resumen.
create or replace function tablero_mesas(p_evento uuid) returns jsonb
  language plpgsql stable security definer set search_path = public as $function$
declare
  v_org uuid := mi_organizador();
  v_fase uuid; v_tipos jsonb;
begin
  if not puede_editar() then raise exception 'Sin permiso'; end if;
  if not exists (select 1 from eventos where id = p_evento and organizador_id = v_org) then
    return '{}'::jsonb;
  end if;
  v_fase := fase_vigente(p_evento);

  select coalesce(jsonb_agg(jsonb_build_object(
           'tipo_id',            t.id,
           'nombre',             t.nombre,
           'descripcion',        t.descripcion,
           'incluye',            t.incluye,
           'activo',             t.activo,
           'entradas_incluidas', t.manillas,
           'incluye_entradas',   t.manillas > 0,
           'comision_rrpp',      t.comision_rrpp,
           'precio',             fp.precio,
           'en_venta',           (fp.tipo_id is not null and t.activo),
           'hay',                t.cupo_total,
           'vendidas',           v.vendidas,
           'reservadas',         v.reservadas,
           'quedan',             case when t.cupo_total is null then null
                                      else greatest(t.cupo_total - v.vendidas, 0) end,
           'recaudado',          v.recaudado,
           'neto',               v.neto,
           'presentadas',        coalesce(p.presentadas, 0))
         order by t.orden, t.nombre), '[]'::jsonb)
    into v_tipos
    from tipo_entrada t
    left join fase_precio fp on fp.fase_id = v_fase and fp.tipo_id = t.id
    left join lateral (
      select coalesce(sum(i.cantidad) filter (where o.estado = 'pagada'), 0)::int as vendidas,
             coalesce(sum(i.cantidad) filter (where o.estado = 'pendiente'
                                                and o.expira_at > now()), 0)::int as reservadas,
             coalesce(sum(i.cantidad * i.precio_unitario)
                        filter (where o.estado = 'pagada'), 0)::numeric(12,2) as recaudado,
             coalesce(sum(o.subtotal) filter (where o.estado = 'pagada'), 0)::numeric(12,2) as neto
        from orden_items i
        join ordenes o on o.id = i.orden_id and o.organizador_id = v_org
       where i.tipo_id = t.id
    ) v on true
    left join lateral (
      select count(*) filter (where r.presentado_at is not null)::int as presentadas
        from mesa_recibos r
        join ordenes o on o.id = r.orden_id and o.estado = 'pagada'
       where r.tipo_id = t.id and r.organizador_id = v_org
    ) p on true
   where t.evento_id = p_evento and t.organizador_id = v_org and t.categoria = 'mesa';

  return jsonb_build_object(
    'evento', p_evento,
    'generado_at', now(),
    'tipos', v_tipos,
    -- El total de "hay" y "quedan" solo si TODAS tienen tope: sumar un
    -- "sin tope" daría un número que no significa nada.
    'total', (select jsonb_build_object(
                'tipos',        count(*)::int,
                'con_entradas', count(*) filter (where (x->>'incluye_entradas')::boolean)::int,
                'hay',          case when bool_and(x->'hay' <> 'null'::jsonb)
                                     then sum((x->>'hay')::int) end,
                'vendidas',     coalesce(sum((x->>'vendidas')::int), 0),
                'reservadas',   coalesce(sum((x->>'reservadas')::int), 0),
                'quedan',       case when bool_and(x->'quedan' <> 'null'::jsonb)
                                     then sum((x->>'quedan')::int) end,
                'recaudado',    coalesce(sum((x->>'recaudado')::numeric), 0)::numeric(12,2),
                'neto',         coalesce(sum((x->>'neto')::numeric), 0)::numeric(12,2),
                'presentadas',  coalesce(sum((x->>'presentadas')::int), 0))
                from jsonb_array_elements(v_tipos) x));
end $function$;
revoke execute on function tablero_mesas(uuid) from public, anon;
grant execute on function tablero_mesas(uuid) to authenticated;

comment on function tablero_mesas(uuid) is
  'Tablero de mesas de un evento (0108): por tipo de mesa hay (cupo_total, null = sin tope), vendidas, reservadas (pendientes vivas), quedan, recaudado (al precio pagado), neto (lo del organizador), si incluye entradas y cuantas se presentaron; y el total. Exige puede_editar().';

-- compradores_mesas: un renglón por mesa vendida, aparte de los
-- compradores de entradas. Las reglas de quién ve qué son las de
-- compradores_evento (0068, 0107): admin y staff todo, el relacionador
-- solo lo suyo y nada si el organizador le apagó las ventas. El carnet va
-- completo, como en el panel de 0107. recibo_url es el link de la compra,
-- donde está el QR del recibo.
create or replace function compradores_mesas(p_evento uuid, p_solo_mios boolean default false)
returns jsonb
  language plpgsql stable security definer set search_path = public as $function$
declare
  v_org   uuid    := mi_organizador();
  v_yo    uuid    := auth.uid();
  v_edita boolean := puede_editar();
  v_solo  uuid;
begin
  if v_org is null or v_yo is null then return '[]'::jsonb; end if;
  if not exists (select 1 from eventos e
                  where e.id = p_evento and e.organizador_id = v_org) then
    return '[]'::jsonb;
  end if;
  if not v_edita
     and not coalesce((select rrpp_ve_ventas from organizadores where id = v_org), true) then
    return '[]'::jsonb;
  end if;
  -- Para el que no puede editar, v_solo es SIEMPRE él mismo.
  v_solo := case when not v_edita then v_yo
                 when p_solo_mios then v_yo
                 else null end;

  return (
    select coalesce(jsonb_agg(jsonb_build_object(
             'orden_id',           o.id,
             'tipo_id',            r.tipo_id,
             'tipo',               r.tipo_nombre,
             'incluye',            r.incluye,
             'entradas_incluidas', r.entradas_incluidas,
             'titular_nombre',     o.titular_nombre,
             'titular_ci',         o.titular_ci,
             'titular_ci_ext',     o.titular_ci_ext,
             'email',              o.comprador_email,
             'telefono',           o.comprador_telefono,
             'fecha',              coalesce(o.pagada_at, o.created_at),
             'precio',             it.precio,
             'pagado',             o.subtotal::numeric(12,2),
             'fee',                o.fee::numeric(12,2),
             'total',              o.total::numeric(12,2),
             'rrpp_id',            o.rrpp_id,
             'rrpp_nombre',        pr.nombre,
             'canal',              case when o.rrpp_id is not null then 'rrpp' else 'publico' end,
             'recibo_code',        r.code,
             'recibo_url',         '/orden/?id=' || o.id,
             'presentado_at',      r.presentado_at,
             'entradas',           coalesce(ma.validas, 0),
             'entradas_usadas',    coalesce(ma.usadas, 0),
             -- La mesa física que el equipo le haya dado (asignar_mesa,
             -- 0029). Hoy el panel no reparte, pero la columna existe y
             -- compradores_evento la mostraba para estas mismas compras.
             'mesa_id',            m.id,
             'mesa_etiqueta',      m.etiqueta,
             'mesa_planta',        m.planta)
           order by coalesce(o.pagada_at, o.created_at) desc, o.id), '[]'::jsonb)
      from mesa_recibos r
      join ordenes o on o.id = r.orden_id and o.organizador_id = v_org
      -- acota por organizador: la función corre como definer y la RLS de
      -- perfiles no la frena (0026).
      left join perfiles pr on pr.id = o.rrpp_id and pr.organizador_id = v_org
      left join mesas m on m.id = o.mesa_asignada_id and m.organizador_id = v_org
      left join lateral (
        select i.precio_unitario::numeric(12,2) as precio
          from orden_items i where i.orden_id = o.id and i.tipo_id = r.tipo_id limit 1) it on true
      left join lateral (
        select count(*) filter (where e.estado <> 'anulada')::int as validas,
               count(*) filter (where e.estado = 'usada')::int    as usadas
          from entradas e where e.orden_id = o.id) ma on true
     where r.evento_id = p_evento
       and r.organizador_id = v_org
       and o.estado = 'pagada'
       and (v_solo is null or o.rrpp_id = v_solo));
end $function$;
revoke execute on function compradores_mesas(uuid, boolean) from anon, public;
grant execute on function compradores_mesas(uuid, boolean) to authenticated;

comment on function compradores_mesas(uuid, boolean) is
  'Compradores de mesas de un evento (0108), uno por mesa pagada: tipo, incluye, titular (nombre, CI y extension), correo, telefono, fecha, precio/pagado/fee/total, relacionador, codigo del recibo y su link (/orden/?id=), presentado_at y entradas incluidas usadas. Mismas reglas de visibilidad que compradores_evento.';

-- compradores_evento: el cuerpo de 0107 sin las compras de mesa, que ahora
-- tienen su propia lista. Una compra con mesa es la que tiene un ítem de
-- un tipo 'mesa' (con MESA_SOLA, no lleva otra cosa). Las de la mesa
-- física del plano viejo (mesa_id) siguen acá como siempre.
create or replace function compradores_evento(
  p_evento uuid, p_solo_mios boolean default false
) returns jsonb
  language plpgsql stable security definer set search_path = public as $function$
declare
  v_org   uuid    := mi_organizador();
  v_yo    uuid    := auth.uid();
  v_edita boolean := puede_editar();
  v_solo  uuid;
begin
  if v_org is null or v_yo is null then return '[]'::jsonb; end if;
  if not exists (select 1 from eventos e
                  where e.id = p_evento and e.organizador_id = v_org) then
    return '[]'::jsonb;
  end if;

  -- 0068: al relacionador de un organizador que apagó `rrpp_ve_ventas` no
  -- se le devuelve nada.
  if not v_edita
     and not coalesce((select rrpp_ve_ventas from organizadores where id = v_org), true) then
    return '[]'::jsonb;
  end if;

  -- Quién queda adentro. Para el que no puede editar, v_solo es SIEMPRE
  -- él mismo: p_solo_mios ni se mira.
  v_solo := case when not v_edita then v_yo
                 when p_solo_mios then v_yo
                 else null end;

  return (
    select coalesce(jsonb_agg(jsonb_build_object(
             'orden_id',         o.id,
             'comprador',        o.comprador_nombre,
             'telefono',         o.comprador_telefono,
             'email',            o.comprador_email,
             'productos',        coalesce(it.productos, '[]'::jsonb),
             'detalle',          coalesce(it.detalle, ''),
             'unidades',         coalesce(it.unidades, 0),
             -- Las manillas se cuentan de `entradas`, que es donde una
             -- fila ES una manilla.
             'manillas',         coalesce(ma.manillas, 0),
             'manillas_usadas',  coalesce(ma.usadas, 0),
             'manillas_anuladas',coalesce(ma.anuladas, 0),
             'pagado',           o.subtotal::numeric(12,2),
             'fee',              o.fee::numeric(12,2),
             'total',            o.total::numeric(12,2),
             'fecha',            coalesce(o.pagada_at, o.created_at),
             'rrpp_id',          o.rrpp_id,
             'rrpp_nombre',      pr.nombre,
             'canal',            case when o.rrpp_id is not null then 'rrpp' else 'publico' end,
             'mesa_id',          m.id,
             'mesa_etiqueta',    m.etiqueta,
             'mesa_planta',      m.planta,
             'titular_nombre',   o.titular_nombre,
             'titular_ci',       o.titular_ci,
             'titular_ci_ext',   o.titular_ci_ext)
           order by coalesce(o.pagada_at, o.created_at) desc, o.id), '[]'::jsonb)
      from ordenes o
      left join perfiles pr on pr.id = o.rrpp_id and pr.organizador_id = v_org
      left join mesas m on m.id = o.mesa_asignada_id and m.organizador_id = v_org
      left join lateral (
        select sum(i.cantidad)::int as unidades,
               jsonb_agg(jsonb_build_object(
                 'nombre',    coalesce(t.nombre, 'Mesa ' || m2.etiqueta),
                 'categoria', coalesce(t.categoria, 'mesa'),
                 'cantidad',  i.cantidad,
                 'manillas',  i.cantidad * coalesce(t.manillas, m2.manillas, 1),
                 'precio_unitario', i.precio_unitario::numeric(12,2))
               order by t.orden nulls last, t.nombre nulls last) as productos,
               string_agg(coalesce(t.nombre, 'Mesa ' || m2.etiqueta) ||
                          case when i.cantidad > 1 then ' ×' || i.cantidad else '' end,
                          ' + ' order by t.orden nulls last, t.nombre nulls last) as detalle
          from orden_items i
          left join tipo_entrada t on t.id = i.tipo_id
          left join mesas m2 on m2.id = i.mesa_id
         where i.orden_id = o.id) it on true
      left join lateral (
        select count(*) filter (where e.estado <> 'anulada')::int as manillas,
               count(*) filter (where e.estado = 'usada')::int    as usadas,
               count(*) filter (where e.estado = 'anulada')::int  as anuladas
          from entradas e where e.orden_id = o.id) ma on true
     where o.evento_id = p_evento
       and o.organizador_id = v_org
       and o.estado = 'pagada'
       and (v_solo is null or o.rrpp_id = v_solo)
       -- 0108: las mesas van en compradores_mesas
       and not exists (select 1 from orden_items i2
                         join tipo_entrada t2 on t2.id = i2.tipo_id
                        where i2.orden_id = o.id and t2.categoria = 'mesa'));
end $function$;
revoke execute on function compradores_evento(uuid, boolean) from anon, public;
grant execute on function compradores_evento(uuid, boolean) to authenticated;

-- ── 12. lo que ve el comprador ──────────────────────────────
-- recibo_mesa_orden: el recibo de una orden para /orden/<uuid>, el correo
-- y la confirmación del pago (las tres Edge Functions lo arman igual
-- porque lo arma esto). El carnet va ENMASCARADO: ese link y ese correo
-- se reenvían, y el completo lo ve el guardia en su pantalla (0107). Las
-- condiciones viajan con el recibo para que el texto viva en un solo
-- lugar del lado del servidor. Null si la orden no tiene mesa.
create or replace function recibo_mesa_orden(p_orden uuid) returns jsonb
  language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
           'code',               r.code,
           'tipo',               r.tipo_nombre,
           'incluye',            r.incluye,
           'entradas_incluidas', r.entradas_incluidas,
           'titular',            o.titular_nombre,
           'ci',                 '••' || right(substring(o.titular_ci from '[0-9]{5,10}'), 4)
                                 || coalesce(' ' || o.titular_ci_ext, ''),
           'email',              o.comprador_email,
           'estado',             case when o.estado = 'pagada' then 'valida' else 'anulada' end,
           'presentado_at',      r.presentado_at,
           'condiciones',        jsonb_build_array('Si no te presentás con entrada, perdés la mesa.',
                                                   'Sin devolución si no vas.'))
    from mesa_recibos r
    join ordenes o on o.id = r.orden_id
   where r.orden_id = p_orden
$$;
revoke execute on function recibo_mesa_orden(uuid) from public, anon, authenticated;
grant execute on function recibo_mesa_orden(uuid) to service_role;

comment on function recibo_mesa_orden(uuid) is
  'El recibo de la mesa de una orden para el comprador (0108): code (QR EVT:<evento>:<code>), tipo, incluye, entradas_incluidas, titular, ci ENMASCARADO, email, estado, presentado_at y condiciones. Null si la orden no tiene mesa. Solo service_role: la usan las Edge Functions orden, estado-orden y enviar-entradas.';

-- mis_compras: la de 0049 con la mesa de cada compra, para que "Mis
-- entradas" no muestre una mesa sin entradas como una compra vacía.
create or replace function mis_compras() returns jsonb
  language sql stable security definer set search_path = public as $function$
  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'id',          o.id,
        'evento',      e.nombre,
        'organizador', g.nombre,
        'org',         g.slug,
        'slug',        e.slug,
        'lugar',       e.lugar,
        'fecha',       to_char(e.fecha, 'YYYY-MM-DD'),
        'hora_inicio', to_char(e.hora_inicio, 'HH24:MI'),
        'arte_url',    e.arte_url,
        'flyer_url',   e.flyer_url,
        'entradas',    (select count(*) from entradas t
                         where t.orden_id = o.id and t.estado <> 'anulada'),
        'mesa',        (select jsonb_build_object('tipo', r.tipo_nombre, 'code', r.code,
                                                  'entradas_incluidas', r.entradas_incluidas)
                          from mesa_recibos r where r.orden_id = o.id),
        'pagada_at',   o.pagada_at
      )
      order by e.fecha desc nulls last, o.pagada_at desc
    ),
    '[]'::jsonb)
  from ordenes o
  join eventos e       on e.id = o.evento_id
  join organizadores g on g.id = o.organizador_id
  where auth.uid() is not null
    and o.comprador_user_id = auth.uid()
    and o.estado = 'pagada'
$function$;
revoke execute on function mis_compras() from public, anon;
grant execute on function mis_compras() to authenticated;

-- Vacío o la migración se queda a medias.
select * from chequeo_funciones_sin_guardia();
