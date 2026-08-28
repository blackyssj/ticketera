-- ============================================================
-- 0020 — crear_orden() deja de vender tipos desactivados
--
-- El select de fase_precio miraba precio y cupo pero nunca
-- tipo_entrada.activo: con activo = false la orden se creaba igual.
-- evento/index.ts ya los oculta (`if (!t?.activo) continue`) y
-- listo_para_publicar() ya los excluye — crear_orden() era la pieza
-- asimétrica que dejaba comprar lo que la landing ni siquiera muestra.
-- ============================================================

create or replace function crear_orden(
  p_evento uuid, p_items jsonb, p_comprador jsonb default '{}'::jsonb,
  p_client_key uuid default null, p_ip_hash text default null
) returns jsonb
  language plpgsql volatile security definer set search_path = public as $function$
declare
  v_org uuid; v_fase uuid; v_tope int; v_estado text; v_org_row organizadores;
  v_orden uuid; v_sub numeric(12,2) := 0; v_fee numeric(12,2); v_entradas int := 0;
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
                       subtotal, fee, total, ip_hash)
  values (v_org, p_evento, p_client_key, now() + interval '10 minutes',
          p_comprador->>'nombre', p_comprador->>'email', p_comprador->>'telefono',
          0, 0, 0, p_ip_hash)
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

  v_fee := greatest(round(v_sub * v_org_row.fee_pct) + v_org_row.fee_fijo_transaccion, v_org_row.fee_piso);
  update ordenes set subtotal = v_sub, fee = v_fee, total = v_sub + v_fee where id = v_orden;

  return jsonb_build_object('ok', true, 'orden', v_orden, 'subtotal', v_sub,
                            'fee', v_fee, 'total', v_sub + v_fee, 'repetida', false);
end $function$;
revoke execute on function crear_orden(uuid, jsonb, jsonb, uuid, text) from anon, public;
