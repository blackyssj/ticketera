-- ============================================================
-- 0064 — la comisión también puede salir de adentro del precio
--
-- Hasta hoy el cargo por servicio se le SUMA al comprador: una entrada
-- de 70 se cobra 75, el organizador recibe 70 y nosotros 5. Sirve cuando
-- el organizador quiere publicar un precio redondo y que el cargo se vea
-- aparte.
--
-- No sirve para el trato que se cierra al revés: "publicá 70, el
-- comprador paga 70 y vos te quedás con tu porcentaje". Ahí la comisión
-- sale de adentro — el comprador paga 70, nosotros 4,90 y el organizador
-- 65,10. Es un acuerdo comercial distinto, no una cuenta distinta, y el
-- sistema tiene que saber hacer los dos porque la tarifa la negocia cada
-- cliente.
--
-- ── la idea que hace que esto sea chico ─────────────────────
--
-- La tentación es que cada consulta de plata pregunte en qué modo está el
-- organizador. Serían siete lugares —crear_orden, disponible_de,
-- liquidacion, el cierre, el resumen, el panel, la página— y bastaría con
-- que uno se olvidara para que la pantalla prometa una plata que el pago
-- no gira.
--
-- En vez de eso se fija el significado de las columnas, igual en los dos
-- modos:
--
--     subtotal = LO DEL ORGANIZADOR
--     fee      = LO DE TICKETAZO
--     total    = LO QUE PAGA EL COMPRADOR   (siempre subtotal + fee)
--
-- Lo único que cambia entre modos es de dónde sale cada uno a partir del
-- precio publicado. Con eso, todo lo que ya estaba escrito —el
-- disponible, la liquidación, el cierre, el giro del liquidador— sigue
-- funcionando sin tocarse: ya sumaban `subtotal` para el organizador y
-- `fee` para nosotros. Esta migración toca UNA función.
--
-- ── por qué el redondeo es distinto en cada modo ────────────
--
-- Sumada, el fee se redondea a bolivianos enteros y el redondeo lo
-- absorbe el comprador: paga un peso más y el total queda redondo, que
-- en una puerta con efectivo importa.
--
-- Descontada, el que absorbe el redondeo es el organizador, porque es de
-- su plata que estamos sacando. Ahí se redondea a centavos: quedarnos con
-- 5 en vez de 4,90 son diez centavos por entrada que nadie acordó, y en
-- tres mil entradas son trescientos bolivianos.
--
-- ── el tope ─────────────────────────────────────────────────
--
-- La comisión descontada nunca puede pasar el precio. Con un fijo por
-- transacción alto y una entrada barata, el organizador terminaría
-- debiendo plata por haber vendido. Se acota al precio y listo.
--
-- Arranca en 'sobre' para todos: es lo que están vendiendo hoy Amstel y
-- Distrito Ferial, y un default que cambia precios en caliente no es un
-- default.
-- ============================================================

alter table organizadores
  add column if not exists comision_modo text not null default 'sobre';

do $$ begin
  alter table organizadores add constraint organizadores_comision_modo_check
    check (comision_modo in ('sobre','adentro'));
exception when duplicate_object then null; end $$;

comment on column organizadores.comision_modo is
  'sobre = el cargo por servicio se le suma al comprador y el organizador recibe el precio entero. adentro = el comprador paga el precio publicado y la comision sale de ahi. En los dos casos subtotal es lo del organizador, fee lo de TICKETAZO y total lo que paga el comprador.';

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

  insert into ordenes (organizador_id, evento_id, client_key, expira_at,
                       comprador_nombre, comprador_email, comprador_telefono,
                       subtotal, fee, total, ip_hash, rrpp_id)
  values (v_org, p_evento, p_client_key, now() + interval '10 minutes',
          p_comprador->>'nombre', p_comprador->>'email', p_comprador->>'telefono',
          0, 0, 0, p_ip_hash, p_rrpp)
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
      select fp.precio, fp.cupo into v_precio, v_cupo
        from fase_precio fp join tipo_entrada te on te.id = fp.tipo_id
       where fp.fase_id = v_fase and fp.tipo_id = v_tipo and te.activo
       for update of fp;
      if not found then raise exception 'TIPO_NO_VENDIBLE: ese tipo no se vende en la fase abierta'; end if;
      if v_cupo is not null then
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

  -- La única línea que cambia esta migración: si no hay nada que cobrar, no
  -- hay cargo por servicio. Antes daba 0 sólo por casualidad —porque hoy el
  -- fijo y el piso están en cero—; ahora lo da por construcción.
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
  'Crea la orden y congela los precios. Segun organizadores.comision_modo el cargo por servicio se le suma al comprador o sale de adentro del precio; en los dos casos subtotal queda siendo lo del organizador, fee lo de TICKETAZO y total lo que se cobra.';

-- La pagina publica necesita saber el modo para no anunciar un cargo que
-- no existe. Se agrega al organizador, que es donde vive la tarifa.
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
      'comision_modo', v_o.comision_modo),
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

-- ── el interruptor desde el panel ───────────────────────────
-- Solo admin, igual que el pago automatico: define cuanto cobra la
-- plataforma y cuanto recibe el cliente.
drop function if exists guardar_comision_modo(text);
create function guardar_comision_modo(p_modo text) returns jsonb
  language plpgsql volatile security definer set search_path = public as $function$
declare v_org uuid := mi_organizador(); o organizadores;
begin
  if mi_rol() <> 'admin' then raise exception 'Sin permiso'; end if;
  if p_modo not in ('sobre','adentro') then
    return jsonb_build_object('ok', false, 'motivo', 'Modo desconocido.');
  end if;

  update organizadores set comision_modo = p_modo where id = v_org returning * into o;

  return jsonb_build_object('ok', true, 'modo', o.comision_modo, 'motivo',
    case when o.comision_modo = 'adentro'
      then format('El comprador paga el precio publicado y se descuenta el %s%%.',
                  round(o.fee_pct * 100, 2))
      else format('Al comprador se le suma el %s%% sobre el precio publicado.',
                  round(o.fee_pct * 100, 2)) end);
end $function$;
revoke execute on function guardar_comision_modo(text) from anon, public;
grant execute on function guardar_comision_modo(text) to authenticated;

comment on function guardar_comision_modo(text) is
  'Cambia si el cargo por servicio se le suma al comprador o sale de adentro del precio. Solo admin: define cuanto recibe el cliente por cada entrada.';
