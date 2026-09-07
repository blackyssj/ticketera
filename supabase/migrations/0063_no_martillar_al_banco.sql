-- ============================================================
-- 0063 — el reloj deja de martillar al banco cuando está cerrado
--
-- La primera noche del pago automático dejó esto en la base:
--
--   02:30  AUTHORIZED_PENDING_SETTLEMENT   el BCP lo tomó
--   03:56  AUTHORIZED_PENDING_SETTLEMENT   el BCP lo tomó
--   04:15  ERROR  Code 01 "Fuera de horario."
--   04:30  ERROR  Code 01 "Fuera de horario."
--   04:45  ERROR  Code 01 "Fuera de horario."
--   05:00  ERROR  Code 03
--   05:15  AUTHORIZED_PENDING_SETTLEMENT   el BCP lo tomó
--
-- Cuatro rechazos seguidos por los mismos 0,70 Bs. El circuito funciona
-- —tres salieron— pero el banco tiene ventanas en las que no atiende, y
-- cada rechazo devuelve el saldo, así que a los quince minutos el reloj
-- lo vuelve a intentar. Toda la madrugada.
--
-- ── por qué no se arregla con un horario ────────────────────
--
-- La tentación es "no pagar entre las 00:00 y las 01:00". Los datos de
-- arriba dicen que no: 00:15 falló y 01:15 anduvo, con un Code 03 en el
-- medio que no es horario. La ventana real la decide el BCP y cambia sin
-- avisarnos. Un horario escrito acá se desactualiza en silencio y, peor,
-- puede dejar de pagar en un rato en que el banco sí atendía.
--
-- Se espera después de un rechazo y listo. No hace falta saber POR QUÉ
-- cerró: alcanza con no volver a golpear la puerta cada quince minutos.
-- Si fue algo pasajero, a la hora siguiente sale solo; si fue la cuenta
-- mal escrita, tampoco tiene sentido reintentar antes.
--
-- Una hora es el número: más corto vuelve a llenar la tabla de basura, y
-- más largo demora de más una plata que en el 90% de los casos iba a
-- salir bien. Lo que se pierde en el peor caso es una hora de espera, no
-- el pago.
--
-- El pago a mano NO se toca. Si alguien está mirando la pantalla y
-- aprieta "Pagar", que lo intente: sabe lo que está haciendo y va a ver
-- el resultado. Esto es sólo para el que no tiene a nadie mirándolo.
-- ============================================================

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
       and exists (select 1 from cuenta_bancaria c
                    where c.organizador_id = o.id and c.vigente)
       and exists (select 1 from ordenes x
                    where x.evento_id = e.id and x.estado = 'pagada'
                      and coalesce(x.pago_ref,'') not like 'SIM-%')
       -- El freno: si el último intento AUTOMÁTICO de este evento se
       -- rechazó hace menos de una hora, se lo saltea. `pedido_por is
       -- null` acota a los automáticos: un rechazo de un pago a mano no
       -- puede frenar al reloj, son decisiones de distinta gente.
       and not exists (
         select 1 from pago_organizador p
          where p.evento_id = e.id
            and p.pedido_por is null
            and p.estado = 'rechazado'
            and p.actualizado_at > now() - interval '1 hour')
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
  'Los eventos que hoy tienen plata para mandar sola. Saltea el que tuvo un rechazo automatico en la ultima hora: el BCP tiene ventanas en las que no atiende y sin esto el reloj reintenta cada quince minutos toda la madrugada.';
