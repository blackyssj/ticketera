-- ============================================================
-- 0019 — emitir_orden se niega a emitir una orden vencida y no pagada
--
-- vencer_ordenes() (0011) existe desde ese bloque y nadie la llama: sin
-- barrido programado, una orden pendiente pasa su expira_at, pero sigue
-- en estado 'pendiente' en la base. disponibilidad_tipo ya filtra por
-- expira_at > now() (comentario de 0008), así que el cupo se libera solo
-- y otra persona lo compra. Si la primera vuelve a la pestaña vieja y
-- aprieta "Verificar pago" con su pago_ref, emitir_orden no miraba
-- expira_at en absoluto y la emitía igual: el cupo de 1 salió dos veces.
--
-- El arreglo vive en emitir_orden porque es el único paso por el que
-- pasan los tres caminos que confirman una orden (callback, retorno del
-- navegador, barrido) — arreglarlo en uno solo de esos caminos deja los
-- otros dos expuestos. Si la orden venció sin llegar a pagada, la
-- función misma la marca 'vencida' (no depende de que el cron haya
-- corrido) y se niega con un motivo que el frontend puede mostrar.
-- ============================================================

create or replace function emitir_orden(
  p_orden uuid, p_monto_cobrado numeric default null, p_pago_ref text default null
) returns jsonb
  language plpgsql volatile security definer set search_path = public as $function$
declare o ordenes; v_n int; v_it record; i int; v_manillas int;
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

  for v_it in select * from orden_items where orden_id = p_orden loop
    if v_it.tipo_id is not null then
      -- cuánta gente entra con UNA unidad de este tipo
      select coalesce(manillas, 1) into v_manillas from tipo_entrada where id = v_it.tipo_id;
      for i in 1 .. (v_it.cantidad * greatest(v_manillas, 1)) loop
        insert into entradas (organizador_id, evento_id, orden_id, code, canal,
                              tipo_id, fase_id, cliente, precio)
        values (o.organizador_id, o.evento_id, p_orden, nuevo_code(), 'publico',
                v_it.tipo_id, v_it.fase_id, o.comprador_nombre, v_it.precio_unitario);
      end loop;
    else
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

-- Barrido programado aparte, para que el cupo vuelva a estar disponible sin
-- depender de que alguien abra la pestaña vieja: el arreglo de arriba no
-- depende de esto (emitir_orden ya se niega solo), pero sin el cron una
-- orden vencida se queda 'pendiente' hasta que algo la toque.
create extension if not exists pg_cron with schema extensions;
select cron.schedule('vencer_ordenes', '* * * * *', $$select vencer_ordenes()$$);
