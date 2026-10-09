-- ============================================================
-- 0101 — reintentar sin duplicar, y un barrido que llega a todos
--
-- ── ordenes.pago_url ──
-- El front ahora reintenta una compra con la MISMA client_key (antes
-- mandaba una nueva cada vez y cada reintento dejaba una reserva fantasma de
-- 10 minutos: en la apertura de LÜMEN eso mostró "Sold out" de mentira). Con
-- la misma clave crear_orden devuelve la misma orden, y si su cobro ya se
-- había iniciado, iniciar-pago contestaba "repetida" SIN el link de la
-- pasarela: v2pro lo da una sola vez y no se guardaba. Se guarda acá para
-- poder devolverlo. APLICAR ANTES de desplegar iniciar-pago, que lo escribe.
--
-- ── pagos_a_confirmar ──
-- El barrido miraba siempre las 20 órdenes más nuevas. vencer_ordenes no
-- vence las que tienen pago_ref, así que un día de venta junta decenas de
-- QR abandonados, y las más viejas que las 20 primeras no se volvían a mirar
-- nunca: si alguien pagaba una de esas y no volvía a la página, su entrada
-- no salía. Ahora tres cuartos del cupo siguen siendo las más nuevas (donde
-- está casi todo el que paga y no vuelve) y el resto es una muestra al azar
-- de las más viejas, que en unos minutos las recorre todas. Pasa a volatile
-- por el random().
--
-- Y sólo service_role: la llama barrer-pagos con la llave del servidor. 0041
-- la había dejado ejecutable por authenticated, que es también el rol del
-- comprador con cuenta, y devuelve ids de órdenes ajenas.
-- ============================================================

alter table ordenes add column if not exists pago_url text;

comment on column ordenes.pago_url is
  'El link de la pasarela que devolvió iniciar-pago. Se guarda para poder devolverlo cuando el front reintenta la misma orden.';

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
             and o.created_at > now() - interval '3 days') c
   order by case when c.rn <= greatest(coalesce(p_limite, 20), 1) * 3 / 4
                 then c.rn::float8
                 else 1e9 + random() end
   limit greatest(coalesce(p_limite, 20), 1)
$$;
revoke execute on function pagos_a_confirmar(int) from anon, public, authenticated;
grant execute on function pagos_a_confirmar(int) to service_role;

comment on function pagos_a_confirmar(int) is
  'Las órdenes que ya pasaron por la pasarela y siguen sin resolverse: 3/4 las más nuevas, el resto al azar entre las más viejas (3 días). Incluye las vencidas: que se haya vencido el hold no significa que la persona no haya pagado.';

-- ── control ─────────────────────────────────────────────────
select * from chequeo_funciones_sin_guardia();
