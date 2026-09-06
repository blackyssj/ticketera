-- ============================================================
-- 0060 — la fase que se agota da paso a la siguiente
--
-- `fase_vigente` elegía por fecha: la primera fase activa cuya ventana
-- incluye el ahora. Eso sirve para "preventa hasta el jueves, después
-- precio de puerta", que es como vendía el primer cliente.
--
-- No sirve para como vende el segundo:
--
--     Hot ticket   70 Bs · 30 entradas
--     Fase 1       90 Bs · 50 entradas
--     Fase Final  100 Bs · sin límite
--
-- Acá la fase no la mueve el reloj, la mueve el cupo. Con la función
-- vieja, la entrada 31 se encuentra con "agotado" —el cupo de Hot ticket
-- está en cero y la fase sigue siendo la vigente— y la venta se detiene
-- hasta que alguien entre al panel a mover fechas a mano. Un viernes a
-- las once de la noche eso son cincuenta entradas que no se vendieron.
--
-- ── qué cuenta como agotada ─────────────────────────────────
--
-- Una fase sigue viva mientras QUEDE algo que vender en ella: algún tipo
-- de entrada activo con cupo libre, o con cupo nulo (sin límite). Cuando
-- ninguno tiene, se saltea y contesta la siguiente por `orden`.
--
-- Se mira contra `disponibilidad_tipo`, que es la misma cuenta que usa
-- `crear_orden` para decidir si te vende. Preguntarlo de otra forma acá
-- sería tener dos definiciones de "queda cupo", y el día que difieran la
-- pantalla ofrece un precio que la compra rechaza.
--
-- ── el efecto de las órdenes pendientes ─────────────────────
--
-- `disponibilidad_tipo` descuenta lo pendiente sin vencer, así que
-- treinta personas con la pasarela abierta agotan Hot ticket aunque
-- todavía no hayan pagado, y el que llega después compra a 90. Es lo
-- correcto: esas treinta entradas están reservadas y a esa persona no se
-- le puede prometer un precio que quizás no exista en dos minutos. Si
-- caducan sin pagar, el cupo vuelve y la fase revive sola.
--
-- ── una fase sin precios no es una fase ─────────────────────
--
-- Antes, una fase creada y todavía sin cargar precios se devolvía como
-- vigente y la compra fallaba adentro con un error sin explicación. El
-- `exists` la saltea: si no hay nada cargado, no hay nada que vender.
--
-- Firma sin cambios (p_evento uuid, returns uuid): `create or replace`
-- alcanza y no hay que tocar a los que la llaman.
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
         join tipo_entrada t on t.id = fp.tipo_id and t.activo
        where fp.fase_id = f.id
          -- cupo nulo = sin límite; con límite, que quede algo.
          and (fp.cupo is null or coalesce(disponibilidad_tipo(f.id, fp.tipo_id), 1) > 0))
   order by f.orden
   limit 1
$$;
revoke execute on function fase_vigente(uuid) from anon, public;
grant execute on function fase_vigente(uuid) to authenticated;

comment on function fase_vigente(uuid) is
  'La fase abierta ahora: la primera por orden que este dentro de su ventana de fechas Y todavia tenga algo para vender. Una fase con el cupo agotado da paso a la siguiente, que es como se vende por fases de cantidad (Hot ticket, Fase 1, Fase Final).';
