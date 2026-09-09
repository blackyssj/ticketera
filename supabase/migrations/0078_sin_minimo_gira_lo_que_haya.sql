-- ============================================================
-- 0078 — el cierre de medianoche gira lo que haya
--
-- El mínimo (`pago_auto_minimo`) nació con el reloj que corría cada 15
-- minutos: sin él, una venta suelta disparaba una transferencia, y un día
-- normal terminaba en veinte giros de 49 Bs. Con el giro una vez por día
-- (0076) esa razón desapareció: como mucho sale una transferencia por
-- evento por noche, valga 8 Bs o valga 4.000.
--
-- Y mientras tanto el mínimo se había vuelto el problema: se aplica POR
-- EVENTO y no sumado, así que con 500 Bs de piso el viernes (343
-- disponibles) y el miércoles (280) quedaban los dos abajo y no cobraba
-- ninguno, aunque juntos fueran 623. El cliente eligió que se gire lo que
-- haya.
--
-- ── por qué 0.01 y no 0 ──
--
-- Porque 0057 puso `check (pago_auto_minimo >= 0.01)` y está bien que
-- siga: un "mínimo" de cero no es un mínimo, es la ausencia de uno, y
-- dicho así invita a que alguien lea la columna y crea que el campo está
-- sin configurar. Un centavo es el mismo comportamiento —cualquier venta
-- real lo supera— y se lee como lo que es: una decisión.
--
-- ── el piso que sí queda ──
--
-- Con el mínimo en un centavo, la comparación `disponible >= minimo`
-- todavía separa bien, pero el margen es tan fino que conviene no
-- depender de él: un evento publicado que hoy no vendió nada da
-- disponible 0.00, y basta que alguien relaje el check para que el reloj
-- mande al banco una orden de cero pesos. Así que la condición de "hay
-- algo para mandar" deja de depender del número que cargue el
-- organizador y pasa a estar en la función: se gira si el disponible es
-- MAYOR A CERO y además llega al mínimo.
-- ============================================================

drop function if exists eventos_a_pagar();
create function eventos_a_pagar() returns jsonb
  language plpgsql stable security definer set search_path = public as $function$
declare r record; d jsonb; v_res jsonb := '[]'::jsonb; v_minimo numeric; v_disp numeric;
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
       -- el de las 00:00, el de las 08:00 tiene que poder salir.
       and not exists (
         select 1 from pago_organizador p
          where p.evento_id = e.id
            and p.pedido_por is null
            and p.estado <> 'rechazado'
            and (p.pedido_at at time zone 'America/La_Paz')::date
              = (now()        at time zone 'America/La_Paz')::date)
       -- El freno corto, de 0063: si el último intento AUTOMÁTICO se
       -- rechazó hace menos de una hora, se lo saltea. Con los reintentos
       -- separados ocho horas ya no debería activarse nunca, y se queda
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
  'Los eventos que hoy tienen plata para mandar sola. Nunca gira cero, valga lo que valga el minimo del organizador. Un giro por dia calendario de La Paz (un rechazo no gasta el giro del dia). Pasada la fecha del evento el minimo no aplica: se gira el resto o queda varado. Saltea el que tuvo un rechazo automatico en la ultima hora.';

-- ── el cliente que lo pidió ─────────────────────────────────
update organizadores set pago_auto_minimo = 0.01 where slug = 'distrito-ferial';

-- ── control ─────────────────────────────────────────────────
select * from chequeo_funciones_sin_guardia();
