-- ============================================================
-- 0057 — que la plata salga sola
--
-- Hoy el pago al organizador existe pero lo dispara una persona: entra
-- al panel, mira el disponible y aprieta "Pagar". Para un boliche por
-- semana alcanza. Para una feria que vende todo el día, no: el
-- organizador quiere ver la plata caer sin llamar a nadie, y esa es
-- justamente la diferencia que se vende contra la competencia.
--
-- Esto agrega el modo automático. NO cambia nada de lo que ya hay: el
-- botón sigue estando, las mismas reglas de tope y de saldo se aplican
-- igual, y la única diferencia es quién aprieta.
--
-- ── por qué arranca apagado ──────────────────────────────────
--
-- `pago_automatico` es false por defecto y se prende organizador por
-- organizador. Un interruptor global encendido de fábrica significa que
-- el día que se sume un cliente nuevo, su plata empieza a salir sola
-- antes de que nadie haya mirado si su cuenta bancaria está bien
-- escrita. El primer pago de cada cliente se mira; los siguientes van
-- solos.
--
-- ── por qué hay un mínimo ────────────────────────────────────
--
-- Sin piso, un evento que vende de a una entrada dispara una
-- transferencia bancaria cada quince minutos por 130 Bs. Cada una es una
-- operación real contra el banco y ninguna le sirve a nadie. Con el piso
-- la plata se junta hasta que vale la pena moverla, y el organizador
-- elige el número: 100 Bs por defecto, que para una feria es media hora
-- de venta floja.
--
-- ── por qué NO se parte un pago grande ───────────────────────
--
-- Los pagos de 4.000 Bs o más quedan esperando aprobación manual del
-- lado del liquidador. La tentación es mandar 3.999 dos veces para
-- esquivarlo. Eso es exactamente lo que un control de ese tipo existe
-- para detectar, y hacerlo automático desde un sistema que mueve plata
-- de terceros es la clase de cosa que después hay que explicarle a un
-- banco. El pago grande sale entero y espera. La pantalla lo muestra
-- como lo que es.
--
-- ── por qué `pedido_por` pasa a aceptar null ─────────────────
--
-- Esa columna contesta "¿quién pidió este pago?". En un pago automático
-- la respuesta honesta es "nadie", y meter un usuario de sistema
-- inventado ahí haría que la pantalla muestre a una persona que no
-- decidió nada. Null es la respuesta correcta y además es el filtro que
-- separa los automáticos de los que apretó alguien.
--
-- La bitácora NO recibe fila por estos pagos, y es a propósito:
-- `admin_bitacora` es el registro de lo que hizo una persona a mano
-- —tiene `actor_id not null` justamente por eso— y aflojarlo para que
-- entre el sistema convierte un registro de decisiones humanas en un
-- log de eventos. El registro de la plata es `pago_organizador`, que
-- tiene el monto, la cuenta, el estado y la hora de cada intento.
--
-- Idempotente: `add column if not exists` y `drop function if exists`
-- con la firma completa delante de cada create (invariante 4).
-- ============================================================

-- ── el interruptor, por organizador ─────────────────────────
alter table organizadores
  add column if not exists pago_automatico boolean not null default false;
alter table organizadores
  add column if not exists pago_auto_minimo numeric(12,2) not null default 100;

do $$ begin
  alter table organizadores add constraint organizadores_pago_auto_minimo_check
    check (pago_auto_minimo >= 0.01);
exception when duplicate_object then null; end $$;

comment on column organizadores.pago_automatico is
  'Si esta en true, el sistema le manda la plata disponible sin que nadie apriete nada. Arranca apagado a proposito: el primer pago de cada cliente se mira.';
comment on column organizadores.pago_auto_minimo is
  'Piso para el pago automatico. Debajo de esto la plata se junta en vez de disparar una transferencia bancaria que no le sirve a nadie.';

-- Un pago automatico no lo pidio nadie, y null es la respuesta honesta.
alter table pago_organizador alter column pedido_por drop not null;
comment on column pago_organizador.pedido_por is
  'Quien apreto "Pagar". Null = lo mando el sistema solo (0057).';

-- ── el disponible, sin depender de quien pregunta ───────────
-- Mismo calculo de 0055, movido a una funcion que recibe el organizador
-- en vez de sacarlo de la sesion. El cron no tiene sesion: sin esto,
-- habria que escribir la cuenta una segunda vez para el, y dos copias de
-- "cuanta plata se puede sacar" es como una de las dos queda vieja.
-- No se expone a nadie: es el cuerpo, no la puerta.
drop function if exists disponible_de(uuid, uuid);
create function disponible_de(p_org uuid, p_evento uuid) returns jsonb
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

  -- La foto del evento: todo lo pagado, simulado incluido.
  select coalesce(sum(subtotal),0), coalesce(sum(fee),0)
    into v_bruto, v_fee
    from ordenes where evento_id = p_evento and estado = 'pagada';

  -- Y lo que realmente cobro la pasarela. El prefijo 'SIM-' lo escribe
  -- nuestra propia pasarela simulada: ninguna referencia real empieza asi.
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
    'automatico', o.pago_automatico,
    'minimo', o.pago_auto_minimo,
    'cuenta', (select jsonb_build_object('id', c.id, 'banco', c.banco_nombre,
                                         'cuenta', c.cuenta,
                                         'titular', c.titular_nombres || ' ' || c.titular_apellido)
                 from cuenta_bancaria c
                where c.organizador_id = p_org and c.vigente));
end $function$;
revoke execute on function disponible_de(uuid, uuid) from anon, public, authenticated;

comment on function disponible_de(uuid, uuid) is
  'Cuanta plata se le puede mandar hoy al organizador de un evento. Cuerpo compartido: lo llaman disponible_organizador (con la sesion) y el pago automatico (sin ninguna). No se expone.';

-- La cara publica no cambia de forma: mismas claves, misma guarda.
drop function if exists disponible_organizador(uuid);
create function disponible_organizador(p_evento uuid) returns jsonb
  language plpgsql stable security definer set search_path = public as $function$
begin
  if not puede_editar() then raise exception 'Sin permiso'; end if;
  return disponible_de(mi_organizador(), p_evento);
end $function$;
revoke execute on function disponible_organizador(uuid) from anon, public;
grant execute on function disponible_organizador(uuid) to authenticated;

-- ── que se puede pagar ahora mismo ──────────────────────────
-- La lista que mira el cron. Se acota antes de calcular: `disponible_de`
-- recorre las ventas del evento entero, y correrlo sobre eventos que no
-- vendieron nada es trabajo tirado cada quince minutos para siempre.
drop function if exists eventos_a_pagar();
create function eventos_a_pagar() returns jsonb
  language plpgsql stable security definer set search_path = public as $function$
declare r record; d jsonb; v_res jsonb := '[]'::jsonb;
begin
  for r in
    select e.id as evento, e.organizador_id as org, o.pago_auto_minimo as minimo
      from eventos e
      join organizadores o on o.id = e.organizador_id
     where o.pago_automatico
       and e.estado in ('publicado','cerrado')
       -- Sin cuenta cargada no hay a donde mandar nada.
       and exists (select 1 from cuenta_bancaria c
                    where c.organizador_id = o.id and c.vigente)
       -- Y sin plata cobrada de verdad tampoco. El filtro barato primero.
       and exists (select 1 from ordenes x
                    where x.evento_id = e.id and x.estado = 'pagada'
                      and coalesce(x.pago_ref,'') not like 'SIM-%')
     order by e.fecha
  loop
    d := disponible_de(r.org, r.evento);
    if (d->>'disponible')::numeric >= r.minimo then
      v_res := v_res || jsonb_build_object(
        'evento', r.evento, 'organizador', r.org,
        'monto', (d->>'disponible')::numeric);
    end if;
  end loop;
  return jsonb_build_object('ok', true, 'eventos', v_res);
end $function$;
revoke execute on function eventos_a_pagar() from anon, public, authenticated;

comment on function eventos_a_pagar() is
  'Los eventos cuyo organizador tiene el pago automatico puesto y hoy pasa el minimo. La lista que recorre el cron. No se expone.';

-- ── pedir el pago sin que haya una persona ──────────────────
-- Gemela de pedir_pago_organizador, con dos diferencias y ninguna es de
-- criterio: el organizador sale del evento en vez de la sesion, y la fila
-- nace con pedido_por en null. El candado, el tope y el chequeo de saldo
-- son los mismos, porque son los que evitan pagar dos veces lo mismo.
drop function if exists pedir_pago_auto(uuid);
create function pedir_pago_auto(p_evento uuid) returns jsonb
  language plpgsql volatile security definer set search_path = public as $function$
declare
  v_org uuid; v_min numeric(12,2); v_auto boolean;
  d jsonb; c cuenta_bancaria; v_monto numeric(12,2); p pago_organizador;
begin
  select e.organizador_id, o.pago_auto_minimo, o.pago_automatico
    into v_org, v_min, v_auto
    from eventos e join organizadores o on o.id = e.organizador_id
   where e.id = p_evento;
  if v_org is null then
    return jsonb_build_object('ok', false, 'motivo', 'Ese evento no existe.');
  end if;
  -- Se vuelve a mirar acá y no sólo en la lista: entre que el cron armó
  -- la lista y llegó a este evento, alguien pudo apagar el interruptor.
  if not v_auto then
    return jsonb_build_object('ok', false, 'motivo', 'Ese organizador no tiene el pago automático puesto.');
  end if;

  perform pg_advisory_xact_lock(hashtext('pago_organizador:' || p_evento::text));

  select * into c from cuenta_bancaria where organizador_id = v_org and vigente;
  if not found then
    return jsonb_build_object('ok', false, 'falta', 'cuenta',
      'motivo', 'El organizador no tiene cuenta bancaria cargada.');
  end if;

  d := disponible_de(v_org, p_evento);
  v_monto := round((d->>'disponible')::numeric, 2);

  -- El mínimo se comprueba DENTRO del candado. Afuera, dos corridas del
  -- cron pisándose podrían ver las dos el mismo disponible y mandar dos
  -- pagos que juntos se pasan del tope.
  if v_monto < v_min then
    return jsonb_build_object('ok', false, 'falta', 'minimo',
      'disponible', v_monto, 'minimo', v_min,
      'motivo', format('Hay %s Bs y el mínimo es %s.', v_monto, v_min));
  end if;

  insert into pago_organizador (organizador_id, evento_id, cuenta_id, monto,
                                banco_nombre, cuenta, titular, pedido_por)
  values (v_org, p_evento, c.id, v_monto, c.banco_nombre, c.cuenta,
          c.titular_nombres || ' ' || c.titular_apellido, null)
  returning * into p;

  return jsonb_build_object('ok', true, 'pago', p.id, 'monto', p.monto,
    'automatico', true,
    'beneficiario', jsonb_build_object(
      'banco_codigo', c.banco_codigo, 'cuenta', c.cuenta,
      'nombres', c.titular_nombres, 'apellido', c.titular_apellido,
      'documento_tipo', c.documento_tipo, 'documento_numero', c.documento_numero,
      'documento_extension', c.documento_extension, 'ciudad_codigo', c.ciudad_codigo),
    'motivo', format('Pago automático de %s Bs a %s.', p.monto, p.titular));
end $function$;
revoke execute on function pedir_pago_auto(uuid) from anon, public, authenticated;

comment on function pedir_pago_auto(uuid) is
  'Crea el pago al organizador sin que haya una persona apretando. Mismo candado y mismo tope que pedir_pago_organizador; la fila nace con pedido_por en null. Solo service_role.';

-- ── el interruptor desde el panel ───────────────────────────
-- Sólo admin. `puede_editar()` incluye a staff, y staff es quien carga
-- eventos y vende: prender un giro automático de plata a una cuenta
-- bancaria no es de ese trabajo. El que puede cambiar la cuenta destino
-- —guardar_cuenta_bancaria, que sí acepta staff— por lo menos deja fila
-- en la bitácora; esto decide cuánto y cada cuánto sale sola.
drop function if exists guardar_pago_automatico(boolean, numeric);
create function guardar_pago_automatico(p_activo boolean, p_minimo numeric default null)
  returns jsonb
  language plpgsql volatile security definer set search_path = public as $function$
declare v_org uuid := mi_organizador(); o organizadores; v_min numeric(12,2);
begin
  if mi_rol() <> 'admin' then raise exception 'Sin permiso'; end if;

  v_min := round(coalesce(p_minimo, (select pago_auto_minimo from organizadores where id = v_org)), 2);
  if v_min < 0.01 then
    return jsonb_build_object('ok', false, 'motivo', 'El mínimo no puede ser cero.');
  end if;

  update organizadores
     set pago_automatico = coalesce(p_activo, false), pago_auto_minimo = v_min
   where id = v_org
  returning * into o;

  return jsonb_build_object('ok', true,
    'automatico', o.pago_automatico, 'minimo', o.pago_auto_minimo,
    'motivo', case when o.pago_automatico
      then format('Pago automático puesto. Se manda solo a partir de %s Bs.', o.pago_auto_minimo)
      else 'Pago automático apagado. La plata sale sólo cuando alguien apriete «Pagar».' end);
end $function$;
revoke execute on function guardar_pago_automatico(boolean, numeric) from anon, public;
grant execute on function guardar_pago_automatico(boolean, numeric) to authenticated;

comment on function guardar_pago_automatico(boolean, numeric) is
  'Prende o apaga el giro automatico al organizador y fija su piso. Solo admin: puede_editar() incluye a staff y esto no es trabajo de staff.';
