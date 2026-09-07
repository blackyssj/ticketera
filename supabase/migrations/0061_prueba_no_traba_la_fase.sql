-- ============================================================
-- 0061 — la entrada de prueba no puede trabar una fase
--
-- 0060 hizo que una fase agotada dé paso a la siguiente: sigue viva
-- mientras QUEDE algo que vender en ella. Cierto, salvo por un detalle
-- que aparece apenas se arma el primer evento nuevo.
--
-- Todo evento lleva una «Prueba de cobro» de Bs 1: el producto con el
-- que se verifica que la pasarela cobra de verdad, por el mismo camino
-- que recorre un comprador. Ese producto tiene cupo propio, y con la
-- regla de 0060 alcanza para mantener abierta la fase:
--
--     Hot ticket · General agotado (30/30) · Prueba de cobro 3 libres
--
-- La fase sigue "con algo que vender", así que la entrada 31 se sigue
-- vendiendo a 70 en vez de pasar a 90. Una prueba que alguien se olvidó
-- de apagar le cuesta 20 Bs a cada entrada de la noche.
--
-- ── por qué `en_cartelera` es el corte correcto ─────────────
--
-- Esa columna ya existe y ya significa exactamente esto: si el producto
-- cuenta "para el `desde` y el estado de venta (agotado / últimas)"
-- (0045). El estado de una fase ES estado de venta. Usar otra señal acá
-- sería inventar una segunda definición de "esto es una oferta al
-- público" al lado de la que ya está escrita.
--
-- Efecto secundario aceptado: si en una fase se agota todo lo real y
-- sólo queda cupo de prueba, la fase avanza y la prueba deja de tener
-- precio ahí — o sea, deja de poder comprarse en esa fase. Está bien: la
-- prueba se hace antes de vender, no en el medio de la noche, y lo otro
-- es cobrarle de menos a todo el mundo.
--
-- Firma sin cambios: `create or replace` alcanza.
-- ============================================================

create or replace function fase_vigente(p_evento uuid) returns uuid
  language sql stable security definer set search_path = public as $$
  select f.id from evento_fase f
   where f.evento_id = p_evento and f.activo
     and (f.desde is null or f.desde <= now())
     and (f.hasta is null or f.hasta >  now())
     and (mi_organizador() is null or f.organizador_id = mi_organizador())
     and exists (
       select 1
         from fase_precio fp
         join tipo_entrada t on t.id = fp.tipo_id
        where fp.fase_id = f.id
          -- Sólo lo que es una oferta al público sostiene una fase: una
          -- prueba de cobro con cupo libre no puede dejar un precio viejo
          -- abierto para todos.
          and t.activo and t.en_cartelera
          and (fp.cupo is null or coalesce(disponibilidad_tipo(f.id, fp.tipo_id), 1) > 0))
   order by f.orden
   limit 1
$$;
revoke execute on function fase_vigente(uuid) from anon, public;
grant execute on function fase_vigente(uuid) to authenticated;

comment on function fase_vigente(uuid) is
  'La fase abierta ahora: la primera por orden dentro de su ventana de fechas que todavia tenga algo REAL para vender (activo y en_cartelera). Una fase con el cupo agotado da paso a la siguiente; la prueba de cobro de Bs 1 no la sostiene.';
