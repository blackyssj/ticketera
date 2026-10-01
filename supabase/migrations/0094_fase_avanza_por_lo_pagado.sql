-- ============================================================
-- 0094 — una fase deja paso a la siguiente cuando se PAGÓ entera
--
-- 01/10 19:30, apertura de LÜMEN: en el primer minuto 84 órdenes
-- pendientes (174 entradas) apartaron casi todo el cupo de First Offering
-- (120 Bs). disponibilidad_tipo() resta lo retenido, fase_vigente() vio
-- First "agotada" y pasó a Second (160 Bs): se vendieron 39 entradas a 160
-- mientras First tenía 187 lugares que nadie había pagado. A las 19:40
-- esas reservas vencieron y First volvió a abrir a 120. El cliente vende
-- escalonado y por orden: así, el precio sube y baja según cuánta gente
-- tenga un QR abierto, y paga más caro el que llegó en el pico.
--
-- Ahora la fase vigente es la primera, por orden, que todavía tiene algo
-- SIN PAGAR del cupo (lo pagado no llena el tope). Si lo que queda está
-- todo apartado por órdenes pendientes, la fase sigue siendo esa y
-- crear_orden contesta que no hay cupo: el comprador espera unos minutos
-- a que esas reservas se paguen o se venzan, en vez de comprar la tanda
-- siguiente más cara. Cuando lo pagado llena el cupo, pasa a la siguiente.
--
-- Lo demás de 0061 queda igual: ventana de fechas, organizador, y que
-- solo cuente lo que es oferta al público (activo y en_cartelera).
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
          and t.activo and t.en_cartelera
          and (fp.cupo is null or
               (select coalesce(sum(i.cantidad), 0)
                  from orden_items i join ordenes o on o.id = i.orden_id
                 where i.fase_id = f.id and i.tipo_id = fp.tipo_id
                   and o.estado = 'pagada') < fp.cupo))
   order by f.orden
   limit 1
$$;
revoke execute on function fase_vigente(uuid) from anon, public;
grant execute on function fase_vigente(uuid) to authenticated;

comment on function fase_vigente(uuid) is
  'La fase abierta ahora: la primera por orden dentro de su ventana de fechas que todavia tenga cupo SIN PAGAR en algo real para vender (activo y en_cartelera). Las reservas pendientes no la cierran (0094): si todo lo que queda esta apartado, sigue siendo esta y crear_orden dice que no hay cupo hasta que se paguen o venzan.';

-- Vacío o la migración se queda a medias.
select * from chequeo_funciones_sin_guardia();
