-- ============================================================
-- 0055 — no se puede retirar plata que nunca entró
--
-- `disponible_organizador` (0052) suma todas las órdenes pagadas, y en
-- RED CIRCLE eso son 4.275 Bs de los cuales 4.270 son órdenes SIMULADAS:
-- las que dejó la pasarela en modo prueba, con `pago_ref` empezando en
-- 'SIM-'. Por esa plata nunca pasó un peso por el banco.
--
-- Hoy el pago igual no sale —el liquidador rechaza por saldo insuficiente
-- en el monedero— así que el sistema no se rompe. Pero la pantalla le
-- dice al organizador que tiene 2.838 Bs disponibles, y eso es una cifra
-- que alguien va a leer en voz alta frente a un cliente. Un número que la
-- plataforma no puede respaldar es peor que no mostrar ninguno.
--
-- ── el tope de la realidad ───────────────────────────────────
--
-- No se cambia lo que la pantalla informa del evento: `bruto`, `neto` y
-- las comisiones siguen contando todo, porque son la foto de lo que se
-- vendió. Lo que se acota es el DISPONIBLE, con un segundo techo: lo que
-- de verdad entró por la pasarela.
--
--     disponible = min(tope de anticipo, plata que entró de verdad) − pagado
--
-- Los dos techos importan y por motivos distintos: el de anticipo cuida
-- del riesgo de que el evento se caiga; este otro cuida de no ofrecer
-- plata que no existe. Se devuelven los dos, y la cuenta de órdenes de
-- prueba, para que la pantalla pueda explicar por qué el número es más
-- chico de lo que el bruto sugiere en vez de parecer un error.
--
-- El día que un evento no tenga órdenes simuladas —o sea, siempre de acá
-- en adelante— los dos techos dan lo mismo y esto no cambia nada.
-- ============================================================

drop function if exists disponible_organizador(uuid);
create function disponible_organizador(p_evento uuid) returns jsonb
  language plpgsql stable security definer set search_path = public as $function$
declare
  v_org uuid := mi_organizador();
  e eventos; o organizadores;
  v_bruto numeric(12,2); v_fee numeric(12,2); v_com numeric(12,2);
  v_real numeric(12,2); v_sim_n int; v_sim_bs numeric(12,2);
  v_pagado numeric(12,2); v_tope numeric(12,2); v_techo numeric(12,2);
  v_pasado boolean;
begin
  if not puede_editar() then raise exception 'Sin permiso'; end if;

  select * into e from eventos where id = p_evento and organizador_id = v_org;
  if not found then raise exception 'EVENTO_INEXISTENTE: ese evento no es tuyo.'; end if;
  select * into o from organizadores where id = v_org;

  -- La foto del evento: todo lo pagado, simulado incluido.
  select coalesce(sum(subtotal),0), coalesce(sum(fee),0)
    into v_bruto, v_fee
    from ordenes where evento_id = p_evento and estado = 'pagada';

  -- Y lo que realmente cobró la pasarela, en la misma pasada. El prefijo
  -- 'SIM-' lo escribe nuestra propia pasarela simulada (app.js): es nuestro,
  -- no de un proveedor, así que ninguna referencia real puede empezar así.
  -- El coalesce cubre la orden sin referencia, que se cuenta como no real.
  select coalesce(sum(subtotal) filter (where coalesce(pago_ref,'') not like 'SIM-%'), 0),
         count(*)                filter (where coalesce(pago_ref,'') like 'SIM-%'),
         coalesce(sum(subtotal)  filter (where coalesce(pago_ref,'') like 'SIM-%'), 0)
    into v_real, v_sim_n, v_sim_bs
    from ordenes where evento_id = p_evento and estado = 'pagada';

  select coalesce(sum(comision),0) into v_com
    from ventas_rrpp_base(p_evento, null);

  select coalesce(sum(monto),0) into v_pagado
    from pago_organizador
   where evento_id = p_evento and estado <> 'rechazado';

  v_pasado := e.estado = 'cerrado' or e.fecha < (now() at time zone 'America/La_Paz')::date;
  v_tope  := round((v_bruto - v_com) * (case when v_pasado then 1 else o.anticipo_pct end), 2);
  -- Las comisiones se descuentan también del techo real: son plata que ya
  -- tiene dueño aunque todavía no se le haya pagado.
  v_techo := round(v_real - v_com, 2);

  return jsonb_build_object(
    'ok', true, 'evento', p_evento,
    'bruto', v_bruto, 'fee', v_fee, 'comisiones', v_com,
    'neto', v_bruto - v_com,
    'cobrado_real', v_real,
    'simuladas', v_sim_n, 'simuladas_bs', v_sim_bs,
    'anticipo_pct', case when v_pasado then 1 else o.anticipo_pct end,
    'evento_pasado', v_pasado,
    'tope', v_tope, 'techo_real', v_techo, 'pagado', v_pagado,
    'disponible', greatest(least(v_tope, v_techo) - v_pagado, 0),
    'cuenta', (select jsonb_build_object('id', c.id, 'banco', c.banco_nombre,
                                         'cuenta', c.cuenta,
                                         'titular', c.titular_nombres || ' ' || c.titular_apellido)
                 from cuenta_bancaria c
                where c.organizador_id = v_org and c.vigente));
end $function$;
revoke execute on function disponible_organizador(uuid) from anon, public;
grant execute on function disponible_organizador(uuid) to authenticated;
