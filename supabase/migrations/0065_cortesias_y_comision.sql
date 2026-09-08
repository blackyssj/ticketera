-- ============================================================
-- 0065 — dos cuentas que estaban mal del lado del organizador
--
-- ── 1. la comisión del relacionador no es nuestra para retener ──
--
-- `neto` se calculaba como `bruto - comisiones`, y el disponible para
-- girar salía de ahí. O sea: le reteníamos al organizador lo que él le
-- debe a sus relacionadores.
--
-- Esa plata no pasa por nosotros. TICKETAZO no le paga a los
-- relacionadores: el organizador arregla con los suyos y les paga él.
-- Reteniéndosela, la plataforma se quedaba haciendo de banco de una
-- deuda ajena — con el agravante de que el organizador veía menos plata
-- disponible de la que le corresponde y no tenía forma de entender por
-- qué.
--
-- Las comisiones se siguen CALCULANDO y mostrando: el organizador
-- necesita saber cuánto le debe a cada uno, y `pagar_comision` sigue
-- llevando la cuenta de lo que ya saldó. Lo que deja de pasar es que se
-- las descontemos del giro.
--
-- ── 2. el cupo es de las ventas, no del aforo ───────────────
--
-- `disponibilidad_tipo` restaba las cortesías del cupo. Con eso, veinte
-- invitaciones dejaban veinte entradas menos para vender, y el
-- organizador que reparte cortesías se encontraba con la venta cerrada
-- antes de tiempo sin haber vendido lo que había puesto.
--
-- El cupo de una fase es "cuántas vendo a este precio", no "cuánta gente
-- entra". El aforo lo controla el organizador y no está en este número.
-- Una cortesía es una decisión suya que no consume su propio stock.
--
-- Consecuencia asumida: entre ventas y cortesías puede entrar más gente
-- que el cupo de la fase. Es lo correcto — el cupo nunca fue el aforo, y
-- tratarlo como si lo fuera es lo que rompía la venta.
-- ============================================================

-- ── 1. el cupo cuenta solo lo que se vendió ─────────────────
create or replace function disponibilidad_tipo(p_fase uuid, p_tipo uuid) returns int
  language plpgsql stable security definer set search_path = public as $function$
declare v_cupo int; v_emitidas int; v_retenidas int;
begin
  select cupo into v_cupo from fase_precio where fase_id = p_fase and tipo_id = p_tipo;
  if not found then return 0; end if;
  if v_cupo is null then return null; end if;

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
  return greatest(v_cupo - v_emitidas - v_retenidas, 0);
end $function$;
-- Sin grant a `authenticated`: 0051 se lo saco a proposito. No mira quien
-- pregunta —no puede, la llaman crear_orden y evento_publico desde adentro—
-- asi que expuesta deja a cualquier sesion contando el stock de cualquier
-- organizador. La copia de 0038 tenia el grant y este archivo casi lo
-- restaura sin querer; el chequeo de funciones sin guardia lo agarro.
revoke execute on function disponibilidad_tipo(uuid, uuid) from anon, public, authenticated;

comment on function disponibilidad_tipo(uuid, uuid) is
  'Cuantas unidades quedan para VENDER de un tipo en una fase. Resta lo vendido y lo retenido por ordenes pendientes vivas. Las cortesias no restan: el cupo es el limite de venta, no el aforo.';

-- ── 2. el disponible deja de retener la comision ajena ──────
create or replace function disponible_de(p_org uuid, p_evento uuid) returns jsonb
  language plpgsql stable security definer set search_path = public as $function$
declare
  e eventos; o organizadores;
  v_bruto numeric(12,2); v_fee numeric(12,2); v_com numeric(12,2);
  v_real numeric(12,2); v_sim_n int; v_sim_bs numeric(12,2);
  v_pagado numeric(12,2); v_tope numeric(12,2); v_techo numeric(12,2);
  v_pasado boolean;
begin
  select * into e from eventos where id = p_evento and organizador_id = p_org;
  if not found then raise exception 'EVENTO_INEXISTENTE: ese evento no es tuyo.'; end if;
  select * into o from organizadores where id = p_org;

  select coalesce(sum(subtotal),0), coalesce(sum(fee),0)
    into v_bruto, v_fee
    from ordenes where evento_id = p_evento and estado = 'pagada';

  select coalesce(sum(subtotal) filter (where coalesce(pago_ref,'') not like 'SIM-%'), 0),
         count(*)                filter (where coalesce(pago_ref,'') like 'SIM-%'),
         coalesce(sum(subtotal)  filter (where coalesce(pago_ref,'') like 'SIM-%'), 0)
    into v_real, v_sim_n, v_sim_bs
    from ordenes where evento_id = p_evento and estado = 'pagada';

  -- Se sigue calculando para mostrarlo: el organizador necesita saber
  -- cuanto le debe a sus relacionadores. Ya no se le descuenta del giro.
  select coalesce(sum(comision),0) into v_com
    from ventas_rrpp_base(p_evento, null);

  select coalesce(sum(monto),0) into v_pagado
    from pago_organizador
   where evento_id = p_evento and estado <> 'rechazado';

  v_pasado := e.estado = 'cerrado' or e.fecha < (now() at time zone 'America/La_Paz')::date;
  v_tope  := round(v_bruto * (case when v_pasado then 1 else o.anticipo_pct end), 2);
  v_techo := round(v_real, 2);

  return jsonb_build_object(
    'ok', true, 'evento', p_evento,
    'bruto', v_bruto, 'fee', v_fee, 'comisiones', v_com,
    'neto', v_bruto,
    'cobrado_real', v_real,
    'simuladas', v_sim_n, 'simuladas_bs', v_sim_bs,
    'anticipo_pct', case when v_pasado then 1 else o.anticipo_pct end,
    'evento_pasado', v_pasado,
    'tope', v_tope, 'techo_real', v_techo, 'pagado', v_pagado,
    'disponible', greatest(least(v_tope, v_techo) - v_pagado, 0),
    'automatico', o.pago_automatico,
    'minimo', o.pago_auto_minimo,
    'cuenta', (select jsonb_build_object('id', c.id, 'banco', c.banco_nombre,
                                         'cuenta', c.cuenta,
                                         'titular', btrim(c.titular_nombres || ' ' ||
                                                          c.titular_apellido || ' ' ||
                                                          coalesce(c.titular_apellido2, '')),
                                         'apellido2', c.titular_apellido2,
                                         'extension', c.documento_extension,
                                         'documento_tipo', c.documento_tipo,
                                         'banco_codigo', c.banco_codigo)
                 from cuenta_bancaria c
                where c.organizador_id = p_org and c.vigente));
end $function$;
revoke execute on function disponible_de(uuid, uuid) from anon, public, authenticated;

-- ── 3. el cierre y su informe, con la misma regla ───────────
-- Si el giro no descuenta y el informe si, los dos numeros discrepan y
-- alguien va a creer que falta plata.

create or replace function cerrar_evento(p_evento uuid, p_motivo text) returns jsonb
  language plpgsql volatile security definer set search_path = public as $function$
declare
  v_org    uuid := mi_organizador();
  v_yo     uuid := auth.uid();
  v_motivo text := btrim(coalesce(p_motivo, ''));
  e eventos; v_liq uuid; v_ver int;
  v_bruto numeric(12,2); v_fee numeric(12,2); v_ent int; v_ord int;
  v_com numeric(12,2) := 0; v_pend int; v_rev int;
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
  -- sería un segundo lugar donde vive la misma cuenta, y es cómo el
  -- relacionador y el admin terminan viendo números distintos.
  insert into liquidacion_linea (organizador_id, liquidacion_id, perfil_id, nombre, slug,
                                 entradas, recaudado, comision_unitaria, comision)
  select v_org, v_liq, v.perfil_id, p.nombre, p.slug,
         v.entradas, v.recaudado, v.comision_unitaria, v.comision
    from ventas_rrpp_base(p_evento, null) v
    join perfiles p on p.id = v.perfil_id and p.organizador_id = v_org;

  select coalesce(sum(comision),0) into v_com
    from liquidacion_linea where liquidacion_id = v_liq;
  update liquidacion set comisiones = v_com, neto = v_bruto where id = v_liq;

  update eventos set estado = 'cerrado' where id = p_evento;

  insert into admin_bitacora (organizador_id, evento_id, accion, motivo, actor_id, detalle)
  values (v_org, p_evento, 'evento_cerrado', v_motivo, v_yo,
          jsonb_build_object('liquidacion', v_liq, 'version', v_ver,
                             'bruto', v_bruto, 'fee', v_fee, 'comisiones', v_com));

  return jsonb_build_object('ok', true, 'liquidacion', v_liq, 'version', v_ver,
    'bruto', v_bruto, 'fee', v_fee, 'comisiones', v_com, 'neto', v_bruto,
    'entradas', v_ent, 'ordenes', v_ord,
    'sin_resolver', jsonb_build_object('revision_manual', v_rev, 'pendientes_vivas', v_pend),
    'motivo', format('Evento cerrado. Quedan %s Bs para el organizador y %s Bs en comisiones.',
                     v_bruto, v_com));
end $function$;

create or replace function liquidacion_evento(p_evento uuid) returns jsonb
  language plpgsql stable security definer set search_path = public as $function$
declare
  v_org uuid := mi_organizador();
  q liquidacion; e eventos;
  v_bruto numeric(12,2); v_fee numeric(12,2); v_ent int; v_ord int; v_com numeric(12,2);
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
  select coalesce(sum(comision),0) into v_com from ventas_rrpp_base(p_evento, null);

  select * into q from liquidacion where evento_id = p_evento and vigente;

  return jsonb_build_object(
    'evento', jsonb_build_object('id', e.id, 'nombre', e.nombre, 'fecha', e.fecha,
                                 'estado', e.estado, 'cerrado', e.estado = 'cerrado'),
    'hoy', jsonb_build_object('bruto', v_bruto, 'fee', v_fee, 'cobrado', v_bruto + v_fee,
                              'comisiones', v_com, 'neto', v_bruto,
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
                 'pagada', l.pagada_at is not null, 'pagada_at', l.pagada_at,
                 'pagado_monto', l.pagado_monto, 'pagado_nota', l.pagado_nota,
                 'pagada_por', (select nombre from perfiles where id = l.pagada_por))
               order by l.comision desc, l.nombre)
          from liquidacion_linea l where l.liquidacion_id = q.id), '[]'::jsonb)) end);
end $function$;
