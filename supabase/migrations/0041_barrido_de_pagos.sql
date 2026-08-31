-- ============================================================
-- 0041 — el barrido que no depende de que el comprador vuelva
--
-- Lo que pasó y por qué existe esto: alguien pagó Bs 1 en la pasarela, la
-- pasarela cobró, mostró "La operación se ha realizado con éxito" y NO lo
-- devolvió a la ticketera. La orden quedó 'pendiente' y la entrada sin
-- emitir. La plata adentro y el comprador sin nada, que es el peor estado
-- posible de este sistema.
--
-- El error puntual —la consulta usaba el nombre de campo equivocado— se
-- arregló en la Edge Function. Pero el arreglo de fondo es otro: **la
-- emisión no puede depender de que el navegador del comprador vuelva.**
-- Entre él y nosotros hay un redirect de un tercero, y ese redirect puede
-- no ocurrir por diez motivos que no controlamos: cierra la pestaña, se
-- queda sin datos, la pasarela no redirige, el banco abre su propia app.
--
-- Así que cada minuto se le pregunta a la pasarela por las órdenes que
-- están esperando. Si cobró, se emite. El comprador puede no volver nunca:
-- su entrada existe igual y su link la muestra.
--
-- Por qué pg_net y no un `if` adentro de vencer_ordenes: pg_cron corre SQL
-- y la consulta a la pasarela es HTTP. pg_net es la forma que tiene
-- Postgres de hacer esa llamada sin bloquear el job.
-- ============================================================

create extension if not exists pg_net with schema extensions;

-- ── a quién hay que preguntarle ──────────────────────────────
-- Solo órdenes que ya pasaron por la pasarela (tienen pago_ref) y todavía
-- no se resolvieron. Se incluyen las 'vencida' a propósito: que se nos
-- haya vencido el hold no significa que la persona no haya pagado, y si
-- pagó hay que emitirle igual — lo contrario es quedarse con la plata.
--
-- El corte de 3 días es para no preguntar por siempre: pasado ese tiempo,
-- una orden pendiente con pago_ref es un caso para mirar a mano, no para
-- reintentar cada minuto hasta el fin de los tiempos.
create or replace function pagos_a_confirmar(p_limite int default 20)
returns table (id uuid, pago_ref text)
  language sql stable security definer set search_path = public as $$
  select o.id, o.pago_ref
    from ordenes o
   where o.pago_ref is not null
     and o.pago_ref not like 'SIM-%'          -- las simuladas no se consultan
     and o.estado in ('pendiente', 'vencida')
     and o.created_at > now() - interval '3 days'
   order by o.created_at desc
   limit greatest(coalesce(p_limite, 20), 1)
$$;
revoke execute on function pagos_a_confirmar(int) from anon, public;
grant execute on function pagos_a_confirmar(int) to authenticated;

comment on function pagos_a_confirmar(int) is
  'Las órdenes que ya pasaron por la pasarela y siguen sin resolverse. Incluye las vencidas: que se haya vencido el hold no significa que la persona no haya pagado.';
