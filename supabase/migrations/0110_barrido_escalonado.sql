-- ============================================================
-- 0106 — el barrido escalonado: consultar la pasarela menos seguido
--         cuanto más vieja es la orden
--
-- barrer-pagos corre cada minuto y le pedía a v2pro el estado de hasta 20
-- órdenes pendientes o vencidas de los últimos 3 días, todas cada minuto.
-- Cada consulta (consulta_transaccion_v2.php) busca por id_transaccion en
-- solicitudpagos, una tabla MyISAM de 183 mil filas sin índice en esa
-- columna: recorre la tabla entera con bloqueo de tabla (1–2 s). El
-- diagnóstico del 17/10/2026 midió ~19 recorridos por minuto, la mayoría
-- nuestros, y 5 congelamientos de cobros entre el 15 y el 18/10: con la
-- tabla trabada no se generan QR para nadie (tampoco para los otros
-- comercios) y la base termina reiniciándose.
--
-- Ahora cada orden se consulta según su edad:
--   · menos de 2 horas: cada minuto (donde está casi todo el que paga y no
--     vuelve de la pasarela);
--   · de 2 horas a 1 día: cada 5 minutos (el QR del BCP vive ~10 horas);
--   · de 1 a 3 días: cada 30 minutos.
-- Dentro de lo elegible se mantiene el criterio de 0101: tres cuartos del
-- cupo para las más nuevas y el resto al azar entre las demás.
-- ============================================================

create or replace function pagos_a_confirmar(p_limite int default 20)
returns table (id uuid, pago_ref text)
  language sql volatile security definer set search_path = public as $$
  select c.id, c.pago_ref
    from (select o.id, o.pago_ref,
                 row_number() over (order by o.created_at desc) as rn
            from ordenes o
           where o.pago_ref is not null
             and o.pago_ref not like 'SIM-%'          -- las simuladas no se consultan
             and o.estado in ('pendiente', 'vencida')
             and o.created_at > now() - interval '3 days'
             and (   o.created_at > now() - interval '2 hours'
                  or (o.created_at > now() - interval '1 day'
                      and extract(minute from now())::int % 5 = 0)
                  or extract(minute from now())::int % 30 = 0)) c
   order by case when c.rn <= greatest(coalesce(p_limite, 20), 1) * 3 / 4
                 then c.rn::float8
                 else 1e9 + random() end
   limit greatest(coalesce(p_limite, 20), 1)
$$;
revoke execute on function pagos_a_confirmar(int) from anon, public, authenticated;
grant execute on function pagos_a_confirmar(int) to service_role;

comment on function pagos_a_confirmar(int) is
  'Las órdenes que ya pasaron por la pasarela y siguen sin resolverse, escalonadas por edad: menos de 2 h cada minuto, hasta 1 día cada 5 min, hasta 3 días cada 30 min. 3/4 las más nuevas, el resto al azar. Incluye las vencidas: que se haya vencido el hold no significa que la persona no haya pagado.';

-- ── control ─────────────────────────────────────────────────
select * from chequeo_funciones_sin_guardia();
