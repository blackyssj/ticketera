-- 0010 — emitir_orden(). Tres caminos distintos llaman acá (callback, retorno
-- del navegador, barrido) y ninguno confía en el otro: por eso lo primero es
-- "¿ya está pagada?". El monto se compara SIEMPRE: emitir por un monto
-- distinto al cobrado no se deshace, porque la persona ya entró.
create function emitir_orden(
  p_orden uuid, p_monto_cobrado numeric default null, p_pago_ref text default null
) returns jsonb
  language plpgsql volatile security definer set search_path = public as $function$
declare o ordenes; v_n int; v_it record; i int;
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

  if p_monto_cobrado is not null and p_monto_cobrado <> o.total then
    update ordenes set estado = 'revision_manual', pago_ref = coalesce(p_pago_ref, pago_ref)
     where id = p_orden;
    return jsonb_build_object('ok', false, 'motivo', 'MONTO',
                              'esperado', o.total, 'cobrado', p_monto_cobrado);
  end if;

  for v_it in select * from orden_items where orden_id = p_orden loop
    if v_it.tipo_id is not null then
      for i in 1 .. v_it.cantidad loop
        insert into entradas (organizador_id, evento_id, orden_id, code, canal,
                              tipo_id, fase_id, cliente, precio)
        values (o.organizador_id, o.evento_id, p_orden, nuevo_code(), 'publico',
                v_it.tipo_id, v_it.fase_id, o.comprador_nombre, v_it.precio_unitario);
      end loop;
    else
      -- una mesa emite una entrada por manilla: la puerta escanea personas
      insert into entradas (organizador_id, evento_id, orden_id, code, canal,
                            mesa_id, cliente, precio)
      select o.organizador_id, o.evento_id, p_orden, nuevo_code(), 'publico',
             m.id, o.comprador_nombre, 0
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
