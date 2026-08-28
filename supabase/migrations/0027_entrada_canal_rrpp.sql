-- ============================================================
-- 0027 — la entrada se acuerda de quién la vendió
--
-- `entradas.canal` nació con este comentario en 0007: "Dato propio, nunca
-- deducido de rrpp_id is null". Y hasta acá emitir_orden lo escribía
-- siempre 'publico', con rrpp_id en null, incluso cuando la orden venía
-- con un relacionador resuelto (0025). O sea: el dato propio existía y
-- mentía, que es peor que no tenerlo — el que lo lea no tiene forma de
-- saber que está mal.
--
-- Importa para la puerta (bloque 6), que muestra de dónde salió cada
-- manilla cuando la escanea. mis_ventas() (0026) no lo necesita porque
-- une por la orden a propósito, y sigue haciéndolo: esto no le agrega
-- una segunda fuente de verdad, le agrega el dato para quien lo mira de
-- a una entrada.
--
-- El histórico también se corrige: las entradas ya emitidas de órdenes
-- con rrpp_id se rellenan. Son pocas y es el mismo dato, no una
-- reinterpretación.
-- ============================================================

create or replace function emitir_orden(
  p_orden uuid, p_monto_cobrado numeric default null, p_pago_ref text default null
) returns jsonb
  language plpgsql volatile security definer set search_path = public as $function$
declare o ordenes; v_n int; v_it record; i int; v_manillas int; v_canal text;
begin
  select * into o from ordenes where id = p_orden for update;
  if not found then raise exception 'ORDEN_INEXISTENTE: %', p_orden; end if;

  if o.estado = 'pagada' then
    select count(*) into v_n from entradas where orden_id = p_orden;
    return jsonb_build_object('ok', true, 'orden', p_orden, 'entradas', v_n, 'repetida', true);
  end if;
  if o.estado in ('anulada','revision_manual') then
    return jsonb_build_object('ok', false, 'motivo', upper(o.estado));
  end if;

  if o.expira_at <= now() then
    update ordenes set estado = 'vencida' where id = p_orden and estado = 'pendiente';
    return jsonb_build_object('ok', false, 'motivo', 'VENCIDA');
  end if;

  if p_monto_cobrado is not null and p_monto_cobrado <> o.total then
    update ordenes set estado = 'revision_manual', pago_ref = coalesce(p_pago_ref, pago_ref)
     where id = p_orden;
    return jsonb_build_object('ok', false, 'motivo', 'MONTO',
                              'esperado', o.total, 'cobrado', p_monto_cobrado);
  end if;

  -- Se decide una vez, antes del bucle: todas las entradas de una orden
  -- vienen del mismo lugar.
  v_canal := case when o.rrpp_id is not null then 'rrpp' else 'publico' end;

  for v_it in select * from orden_items where orden_id = p_orden loop
    if v_it.tipo_id is not null then
      -- cuánta gente entra con UNA unidad de este tipo
      select coalesce(manillas, 1) into v_manillas from tipo_entrada where id = v_it.tipo_id;
      for i in 1 .. (v_it.cantidad * greatest(v_manillas, 1)) loop
        insert into entradas (organizador_id, evento_id, orden_id, code, canal,
                              tipo_id, fase_id, rrpp_id, cliente, precio)
        values (o.organizador_id, o.evento_id, p_orden, nuevo_code(), v_canal,
                v_it.tipo_id, v_it.fase_id, o.rrpp_id, o.comprador_nombre,
                v_it.precio_unitario);
      end loop;
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
  return jsonb_build_object('ok', true, 'orden', p_orden, 'entradas', v_n, 'repetida', false);
end $function$;
revoke execute on function emitir_orden(uuid, numeric, text) from anon, public;

-- El histórico. Idempotente: la segunda corrida no encuentra nada que hacer.
update entradas e
   set rrpp_id = o.rrpp_id,
       canal   = 'rrpp'
  from ordenes o
 where o.id = e.orden_id
   and o.rrpp_id is not null
   and e.rrpp_id is null;
