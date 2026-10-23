-- ============================================================
-- 0113 — cerrar un evento que no pasó pide confirmarlo, también en la base
--
-- En Cobros, «Cerrar el evento y liquidar» era el primer botón violeta de
-- la pantalla, arriba de la plata. Cerrar corta la venta online y los
-- links de los relacionadores, congela la liquidación, y desde ese momento
-- disponible_de da el evento por pasado: el giro siguiente manda el 100%
-- en vez del adelanto. Un cliente que lo toca el martes para «ver cómo
-- queda» le corta la venta a su fiesta del jueves.
--
-- El panel nuevo lo pone al final, y antes de la fecha sólo como un botón
-- chico que pide confirmar. Pero la pantalla sola no alcanza: una pestaña
-- vieja en caché, un doble clic, o el panel de antes de esta tanda
-- llaman a cerrar_evento(evento, motivo) igual. Por eso la base exige un
-- tercer parámetro, p_antes_de_fecha, para cerrar un evento cuya fecha no
-- pasó; con el default (false) un evento ya pasado se cierra como
-- siempre, así que el panel viejo sigue andando para lo normal.
--
-- «Pasó» es lo mismo que en disponible_de (0065): la fecha del evento es
-- anterior a hoy en La Paz. El día del evento todavía no pasó.
--
-- Cuerpo de 0108 tal cual, más la guardia y `antes_de_la_fecha` en la
-- bitácora. Cambia la firma, así que drop + create (invariante 4: una
-- firma por función).
-- ============================================================

drop function if exists cerrar_evento(uuid, text);
drop function if exists cerrar_evento(uuid, text, boolean);

create function cerrar_evento(p_evento uuid, p_motivo text, p_antes_de_fecha boolean default false)
  returns jsonb
  language plpgsql security definer set search_path = public as $function$
declare
  v_org    uuid := mi_organizador();
  v_yo     uuid := auth.uid();
  v_motivo text := btrim(coalesce(p_motivo, ''));
  e eventos; v_liq uuid; v_ver int;
  v_bruto numeric(12,2); v_fee numeric(12,2); v_ent int; v_ord int;
  v_com numeric(12,2) := 0; v_pend int; v_rev int;
  v_com_ent numeric(12,2); v_com_mes numeric(12,2); v_antes boolean;
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
  -- 0113: un evento con fecha de hoy o posterior en La Paz (no «pasó»,
  -- con la misma regla que disponible_de) se cierra sólo con la
  -- confirmación explícita. Va después del for update: dos pedidos a la
  -- vez ven el mismo estado.
  v_antes := e.fecha >= (now() at time zone 'America/La_Paz')::date;
  if v_antes and not coalesce(p_antes_de_fecha, false) then
    raise exception 'EVENTO_FUTURO: el evento todavía no pasó. Cerrarlo corta la venta y los links de tus relacionadores; confirmalo si es lo que querés.';
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
                             'comisiones_entradas', v_com_ent, 'comisiones_mesas', v_com_mes,
                             'antes_de_la_fecha', v_antes));
  return jsonb_build_object('ok', true, 'liquidacion', v_liq, 'version', v_ver,
    'bruto', v_bruto, 'fee', v_fee, 'comisiones', v_com, 'neto', v_bruto,
    'comisiones_entradas', v_com_ent, 'comisiones_mesas', v_com_mes,
    'entradas', v_ent, 'ordenes', v_ord,
    'sin_resolver', jsonb_build_object('revision_manual', v_rev, 'pendientes_vivas', v_pend),
    'motivo', format('Evento cerrado. Quedan %s Bs para el organizador y %s Bs en comisiones.',
                     v_bruto, v_com));
end $function$;

revoke execute on function cerrar_evento(uuid, text, boolean) from public, anon;
grant execute on function cerrar_evento(uuid, text, boolean) to authenticated;

-- ── control ─────────────────────────────────────────────────
select * from chequeo_funciones_sin_guardia();
