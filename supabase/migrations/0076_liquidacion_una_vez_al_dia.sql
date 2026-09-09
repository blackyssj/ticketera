-- ============================================================
-- 0076 — un giro por día, no uno cada vez que junta plata
--
-- Hasta hoy el reloj corría cada 15 minutos y giraba apenas el disponible
-- pasaba el mínimo. En un día de venta normal eso son cuatro o cinco
-- transferencias sueltas —el viernes 18 tuvo cuatro en catorce horas— y
-- del lado del cliente es un extracto bancario ilegible: nadie sabe a qué
-- corresponde cada monto ni si ya le pagaron todo lo del día.
--
-- Ahora se gira UNA VEZ POR DÍA, y el monto es todo lo vendido desde el
-- giro anterior. Ese monto no hay que calcularlo: `disponible_de` ya
-- devuelve "lo que corresponde menos lo ya pagado", así que corriendo una
-- vez al día ese número ES la venta del día. No se toca la plata, se
-- toca cuándo sale.
--
-- ── por qué a la mañana y no a medianoche ──
--
-- El BCP rechaza fuera de horario ("Fuera de horario", código 01), y un
-- giro que sale a las 23:00 y rebota deja al cliente esperando hasta la
-- noche siguiente. Los cuatro giros que sí salieron fueron a las 23:00,
-- 08:30, 09:00 y 09:45: la mañana es la franja segura.
--
-- Así que el cierre del día se gira a la mañana siguiente, que es como
-- cierra cualquier procesador de tarjetas. El reloj corre a las 08:00,
-- 10:00 y 12:00 de La Paz (12, 14 y 16 UTC — pg_cron corre en GMT). No
-- son tres giros: son un giro y dos reintentos. El primero que sale
-- apaga a los otros dos, por la guardia de acá abajo.
--
-- ── la guardia ──
--
-- "Ya se giró hoy" se mide sobre el día calendario de La Paz y sólo
-- cuenta lo que NO fue rechazado: un rechazo no gasta el giro del día,
-- justamente para que el reintento de las 10:00 tenga sentido. Y mira
-- `pedido_por is null` porque acota a los automáticos: el botón del panel
-- sigue girando cuando el organizador quiere, sin pedirle permiso al
-- reloj.
--
-- ── el mínimo, después del evento ──
--
-- El mínimo existe para no disparar una transferencia de 3 Bs. Pero
-- pasada la fecha del evento se libera el 30% retenido, y si ese resto
-- queda por debajo del mínimo el reloj no lo gira NUNCA: la plata se
-- queda esperando a que alguien se acuerde de apretar "Pagar". Con el
-- evento pasado ya no hay nada más que acumular, así que el mínimo baja
-- a 1 Bs y el sistema termina lo que empezó.
-- ============================================================

drop function if exists eventos_a_pagar();
create function eventos_a_pagar() returns jsonb
  language plpgsql stable security definer set search_path = public as $function$
declare r record; d jsonb; v_res jsonb := '[]'::jsonb; v_minimo numeric;
begin
  for r in
    select e.id as evento, e.organizador_id as org, o.pago_auto_minimo as minimo
      from eventos e
      join organizadores o on o.id = e.organizador_id
     where o.pago_automatico
       and e.estado in ('publicado','cerrado')
       and exists (select 1 from cuenta_bancaria c
                    where c.organizador_id = o.id and c.vigente)
       and exists (select 1 from ordenes x
                    where x.evento_id = e.id and x.estado = 'pagada'
                      and coalesce(x.pago_ref,'') not like 'SIM-%')
       -- Uno por día. El día es el de La Paz y no el de UTC: a las 21:00
       -- de Santa Cruz en UTC ya es mañana, y el corte caería en mitad de
       -- la noche de venta. Los rechazados no cuentan: si el banco rebotó
       -- el de las 08:00, el de las 10:00 tiene que poder salir.
       and not exists (
         select 1 from pago_organizador p
          where p.evento_id = e.id
            and p.pedido_por is null
            and p.estado <> 'rechazado'
            and (p.pedido_at at time zone 'America/La_Paz')::date
              = (now()        at time zone 'America/La_Paz')::date)
       -- El freno corto, de 0063: si el último intento AUTOMÁTICO se
       -- rechazó hace menos de una hora, se lo saltea. Con los reintentos
       -- separados dos horas ya no debería activarse nunca, y se queda
       -- igual porque protege del día que alguien vuelva a acortar el
       -- reloj sin acordarse de esto.
       and not exists (
         select 1 from pago_organizador p
          where p.evento_id = e.id
            and p.pedido_por is null
            and p.estado = 'rechazado'
            and p.actualizado_at > now() - interval '1 hour')
     order by e.fecha
  loop
    d := disponible_de(r.org, r.evento);
    -- Pasada la fecha no queda nada por acumular: se gira el resto aunque
    -- no llegue al mínimo, o se queda para siempre en la pasarela.
    v_minimo := case when (d->>'evento_pasado')::boolean then 1 else r.minimo end;
    if (d->>'disponible')::numeric >= v_minimo then
      v_res := v_res || jsonb_build_object(
        'evento', r.evento, 'organizador', r.org,
        'disponible', (d->>'disponible')::numeric);
    end if;
  end loop;
  return jsonb_build_object('ok', true, 'eventos', v_res);
end $function$;
revoke execute on function eventos_a_pagar() from anon, public, authenticated;

comment on function eventos_a_pagar() is
  'Los eventos que hoy tienen plata para mandar sola. Un giro por dia calendario de La Paz (un rechazo no gasta el giro del dia). Pasada la fecha del evento el minimo del organizador no aplica: se gira el resto o queda varado. Saltea el que tuvo un rechazo automatico en la ultima hora.';

-- ── el reloj ────────────────────────────────────────────────
-- alter_job y no schedule(): así no hay que repetir la URL ni las claves
-- del cuerpo, que ya viven en 0058. 12, 14 y 16 UTC = 08:00, 10:00 y
-- 12:00 de La Paz.
select cron.alter_job(jobid, schedule := '0 12,14,16 * * *')
  from cron.job where jobname = 'pago_automatico';

-- ── control ─────────────────────────────────────────────────
select * from chequeo_funciones_sin_guardia();
