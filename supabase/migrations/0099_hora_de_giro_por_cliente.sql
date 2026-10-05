-- ============================================================
-- 0099 — cada cliente con su hora de giro; Latina a las 09:00
--
-- Hasta hoy el giro automático salía para todos a la misma hora (08:00,
-- 0095). Toda esa plata cae en la misma cuenta —la BCP de Francisco, que
-- después le paga a cada cliente— y el 05/10 se pidió que lo de Latina
-- llegue UNA HORA DESPUÉS que lo de LÜMEN y Distrito: dos transferencias
-- del mismo origen a la misma hora no se distinguen en el extracto.
--
-- `organizadores.pago_hora` es el TURNO del cliente: su giro del día se
-- intenta a esa hora de La Paz y, como red, dos y cuatro horas después.
-- El reloj pasa a correr cada hora de 08:00 a 13:00 y `eventos_a_pagar`
-- sólo ofrece a los clientes cuyo turno es la hora en curso. Así los de
-- las 8 quedan exactamente en 08/10/12, como en 0095, y Latina en
-- 09/11/13: nunca coinciden. Con "desde esa hora" en vez de turnos, un
-- cliente de las 8 que no giró a las 08:00 saldría a las 09:00 junto con
-- Latina, que es justo lo que se quiere evitar. La guardia de un giro
-- automático por día (0076) apaga los turnos que quedan, y un rechazo no
-- gasta el día.
--
-- Sólo 8 o 9: son las únicas horas con sus tres intentos dentro del
-- reloj (el último corre a las 13:00). Antes de las 08:00 el BCP rechaza
-- ("Fuera de horario", ver 0083).
-- ============================================================

alter table organizadores
  add column if not exists pago_hora smallint not null default 8
  check (pago_hora in (8, 9));

comment on column organizadores.pago_hora is
  'Turno del giro automático: se intenta a esta hora de La Paz y 2 y 4 horas después (8 = 08/10/12, 9 = 09/11/13).';

create or replace function eventos_a_pagar() returns jsonb
  language plpgsql stable security definer set search_path = public as $function$
declare r record; d jsonb; v_res jsonb := '[]'::jsonb; v_minimo numeric; v_disp numeric;
begin
  for r in
    select e.id as evento, e.organizador_id as org, o.pago_auto_minimo as minimo
      from eventos e
      join organizadores o on o.id = e.organizador_id
     where o.pago_automatico
       -- El turno del cliente. Se compara la hora de La Paz y no la de
       -- UTC por lo mismo que el día de abajo: pg_cron corre en GMT.
       and extract(hour from now() at time zone 'America/La_Paz')
           in (o.pago_hora, o.pago_hora + 2, o.pago_hora + 4)
       and e.estado in ('publicado','cerrado')
       and exists (select 1 from cuenta_bancaria c
                    where c.organizador_id = o.id and c.vigente)
       and exists (select 1 from ordenes x
                    where x.evento_id = e.id and x.estado = 'pagada'
                      and coalesce(x.pago_ref,'') not like 'SIM-%')
       -- Uno por día. El día es el de La Paz y no el de UTC: a las 21:00
       -- de Santa Cruz en UTC ya es mañana, y el corte caería en mitad de
       -- la noche de venta. Los rechazados no cuentan: si el banco rebotó
       -- el primero, el reintento tiene que poder salir.
       and not exists (
         select 1 from pago_organizador p
          where p.evento_id = e.id
            and p.pedido_por is null
            and p.estado <> 'rechazado'
            and (p.pedido_at at time zone 'America/La_Paz')::date
              = (now()        at time zone 'America/La_Paz')::date)
       -- El freno corto, de 0063: si el último intento AUTOMÁTICO se
       -- rechazó hace menos de una hora, se lo saltea. Con los turnos
       -- separados dos horas no debería activarse nunca, y se queda igual
       -- porque protege del día que alguien vuelva a acortar el reloj.
       and not exists (
         select 1 from pago_organizador p
          where p.evento_id = e.id
            and p.pedido_por is null
            and p.estado = 'rechazado'
            and p.actualizado_at > now() - interval '1 hour')
     order by e.fecha
  loop
    d := disponible_de(r.org, r.evento);
    v_disp := (d->>'disponible')::numeric;
    -- Pasada la fecha no queda nada por acumular: se gira el resto aunque
    -- no llegue al mínimo, o se queda para siempre en la pasarela.
    v_minimo := case when (d->>'evento_pasado')::boolean then 1 else r.minimo end;
    -- El piso real, y no el que cargue el organizador: cero no se gira,
    -- valga lo que valga `pago_auto_minimo`.
    if v_disp > 0 and v_disp >= v_minimo then
      v_res := v_res || jsonb_build_object(
        'evento', r.evento, 'organizador', r.org, 'disponible', v_disp);
    end if;
  end loop;
  return jsonb_build_object('ok', true, 'eventos', v_res);
end $function$;
revoke execute on function eventos_a_pagar() from anon, public, authenticated;

comment on function eventos_a_pagar() is
  'Los eventos que hoy tienen plata para mandar sola. Sólo clientes cuyo turno (pago_hora, +2, +4, hora La Paz) es la hora en curso. Un giro por dia calendario de La Paz (un rechazo no gasta el giro del dia). Pasada la fecha del evento el minimo del organizador no aplica. Saltea el que tuvo un rechazo automatico en la ultima hora.';

-- ── el reloj ────────────────────────────────────────────────
-- Cada hora de 12 a 17 UTC = 08:00 a 13:00 de La Paz.
select cron.alter_job(jobid, schedule := '0 12-17 * * *')
  from cron.job where jobname = 'pago_automatico';

-- ── Latina ──────────────────────────────────────────────────
-- Su plata va a la misma cuenta que la de LÜMEN y Distrito (la BCP de
-- Francisco Aguilera): se copia la fila de LÜMEN para no escribir el
-- número de cuenta en el repo. Antes de copiar se verifica que esa fila
-- SEA la de Francisco, y que Latina no tenga ya otra cuenta cargada desde
-- su panel: en cualquiera de los dos casos la migración se cae entera en
-- vez de dejar el giro apuntando a una cuenta que nadie eligió.
do $guarda$
declare v_lumen cuenta_bancaria%rowtype; v_latina cuenta_bancaria%rowtype;
begin
  select c.* into v_lumen from cuenta_bancaria c join organizadores o on o.id = c.organizador_id
   where o.slug = 'lumen' and c.vigente;
  if not found then raise exception '0099: LÜMEN no tiene cuenta vigente para copiar'; end if;
  -- La de Francisco es la que mandó Distrito Ferial el 06/09: se compara
  -- contra esa para no escribir ni un dígito de la cuenta acá.
  if v_lumen.titular_nombres <> 'Francisco' or v_lumen.titular_apellido <> 'Aguilera'
     or not exists (select 1 from cuenta_bancaria d join organizadores od on od.id = d.organizador_id
                     where od.slug = 'distrito-ferial' and d.vigente
                       and d.cuenta = v_lumen.cuenta and d.banco_codigo = v_lumen.banco_codigo) then
    raise exception '0099: la cuenta vigente de LÜMEN ya no es la de Francisco Aguilera';
  end if;
  select c.* into v_latina from cuenta_bancaria c join organizadores o on o.id = c.organizador_id
   where o.slug = 'latina' and c.vigente;
  if found and (v_latina.cuenta, v_latina.banco_codigo, v_latina.documento_numero)
            is distinct from (v_lumen.cuenta, v_lumen.banco_codigo, v_lumen.documento_numero) then
    raise exception '0099: Latina ya tiene otra cuenta vigente; decidir a mano cuál vale';
  end if;
end $guarda$;

insert into cuenta_bancaria (organizador_id, banco_codigo, banco_nombre, cuenta,
       titular_nombres, titular_apellido, titular_apellido2,
       documento_tipo, documento_numero, documento_extension, ciudad_codigo,
       vigente, nota)
select (select id from organizadores where slug = 'latina'),
       c.banco_codigo, c.banco_nombre, c.cuenta,
       c.titular_nombres, c.titular_apellido, c.titular_apellido2,
       c.documento_tipo, c.documento_numero, c.documento_extension, c.ciudad_codigo,
       true,
       'Cuenta de Francisco Aguilera, igual que LÜMEN y distrito-ferial: los pagos de TICKETAZO van a Francisco (pedido del 05/10/2026).'
  from cuenta_bancaria c
  join organizadores o on o.id = c.organizador_id
 where o.slug = 'lumen' and c.vigente
   and not exists (select 1 from cuenta_bancaria x
                    join organizadores ol on ol.id = x.organizador_id
                   where ol.slug = 'latina' and x.vigente);

-- Turno de las 9 y sin mínimo, como los otros dos (0078). El automático
-- NO se prende acá: esto se aplica el 05/10 a media mañana y, prendido ya,
-- el turno de las 11:00 giraría hoy todo lo acumulado sin que nadie lo
-- mire. El primer giro de cada cliente se mira (0057), así que se prende
-- mañana 06/10 a las 08:50 con un trabajo de una sola vez, igual que se
-- hizo con LÜMEN en 0096, y el primero sale a las 09:00.
update organizadores
   set pago_hora = 9, pago_auto_minimo = 0.01
 where slug = 'latina';

select cron.schedule('activar_auto_latina', '50 12 6 10 *', $job$
  update organizadores set pago_automatico = true where slug = 'latina';
  select cron.unschedule('activar_auto_latina');
$job$);

-- ── control ─────────────────────────────────────────────────
select * from chequeo_funciones_sin_guardia();
