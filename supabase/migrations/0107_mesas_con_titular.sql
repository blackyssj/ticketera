-- ============================================================
-- 0107 — las mesas se cargan desde el panel y van a nombre de alguien
--
-- Una mesa o combo ya era un tipo_entrada con categoria = 'mesa' (0015):
-- se vende por la misma tubería que una entrada, emite una manilla por
-- persona y queda atribuida al relacionador del link (?r=). Lo que no
-- había era todo lo demás:
--
--   · Crearla pedía SQL. El panel solo creaba tipos 'entrada' de una
--     manilla; personas, cantidad y precio no se podían decir desde ahí.
--   · Nadie sabía a nombre de quién iba. La mesa es UNA reserva para un
--     grupo y en la puerta preguntan por la persona que la reservó, con
--     su carnet. El comprador puede ser otro (la amiga que paga con su
--     QR), así que el titular es un dato aparte del comprador.
--   · La comisión del relacionador contaba manillas: una mesa de diez
--     personas le pagaba diez comisiones. En Plataforma Puerta ya pasó
--     una vez contar por fila (mesas: no sumar por fila) y se pagó doble.
--
-- ── lo que decidió el dueño, y por qué así ──────────────────
--
-- 1) UNA mesa por compra. Un titular por orden alcanza si la orden lleva
--    una sola mesa; con dos, la segunda quedaría a nombre de alguien que
--    no la reservó. Las entradas sueltas se siguen pudiendo sumar a la
--    misma compra. La regla vive en crear_orden (la que cobra); el front y
--    crear-orden la repiten para avisar antes, no en lugar de esto.
--
-- 2) El titular va en `ordenes` (titular_nombre, titular_ci,
--    titular_ci_ext) y no en cada entrada: es UNA persona por reserva.
--    entradas.cliente sigue siendo el comprador, como hasta hoy, y
--    emitir_orden no se toca. Donde hace falta el titular se cruza por la
--    orden.
--
-- 3) La comisión de una mesa es por MESA, no por manilla:
--    tipo_entrada.comision_rrpp (Bs fijos por unidad) o, si está vacía,
--    la comisión de siempre de ese relacionador UNA vez por mesa. Las
--    entradas sueltas siguen exactamente con la cuenta de hoy.
--
-- 4) El carnet completo es dato personal de un tercero. Lo ven: el panel
--    (admin y staff, y el relacionador en SUS ventas) y la puerta EN LÍNEA.
--    El padrón offline vive en el localStorage del teléfono del portero:
--    ahí va enmascarado (últimos 4 dígitos y extensión). Nunca en
--    /orden/<uuid>, en los correos, en la imagen de la entrada ni en el
--    localStorage del comprador.
--
-- 5) Bowie y BurTown (espejo de Puerta, 0103): sus mesas se venden allá.
--    guardar_mesa los rechaza con una frase y el panel ni ofrece el botón.
--
-- ── dos cosas que se arreglan de paso, porque sin ellas la mesa vende mal ──
--
-- · Stock del evento entero (tipo_entrada.cupo_total). El cupo vive por
--   fase: con cinco mesas y tres fases, "5" en cada fase son quince mesas.
--   cupo_total cuenta lo vendido en TODAS las fases. Solo lo usa la mesa;
--   con null (todo lo que existe hoy) nada cambia.
--
-- · Una mesa sin vender ya no traba la fase. fase_vigente (0094) deja una
--   fase abierta mientras CUALQUIER tipo tenga cupo sin pagar: en una
--   fiesta que sube de precio por cantidad (LÜMEN, Distrito Ferial), una
--   mesa sin vender dejaría la General en "agotado" y la fase siguiente
--   sin abrir nunca. Ahora una fase que vende entradas pasa a la siguiente
--   cuando se le terminan las ENTRADAS. Si ya no queda ninguna fase con
--   entradas, se sigue vendiendo lo que queda de mesas (en la última fase
--   que las tenga), como hoy.
--
-- Al aplicar esto no había ningún tipo con categoria = 'mesa' en
-- producción (consulta de solo lectura del 18/10), así que la exigencia
-- del titular sale ya acá y no hizo falta separarla en otra migración.
-- ============================================================

-- La migración toca `ordenes`, que es la tabla del checkout. Si una
-- consulta larga la tiene tomada, mejor fallar a los 15 s y reintentar que
-- dejar la venta entera esperando detrás del ALTER.
set local lock_timeout = '15s';

-- ── 1. columnas ─────────────────────────────────────────────
-- Todas nullable y sin default: en Postgres eso es solo catálogo, no
-- reescribe la tabla. Las órdenes viejas quedan con null y el panel y la
-- puerta muestran lo de siempre.
alter table ordenes
  add column if not exists titular_nombre text,
  add column if not exists titular_ci     text,
  add column if not exists titular_ci_ext text;

alter table tipo_entrada
  add column if not exists cupo_total    int,
  add column if not exists comision_rrpp numeric(12,2);

-- Las mismas reglas que crear_orden, crear-orden y la página: la base es
-- la última palabra y un insert a mano tampoco puede guardar un carnet
-- roto. NOT VALID + VALIDATE porque es el patrón seguro para una tabla
-- con datos; acá las columnas nacen vacías y valida en el acto.
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'ordenes_titular_ci_ck') then
    alter table ordenes add constraint ordenes_titular_ci_ck
      check (titular_ci is null or titular_ci ~ '^(E-)?[0-9]{5,10}(-[0-9A-Z]{2})?$') not valid;
  end if;
  if not exists (select 1 from pg_constraint where conname = 'ordenes_titular_ext_ck') then
    alter table ordenes add constraint ordenes_titular_ext_ck
      check (titular_ci_ext is null
             or titular_ci_ext in ('LP','CB','SC','OR','PT','CH','TJ','BN','PD')) not valid;
  end if;
  -- nombre y carnet van juntos; la extensión sola no significa nada
  if not exists (select 1 from pg_constraint where conname = 'ordenes_titular_par_ck') then
    alter table ordenes add constraint ordenes_titular_par_ck
      check ((titular_nombre is null) = (titular_ci is null)
             and (titular_ci_ext is null or titular_ci is not null)) not valid;
  end if;
  -- nombre y apellido: dos palabras como mínimo, ya normalizado
  if not exists (select 1 from pg_constraint where conname = 'ordenes_titular_nombre_ck') then
    alter table ordenes add constraint ordenes_titular_nombre_ck
      check (titular_nombre is null
             or (titular_nombre ~ '^\S+( \S+)+$' and char_length(titular_nombre) <= 80)) not valid;
  end if;
  if not exists (select 1 from pg_constraint where conname = 'tipo_entrada_cupo_total_ck') then
    alter table tipo_entrada add constraint tipo_entrada_cupo_total_ck
      check (cupo_total is null or cupo_total > 0) not valid;
  end if;
  if not exists (select 1 from pg_constraint where conname = 'tipo_entrada_comision_rrpp_ck') then
    alter table tipo_entrada add constraint tipo_entrada_comision_rrpp_ck
      check (comision_rrpp is null or comision_rrpp >= 0) not valid;
  end if;
end $$;
alter table ordenes validate constraint ordenes_titular_ci_ck;
alter table ordenes validate constraint ordenes_titular_ext_ck;
alter table ordenes validate constraint ordenes_titular_par_ck;
alter table ordenes validate constraint ordenes_titular_nombre_ck;
alter table tipo_entrada validate constraint tipo_entrada_cupo_total_ck;
alter table tipo_entrada validate constraint tipo_entrada_comision_rrpp_ck;

comment on column ordenes.titular_nombre is
  'A nombre de quién va la mesa de esta orden (0107). Solo en órdenes con una mesa; null en las de entradas. Puede no ser el comprador.';
comment on column ordenes.titular_ci is
  'Carnet del titular de la mesa, normalizado: número de 5 a 10 dígitos, E- adelante si es extranjero, -XX si tiene complemento. Dato personal de un tercero: completo solo en el panel y en la puerta en línea; el padrón offline lo lleva enmascarado.';
comment on column ordenes.titular_ci_ext is
  'Extensión del carnet del titular (LP, CB, SC, OR, PT, CH, TJ, BN, PD). Opcional: los carnets nuevos de número único no la llevan.';
comment on column tipo_entrada.cupo_total is
  'Cuántas unidades hay en TODO el evento, sumando todas las fases (0107). El cupo de fase_precio es por fase y no sirve para decir "hay cinco mesas". Null = sin tope de evento.';
comment on column tipo_entrada.comision_rrpp is
  'Solo mesas: Bs fijos que cobra el relacionador por cada mesa vendida con su link (0107). Null = su comisión de siempre, una vez por mesa y no por manilla.';

-- ── 2. disponibilidad_tipo: el cupo de la fase y el del evento ──
-- El cuerpo de 0065 tal cual, más el tope del evento. Con cupo_total null
-- devuelve exactamente lo de antes. Con cupo_total, lo menor de las dos
-- cuentas: lo que queda en la fase y lo que queda en el evento (pagado y
-- apartado por pendientes vivas, en cualquier fase, igual que el cupo de
-- la fase).
create or replace function disponibilidad_tipo(p_fase uuid, p_tipo uuid) returns int
  language plpgsql stable security definer set search_path = public as $function$
declare v_cupo int; v_emitidas int; v_retenidas int;
        v_total int; v_resto int; v_usadas int;
begin
  select cupo into v_cupo from fase_precio where fase_id = p_fase and tipo_id = p_tipo;
  if not found then return 0; end if;
  select cupo_total into v_total from tipo_entrada where id = p_tipo;
  if v_cupo is null and v_total is null then return null; end if;

  if v_cupo is not null then
    select coalesce(sum(i.cantidad), 0) into v_emitidas
      from orden_items i join ordenes o on o.id = i.orden_id
     where i.fase_id = p_fase and i.tipo_id = p_tipo and o.estado = 'pagada';

    select coalesce(sum(i.cantidad), 0) into v_retenidas
      from orden_items i join ordenes o on o.id = i.orden_id
     where i.fase_id = p_fase and i.tipo_id = p_tipo
       and o.estado = 'pendiente' and o.expira_at > now();

    -- Las cortesías ya NO se restan (0065). Se emiten sin orden, así que
    -- no entran por ninguno de los dos caminos de arriba y no hay nada que
    -- excluir: alcanza con haber sacado el tercer conteo.
    v_resto := greatest(v_cupo - v_emitidas - v_retenidas, 0);
  end if;
  if v_total is null then return v_resto; end if;

  select coalesce(sum(i.cantidad), 0) into v_usadas
    from orden_items i join ordenes o on o.id = i.orden_id
   where i.tipo_id = p_tipo
     and (o.estado = 'pagada' or (o.estado = 'pendiente' and o.expira_at > now()));

  return case when v_resto is null then greatest(v_total - v_usadas, 0)
              else least(v_resto, greatest(v_total - v_usadas, 0)) end;
end $function$;
-- Sin grant a `authenticated`, como en 0051/0065: no mira quién pregunta.
revoke execute on function disponibilidad_tipo(uuid, uuid) from anon, public, authenticated;

comment on function disponibilidad_tipo(uuid, uuid) is
  'Cuantas unidades quedan para VENDER de un tipo en una fase. Resta lo vendido y lo retenido por ordenes pendientes vivas. Con tipo_entrada.cupo_total (0107) devuelve lo menor entre lo que queda en la fase y lo que queda en todo el evento. Las cortesias no restan: el cupo es el limite de venta, no el aforo.';

-- ── 3. fase_vigente: una mesa no traba la fase de las entradas ──
-- Dos pasadas. La primera es la de 0094 con una condición más: en una fase
-- que vende entradas, solo las ENTRADAS la sostienen abierta. Para un
-- evento sin mesas es la consulta de siempre, con el mismo orden y el
-- mismo corte, y la segunda pasada nunca encuentra nada que la primera no
-- haya encontrado.
--
-- La segunda solo cuenta cuando ya no queda ninguna fase con entradas
-- para vender: ahí lo que queda son mesas, y se siguen vendiendo en la
-- ÚLTIMA fase que todavía las tenga — la de precio más nuevo, no la
-- preventa que ya pasó. Sin esto, la General agotada en la última fase
-- dejaba las mesas sin poder venderse.
--
-- Lo que se vende contra cupo_total (las mesas) deja de sostener una fase
-- cuando se pagó el total del evento, aunque en esa fase no se haya
-- vendido ninguna.
create or replace function fase_vigente(p_evento uuid) returns uuid
  language sql stable security definer set search_path = public as $$
  select coalesce(
    (select f.id from evento_fase f
      where f.evento_id = p_evento and f.activo
        and (f.desde is null or f.desde <= now())
        and (f.hasta is null or f.hasta >  now())
        and (mi_organizador() is null or f.organizador_id = mi_organizador())
        and exists (
          select 1
            from fase_precio fp
            join tipo_entrada t on t.id = fp.tipo_id
           where fp.fase_id = f.id
             and t.activo and t.en_cartelera
             and (fp.cupo is null or
                  (select coalesce(sum(i.cantidad), 0)
                     from orden_items i join ordenes o on o.id = i.orden_id
                    where i.fase_id = f.id and i.tipo_id = fp.tipo_id
                      and o.estado = 'pagada') < fp.cupo)
             and (t.cupo_total is null or
                  (select coalesce(sum(i.cantidad), 0)
                     from orden_items i join ordenes o on o.id = i.orden_id
                    where i.tipo_id = fp.tipo_id and o.estado = 'pagada') < t.cupo_total)
             -- 0107: si la fase vende entradas, la sostienen solo ellas
             and (t.categoria = 'entrada' or not exists (
                   select 1 from fase_precio fp2
                     join tipo_entrada t2 on t2.id = fp2.tipo_id
                    where fp2.fase_id = f.id and t2.categoria = 'entrada'
                      and t2.activo and t2.en_cartelera)))
      order by f.orden
      limit 1),
    (select f.id from evento_fase f
      where f.evento_id = p_evento and f.activo
        and (f.desde is null or f.desde <= now())
        and (f.hasta is null or f.hasta >  now())
        and (mi_organizador() is null or f.organizador_id = mi_organizador())
        and exists (
          select 1
            from fase_precio fp
            join tipo_entrada t on t.id = fp.tipo_id
           where fp.fase_id = f.id
             and t.activo and t.en_cartelera
             and (fp.cupo is null or
                  (select coalesce(sum(i.cantidad), 0)
                     from orden_items i join ordenes o on o.id = i.orden_id
                    where i.fase_id = f.id and i.tipo_id = fp.tipo_id
                      and o.estado = 'pagada') < fp.cupo)
             and (t.cupo_total is null or
                  (select coalesce(sum(i.cantidad), 0)
                     from orden_items i join ordenes o on o.id = i.orden_id
                    where i.tipo_id = fp.tipo_id and o.estado = 'pagada') < t.cupo_total))
      order by f.orden desc
      limit 1))
$$;
revoke execute on function fase_vigente(uuid) from anon, public;
grant execute on function fase_vigente(uuid) to authenticated;

comment on function fase_vigente(uuid) is
  'La fase abierta ahora: la primera por orden dentro de su ventana de fechas que todavia tenga cupo SIN PAGAR en algo real para vender (activo y en_cartelera). Las reservas pendientes no la cierran (0094). En una fase que vende entradas, solo las entradas la sostienen; si no queda ninguna fase con entradas, la ultima que todavia tenga mesas (0107).';

-- ── 4. crear_orden: una mesa por compra y su titular ────────
-- El cuerpo vivo de 0064 (las dos formas de cobrar la comisión y el fee
-- en cero sin nada que cobrar) con tres cambios marcados 0107:
--   a) antes de crear la orden se cuenta cuántas mesas trae: más de una
--      es UNA_MESA; una exige titular (FALTA_TITULAR / CI_INVALIDO).
--   b) la orden guarda el titular, normalizado. Sin mesa, null: las
--      órdenes de entradas quedan exactamente como hoy.
--   c) el tope del evento (cupo_total) se mira aunque la fase no tenga
--      cupo propio.
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

  -- 0107 a) Cuántas mesas trae: unidades de tipos 'mesa' de este evento,
  -- más las del camino viejo por mesa_id (la mesa física), que también son
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

  if v_mesas = 1 then
    -- Se normaliza acá aunque crear-orden ya lo haga: la base no confía en
    -- quien la llama, y los CHECK de `ordenes` exigen esta forma exacta.
    v_tit_nombre := btrim(left(regexp_replace(btrim(coalesce(p_comprador->>'titular_nombre', '')),
                                              '\s+', ' ', 'g'), 80));
    v_tit_ci := regexp_replace(upper(regexp_replace(coalesce(p_comprador->>'titular_ci', ''),
                                                    '[\s.]', '', 'g')), '^-+|-+$', '', 'g');
    v_tit_ext := nullif(upper(btrim(coalesce(p_comprador->>'titular_ci_ext', ''))), '');
    -- Los alias que la gente escribe: Beni con E, Pando con A o N.
    v_tit_ext := case v_tit_ext when 'BE' then 'BN' when 'PA' then 'PD' when 'PN' then 'PD'
                                else v_tit_ext end;
    if v_tit_nombre !~ '^\S+( \S+)+$' or v_tit_ci = '' then
      raise exception 'FALTA_TITULAR: la mesa va a nombre de alguien: falta su nombre y apellido o su carnet';
    end if;
    -- El carnet no va en el mensaje: los errores terminan en logs.
    if v_tit_ci !~ '^(E-)?[0-9]{5,10}(-[0-9A-Z]{2})?$'
       or (v_tit_ext is not null
           and v_tit_ext not in ('LP','CB','SC','OR','PT','CH','TJ','BN','PD')) then
      raise exception 'CI_INVALIDO: el carnet del titular no tiene un formato valido';
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
          p_comprador->>'nombre', p_comprador->>'email', p_comprador->>'telefono',
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
  'Crea la orden y congela los precios. Segun organizadores.comision_modo el cargo por servicio se le suma al comprador o sale de adentro del precio; en los dos casos subtotal queda siendo lo del organizador, fee lo de TICKETAZO y total lo que se cobra. Una mesa por orden como maximo (UNA_MESA) y, si la hay, p_comprador trae titular_nombre, titular_ci y titular_ci_ext (FALTA_TITULAR / CI_INVALIDO) (0107).';

-- ── 5. evento_publico: lo mismo que fase_vigente, en la lista de fases ──
-- La definición viva de 0104 con dos cambios marcados 0107:
--   · el precio de un tipo con tope de evento dice cuánto queda aunque la
--     fase no tenga cupo propio (la grilla del panel lo puede vaciar);
--   · la lista de fases cuenta, en una fase que vende entradas, solo las
--     entradas: es el mismo criterio que fase_vigente, y sin él una fase
--     que ya pasó con una mesa sin vender aparecía como "próxima" y su
--     precio anunciado era el de la mesa.
-- Para un evento sin mesas no cambia una coma de la respuesta.
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
               -- 0107: el tope del evento cuenta como tope aunque la fase no tenga
               'tipo_id', p.tipo_id, 'precio', p.precio, 'cupo', coalesce(p.cupo, t.cupo_total),
               'disponible', case when p.cupo is null and t.cupo_total is null then null
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
                     coalesce(min(p.precio) filter (where (p.cupo is null and t.cupo_total is null)
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
                     -- 0107: en una fase con entradas, las mesas no cuentan
                     and (t.categoria = 'entrada' or not exists (
                           select 1 from fase_precio p2
                             join tipo_entrada t2 on t2.id = p2.tipo_id
                            where p2.fase_id = f.id and t2.categoria = 'entrada'
                              and t2.activo and t2.en_cartelera))
               where f.evento_id = v_e.id and f.activo
               group by f.id) x), '[]'::jsonb));
end $function$;
revoke execute on function evento_publico(text, text) from public, anon, authenticated;
grant execute on function evento_publico(text, text) to service_role;

-- ── 6. ¿es espejo de Puerta? (para el panel) ────────────────
-- evento_espejo() es solo de service_role porque no mira de quién es el
-- evento. El panel necesita saberlo para no ofrecer «Crear mesa o combo»
-- en Bowie y BurTown, así que esta versión contesta solo por los eventos
-- del organizador de la sesión: de uno ajeno dice false, igual que de uno
-- que no existe.
create or replace function espejo_de_puerta(p_evento uuid) returns boolean
  language sql stable security definer set search_path = public as $$
  select exists (select 1 from puerta_evento pe
                   join eventos e on e.id = pe.evento_id
                  where pe.evento_id = p_evento
                    and e.organizador_id = mi_organizador())
$$;
revoke execute on function espejo_de_puerta(uuid) from public, anon;
grant execute on function espejo_de_puerta(uuid) to authenticated;

comment on function espejo_de_puerta(uuid) is
  'Si un evento del organizador de la sesion es espejo de Plataforma Puerta (0103). De un evento ajeno o inexistente dice false. Lo usa el panel para no ofrecer mesas donde se venden alla (0107).';

-- ── 7. guardar_mesa: crear o editar una mesa desde el panel ──
-- Una sola llamada hace las tres cosas que antes eran SQL a mano: el tipo
-- con categoria 'mesa' y sus personas, el tope del evento, y el precio en
-- las fases elegidas. En una sola transacción, como guardar_precios.
--
-- A diferencia de guardar_precios, no reemplaza los precios del evento:
-- toca SOLO las filas de esta mesa. Pone el precio en las fases marcadas y
-- se lo saca de las desmarcadas, que es lo que el formulario muestra.
--
-- Las validaciones vuelven como {ok:false, motivo}: es un formulario y el
-- motivo se le muestra tal cual al organizador. El permiso sí revienta,
-- con el mismo 'Sin permiso' de siempre.
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
      'Revisá los números: personas, precio, cantidad y comisión van en cifras.');
  end;

  if char_length(v_nombre) not between 2 and 60 then
    return jsonb_build_object('ok', false, 'motivo', 'Poné un nombre de 2 a 60 letras.');
  end if;
  if char_length(coalesce(v_desc, '')) > 220 or char_length(coalesce(v_incluye, '')) > 220 then
    return jsonb_build_object('ok', false, 'motivo',
      'La frase y lo que incluye van de hasta 220 letras cada una.');
  end if;
  if v_personas is null or v_personas not between 1 and 50 then
    return jsonb_build_object('ok', false, 'motivo', 'Cuántas personas entran: de 1 a 50.');
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

  -- emitir_orden lee las personas del tipo al EMITIR (0038): cambiarlas con
  -- compras hechas cambiaría cuántas manillas recibe una orden que ya se
  -- vendió con otra cantidad. Antes de que haya ventas, se cambia libre.
  if p_tipo is not null and v_personas <> v_t.manillas
     and (exists (select 1 from orden_items where tipo_id = p_tipo)
          or exists (select 1 from entradas where evento_id = p_evento and tipo_id = p_tipo)) then
    return jsonb_build_object('ok', false, 'codigo', 'MESA_CON_VENTAS', 'motivo',
      format('«%s» ya tiene compras con %s personas. Para cambiar cuántos entran, creá otra mesa.',
             v_t.nombre, v_t.manillas));
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
  -- Una que ya tenía fila NO se aplana: la grilla deja poner precio y cupo
  -- distintos por fase, y el formulario muestra uno solo. Pisar sin
  -- preguntar hacía que «Editar mesa» para corregir el «Incluye» dejara la
  -- General a 900 en vez de 1200 (se cobraba de menos), y con «Cuántas hay»
  -- vacío borraba el tope de 3 puesto en la grilla: con los dos topes en
  -- null, disponibilidad_tipo da null y crear_orden deja de contar stock.
  --   · el precio cambia solo si el organizador lo cambió (tocar_precio);
  --   · el cupo de la fase sigue al nuevo cupo_total solo si era el espejo
  --     del anterior (lo que puso este formulario); uno escrito a mano en
  --     la grilla se respeta. v_t es la mesa ANTES del update.
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
  'Crea (p_tipo null) o edita una mesa o combo: tipo_entrada con categoria mesa, personas (manillas), descripcion, incluye, cupo_total, comision_rrpp y su precio en las fases de p_datos.fases (todas las activas si no viene). Toca solo los precios de esa mesa. Editando, una fase que ya tenia fila conserva su precio si p_datos.tocar_precio es false (sin el dato vale true y lo pisa), y su cupo solo sigue a cupo_total si era el espejo del anterior: lo puesto a mano en la grilla no se aplana. Exige puede_editar(); rechaza espejos de Puerta y cambiar personas con compras hechas (0107).';

-- ── 8. personas y categoría quedan quietas después de vender ──
-- La misma regla que guardar_mesa, para el que escribe directo por la API
-- (la RLS de tipos deja a admin y staff tocar cualquier columna). Sin esto,
-- un update de manillas cambia cuántas entradas emite una orden pendiente
-- cuando se paga. El sync de Puerta reescribe esas columnas a propósito y
-- pasa por puerta_sync_activo().
create or replace function tipo_entrada_congelar() returns trigger
  language plpgsql security definer set search_path = public as $$
begin
  if puerta_sync_activo() then return new; end if;
  if exists (select 1 from orden_items where tipo_id = old.id) then
    raise exception 'TIPO_CON_VENTAS: «%» ya tiene compras: no se cambia cuántas personas entran ni si es entrada o mesa. Creá otro producto.', old.nombre;
  end if;
  return new;
end $$;
revoke execute on function tipo_entrada_congelar() from public, anon, authenticated;

drop trigger if exists tipo_entrada_congelar on tipo_entrada;
create trigger tipo_entrada_congelar before update of manillas, categoria on tipo_entrada
  for each row
  when (new.manillas is distinct from old.manillas or new.categoria is distinct from old.categoria)
  execute function tipo_entrada_congelar();

-- ── 9. compradores_evento: con el titular ───────────────────
-- El cuerpo de 0068b con tres claves más. Las reglas de quién ve qué son
-- las de siempre: admin y staff todas las filas, el relacionador solo las
-- suyas (y nada si el organizador le apagó las ventas), así que el carnet
-- completo le llega solo al que vendió esa mesa.
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
  -- se le devuelve nada. Su lista de compradores ES el conteo de sus
  -- ventas —una fila por compra— así que taparle el total de arriba y
  -- dejarle la lista abajo no le tapa nada.
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
             -- El detalle y su versión en una línea, para no obligar a la
             -- pantalla a rearmar el texto (y a que dos pantallas lo
             -- rearmen distinto).
             'productos',        coalesce(it.productos, '[]'::jsonb),
             'detalle',          coalesce(it.detalle, ''),
             'unidades',         coalesce(it.unidades, 0),
             -- Las manillas se cuentan de `entradas`, que es donde una
             -- fila ES una manilla. Multiplicar cantidad × manillas del
             -- tipo daría lo mismo hoy, pero se rompe el día que alguien
             -- edite tipo_entrada.manillas después de emitida la orden.
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
             -- 0107: a nombre de quién va la mesa. Null en compras sin mesa.
             'titular_nombre',   o.titular_nombre,
             'titular_ci',       o.titular_ci,
             'titular_ci_ext',   o.titular_ci_ext)
           order by coalesce(o.pagada_at, o.created_at) desc, o.id), '[]'::jsonb)
      from ordenes o
      -- El join a perfiles acota por organizador igual que en 0026: esta
      -- función corre como definer, así que la RLS de perfiles no la
      -- frena, y un rrpp_id de otro tenant filtraría el nombre de esa
      -- persona.
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
       and (v_solo is null or o.rrpp_id = v_solo));
end $function$;
revoke execute on function compradores_evento(uuid, boolean) from anon, public;
grant execute on function compradores_evento(uuid, boolean) to authenticated;

-- ── 10. la puerta: el titular en línea, enmascarado sin señal ──
-- puerta_entrada es el cuerpo de 0032 (la ficha que arman validar, filtro
-- y deshacer) con el titular y su carnet completo: es la puerta en línea,
-- con un portero logueado, y ahí se compara contra el carnet en la mano.
-- Solo en las manillas de la mesa: la General que vino en la misma compra
-- no es "la mesa de Fulano".
create or replace function puerta_entrada(p_evento uuid, p_code text, p_resultado text)
returns jsonb
  language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
           'resultado', p_resultado,
           'code',      e.code,
           'cliente',   e.cliente,
           'tipo',      coalesce(t.nombre, case when e.mesa_id is not null then 'Mesa' end),
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
  'La ficha de una entrada para la pantalla de la puerta, con el resultado que le pase quien llama. En las manillas de una mesa trae titular y titular_ci (carnet completo: es la puerta en linea) (0107). Cuerpo compartido de validar/filtro/descheckin para que las tres devuelvan la misma forma. No se expone: se llama solo desde ellas.';

-- padron_puerta: la definición viva de 0103 (con el corte de espejo) y,
-- solo en las manillas de una mesa, tn = titular y td = carnet ENMASCARADO
-- (••4567 SC). El padrón se guarda entero en el localStorage del teléfono
-- de la puerta, que se pierde, se presta y se queda en una barra: el
-- carnet completo no viaja por acá. Las claves van solo donde hay mesa
-- para no engordar veinte mil filas con dos null cada una.
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
revoke execute on function padron_puerta(uuid) from anon, public;
grant execute on function padron_puerta(uuid) to authenticated;

comment on function padron_puerta(uuid) is
  'La lista entera de entradas de un evento para que la puerta pueda trabajar sin señal. Vuelve como un jsonb y no como filas porque PostgREST corta en 1000 sin avisar. Claves cortas: c=code, n=cliente, t=tipo, e=estado, u=used_at; en manillas de mesa tn=titular y td=carnet enmascarado (0107). Espejo de Puerta: padron vacio (0103).';

-- ── 11. la comisión de una mesa es por mesa ─────────────────
-- ventas_rrpp_base (0026) es la única cuenta de comisiones: la leen
-- mis_ventas, ventas_por_rrpp, la liquidación, el cierre y el disponible.
-- Cambia en un solo lugar:
--
--   comision = sueltas × comision_de(persona, evento)
--            + Σ por mesa vendida: coalesce(tipo.comision_rrpp, comision_de)
--
-- `sueltas` son las manillas válidas que NO son de un tipo 'mesa': para un
-- evento sin mesas es `entradas` y la cuenta da exactamente lo de antes.
-- Una mesa cuenta mientras le quede alguna manilla sin anular (con las
-- diez anuladas, la mesa se devolvió y no paga); con dos mesas en la misma
-- orden (posibles antes de 0107) se cuentan por manillas válidas / personas,
-- redondeado para arriba.
--
-- `entradas` sigue siendo TODAS las manillas válidas: es lo que la
-- liquidación muestra como "manillas". Tres columnas nuevas al final
-- —sueltas, mesas, comision_mesas— para que la pantalla pueda decir
-- "4 × 15 + 1 mesa" en vez de un "5 × 15" que no da el total.
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
  comision_mesas    numeric(12,2)
)
  language sql stable security definer set search_path = public as $$
  with ordenes_rrpp as (
    select o.id, o.evento_id, o.rrpp_id, o.subtotal,
           (select count(*) from entradas e
             where e.orden_id = o.id and e.estado <> 'anulada')::int as validas,
           coalesce(m.validas, 0)  as validas_mesa,
           coalesce(m.unidades, 0) as mesas,
           coalesce(m.comision, 0) as comision_mesas
      from ordenes o
      -- 0107: las manillas de mesa de la orden, agrupadas por tipo. Para una
      -- orden sin mesas no hay filas y todo queda en cero.
      left join lateral (
        select sum(g.n)::int        as validas,
               sum(g.unidades)::int as unidades,
               sum(g.unidades * coalesce(g.comision_rrpp,
                                         comision_de(o.rrpp_id, o.evento_id))) as comision
          from (select count(*) as n,
                       ceil(count(*)::numeric / greatest(t.manillas, 1))::int as unidades,
                       t.comision_rrpp
                  from entradas e
                  join tipo_entrada t on t.id = e.tipo_id and t.categoria = 'mesa'
                 where e.orden_id = o.id and e.estado <> 'anulada'
                 group by t.id, t.manillas, t.comision_rrpp) g
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
     where r.validas > 0
     group by r.rrpp_id, r.evento_id
  )
  select pe.rrpp_id, pe.evento_id, ev.nombre, ev.fecha,
         pe.entradas, pe.recaudado,
         comision_de(pe.rrpp_id, pe.evento_id)::numeric(12,2),
         (pe.sueltas * comision_de(pe.rrpp_id, pe.evento_id) + pe.comision_mesas)::numeric(12,2),
         pe.sueltas, pe.mesas, pe.comision_mesas::numeric(12,2)
    from por_evento pe
    join eventos ev on ev.id = pe.evento_id
   where ev.organizador_id = mi_organizador()
$$;
revoke execute on function ventas_rrpp_base(uuid, uuid) from public, anon, authenticated;

comment on function ventas_rrpp_base(uuid, uuid) is
  'Cuerpo compartido de mis_ventas() y ventas_por_rrpp() (y de la liquidacion): una fila por (relacionador, evento) con manillas validas, recaudado y comision. La comision es sueltas x comision_de + una por mesa vendida (tipo.comision_rrpp o comision_de) (0107). Acota por mi_organizador() adentro, no por parametro. No se expone.';

-- mis_ventas: la de 0068 con las tres cifras nuevas en el jsonb.
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
             'comision_mesas',    v.comision_mesas)
           order by v.comision desc, v.evento_fecha desc), '[]'::jsonb)
      from ventas_rrpp_base(p_evento, v_yo) v);
end $function$;
revoke execute on function mis_ventas(uuid) from anon, public;
grant execute on function mis_ventas(uuid) to authenticated;

-- ventas_por_rrpp: la de 0026 con las mismas tres cifras.
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
             'comision_mesas',    v.comision_mesas)
           order by v.comision desc, p.nombre), '[]'::jsonb)
      from ventas_rrpp_base(p_evento, null) v
      -- el join también acota por organizador: esta función corre como
      -- definer, así que la RLS de perfiles no la frena, y una orden con
      -- un rrpp_id de otro tenant (que crear-orden no puede producir, pero
      -- la columna sí admite) filtraría el nombre de esa persona.
      join perfiles p on p.id = v.perfil_id and p.organizador_id = mi_organizador());
end $function$;
revoke execute on function ventas_por_rrpp(uuid) from anon, public;
grant execute on function ventas_por_rrpp(uuid) to authenticated;

-- Vacío o la migración se queda a medias.
select * from chequeo_funciones_sin_guardia();
