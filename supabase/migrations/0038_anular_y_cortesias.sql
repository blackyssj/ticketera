-- ============================================================
-- 0038 — anular, regalar y resolver una revisión manual
--
-- El esquema tiene `entradas.estado = 'anulada'` desde 0007 y
-- `entradas.canal = 'cortesia'` desde el mismo día. Los dos se LEEN en
-- todos lados —la disponibilidad, el tablero, las comisiones del
-- relacionador, la puerta— y hasta hoy no había una sola función que los
-- ESCRIBIERA. Lo mismo con `ordenes.estado = 'revision_manual'`, que
-- emitir_orden (0019) sabe poner y nadie sabía sacar.
--
-- O sea: un pago doble, un contracargo, veinte entradas para la prensa o
-- una orden que la pasarela cobró por otro monto se resolvían entrando a
-- la base con SQL. Eso no escala y, sobre todo, no es del organizador:
-- es de quien tenga el PAT.
--
-- Son tres operaciones y van juntas porque comparten la misma forma: la
-- decisión de una persona, con un motivo, que queda escrita.
--
-- ── por qué el registro va en una tabla aparte ───────────────
--
-- La alternativa era guardar `anulada_por`, `anulada_at` y `motivo` como
-- columnas de `ordenes` y de `entradas`. Se descartó por cuatro razones,
-- y la primera sola ya alcanza:
--
-- 1) `ordenes` la puede escribir cualquier admin por PostgREST. La policy
--    "ordenes escribir" de 0012 le da update a puede_editar(), así que
--    una columna `anulacion_motivo` ahí es un motivo que el que anuló
--    puede reescribir mañana. Un registro que se puede corregir no es un
--    registro — es la misma frase de 0034 y por la misma razón.
-- 2) Una emisión de cortesías es una decisión sola sobre N entradas y sin
--    ninguna orden detrás: no hay fila a la cual colgarle el motivo. Y la
--    anulación de una orden en revisión manual pasa al revés: la orden no
--    tiene NINGUNA entrada, así que un registro por entrada tampoco sirve.
--    Lo que se anota es la decisión, no la fila que tocó.
-- 3) Una entrada puede nacer cortesía y anularse después: dos decisiones,
--    dos autores, dos motivos. En columnas serían dos juegos de columnas
--    en la tabla más caliente del sistema —la que escanea la puerta— y la
--    segunda decisión pisaría a la primera igual.
-- 4) La forma ya existe y funciona: `puerta_bitacora` (0034). Dos
--    bitácoras con la misma forma se leen igual; una tabla con seis
--    columnas nuevas no se parece a nada.
--
-- No se reusó `puerta_bitacora` misma porque es de la puerta: su policy
-- de insert deja escribir a `es_portero()`, sus índices están afinados
-- para el ritmo de escaneo de una noche y su `accion` es un vocabulario
-- de molinete. Mezclar las decisiones del escritorio ahí obliga a filtrar
-- en las dos direcciones para siempre.
--
-- Append-only de verdad, igual que 0034: `grant` de select e insert y
-- nada más. Sin update, sin delete y sin truncate (invariante 6, y
-- Supabase los otorga solos en cada tabla nueva).
--
-- ── el cupo se libera solo, y hay que confirmarlo antes ──────
--
-- `disponibilidad_tipo` NO cuenta filas de `entradas` desde 0018: cuenta
-- `orden_items.cantidad` de las órdenes `pagada`, porque el cupo se mide
-- en unidades vendidas y no en manillas emitidas. De ahí salen tres
-- consecuencias que hay que tener claras antes de tocar nada:
--
--   · Anular una ORDEN devuelve el cupo solo: la orden deja de estar
--     'pagada' y su renglón desaparece de la resta. Por eso acá no hay
--     una sola línea que toque el cupo a mano — si la hubiera, el cupo
--     volvería dos veces y el evento se sobrevendería.
--   · Anular una MANILLA suelta de una orden pagada NO devuelve cupo, y
--     está bien: la unidad se vendió y se cobró. Lo que se perdió es una
--     manilla, no una venta.
--   · Una CORTESÍA no tiene orden, así que hoy no la vería nadie. Ese es
--     el único lugar donde esta migración toca la cuenta, y lo hace
--     agregando un término, no restando por afuera.
--
-- ── qué NO hace esta migración ──────────────────────────────
--
-- No devuelve plata. Anular una orden pagada la marca anulada y libera lo
-- que ocupaba; el reintegro lo hace quien tiene la pasarela, y la orden
-- queda con su `pago_ref` intacto para que se pueda ir a buscar. Poner
-- acá un botón que diga "devolver" sería prometer algo que este sistema
-- no puede cumplir.
--
-- Idempotente: `create table if not exists`, `add column if not exists`,
-- `create index if not exists`, `drop policy if exists` delante de cada
-- policy y `drop function if exists` con la firma completa delante de
-- cada función (invariante 4: dos firmas vivas dejan a PostgREST sin
-- candidata y la función muere sin avisar). Correrla dos veces seguidas
-- no falla.
-- ============================================================

-- ============================================================
-- 1) admin_bitacora — quién decidió qué, y por qué
--
-- La tabla se llama `admin_bitacora` y la función que la lee
-- `bitacora_admin`, por el mismo motivo que en 0034: con el mismo nombre
-- Postgres los deja convivir, pero `admin_bitacora(x)` de un argumento se
-- puede leer como selección de campo de un registro.
--
-- Una fila por DECISIÓN, no por fila tocada. Anular una orden de treinta
-- manillas es una fila; emitir veinte cortesías es una fila con los
-- veinte códigos adentro. Es la unidad en la que después se pregunta:
-- nadie audita "quién anuló esta manilla de las treinta", audita "quién
-- anuló esta compra".
-- ============================================================
create table if not exists admin_bitacora (
  id             uuid primary key default gen_random_uuid(),
  organizador_id uuid not null references organizadores on delete restrict,
  evento_id      uuid not null references eventos  on delete cascade,
  accion         text not null check (accion in
                   ('orden_anulada','entrada_anulada','cortesias_emitidas','revision_confirmada')),
  -- Las dos referencias son opcionales y nunca las dos a la vez por
  -- accidente: una anulación de orden trae orden_id, una de manilla trae
  -- las dos, y una emisión de cortesías no trae ninguna porque no hay
  -- orden y hay N entradas (van por código en `detalle`).
  orden_id       uuid references ordenes  on delete cascade,
  entrada_id     uuid references entradas on delete cascade,
  -- El motivo es NOT NULL y además no puede ser blanco. La guardia está
  -- en la base y no en la pantalla a propósito: una anulación sin motivo,
  -- tres meses después, es indistinguible de un error o de un robo.
  motivo         text not null check (btrim(motivo) <> ''),
  actor_id       uuid not null references perfiles(id),
  ocurrio_at     timestamptz not null default clock_timestamp(),
  detalle        jsonb not null default '{}'::jsonb
);

comment on table admin_bitacora is
  'Una fila por cada decision de escritorio que mueve plata o gente: anular una compra, anular una manilla, emitir cortesias, confirmar una revision manual. Append-only: se agrega y se lee, no se edita ni se borra. La escriben las funciones de 0038 en la MISMA transaccion que el cambio, asi que no existe el caso "el cambio salio y el registro no".';
comment on column admin_bitacora.motivo is
  'Por que se hizo. Obligatorio y no blanco, en la base. Es la mitad del registro que no se puede reconstruir despues.';
comment on column admin_bitacora.actor_id is
  'Quien la hizo. Sale de auth.uid() adentro de la funcion, nunca de un parametro: por parametro, el navegador podria firmar con el nombre del companero.';
comment on column admin_bitacora.detalle is
  'Lo que la fila referenciada ya no dice: cuantas manillas se anularon, cuantas de esas ya habian entrado, el estado previo de la orden, los codigos de las cortesias emitidas.';

-- Dos preguntas y un índice para cada una: "todo lo que pasó en este
-- evento" (el tablero, lo más nuevo primero) y "qué pasó con esta orden"
-- (la discusión concreta con un comprador).
create index if not exists admin_bitacora_evento_idx
  on admin_bitacora (evento_id, ocurrio_at desc);
create index if not exists admin_bitacora_orden_idx
  on admin_bitacora (orden_id, ocurrio_at desc) where orden_id is not null;

alter table admin_bitacora enable row level security;

-- Leer: solo quien puede editar. No es la bitácora de la puerta, donde el
-- portero necesita revisar sus propios escaneos; acá adentro están los
-- motivos de las anulaciones, con nombres de compradores y montos.
drop policy if exists "admin bitacora leer" on admin_bitacora;
create policy "admin bitacora leer" on admin_bitacora for select to authenticated
  using (organizador_id = mi_organizador() and puede_editar());

-- Escribir: solo hacia adelante y solo firmando con el propio uid. El
-- camino real es la función; esta policy existe para que lo único que
-- alguien pueda escribir a mano sea una fila con su nombre, al lado de
-- todas las demás, y que después no la pueda sacar.
drop policy if exists "admin bitacora agregar" on admin_bitacora;
create policy "admin bitacora agregar" on admin_bitacora for insert to authenticated
  with check (organizador_id = mi_organizador()
              and puede_editar()
              and actor_id = auth.uid()
              and exists (select 1 from eventos e
                           where e.id = admin_bitacora.evento_id
                             and e.organizador_id = mi_organizador()));

-- El `revoke all` antes del grant no es ceremonia: Supabase otorga solo,
-- por default privileges, todo lo de una tabla nueva a anon y a
-- authenticated —update, delete, truncate, trigger y references
-- incluidos—. Sin esta línea la bitácora nace editable y borrable.
revoke all on admin_bitacora from anon, authenticated;
grant select, insert on admin_bitacora to authenticated;

-- ============================================================
-- 2) ordenes.monto_cobrado — lo que la pasarela cobró de verdad
--
-- Una orden cae en `revision_manual` cuando `p_monto_cobrado <> o.total`
-- (0019). La cifra que disparó la revisión no se guardaba en ningún lado:
-- llegaba por parámetro, decidía el estado y se perdía. Quien abre esa
-- orden dos días después ve "en revisión" y el total esperado, y tiene
-- que ir a la pasarela con el `pago_ref` para enterarse de cuánto entró.
--
-- Es el dato central de la decisión más delicada del sistema —hay plata
-- cobrada y no hay entradas emitidas— y no estaba escrito. Ahora sí.
-- ============================================================
alter table ordenes add column if not exists monto_cobrado numeric(12,2);

comment on column ordenes.monto_cobrado is
  'Lo que la pasarela dijo haber cobrado, cuando no coincidio con el total. Se escribe solo en el camino que manda la orden a revision_manual: en una orden normal es null porque cobrado y total son lo mismo.';

-- ============================================================
-- 3) disponibilidad_tipo — una cortesía ocupa un lugar físico
--
-- Sin este término, una cortesía sería la única entrada del sistema que
-- entra al evento sin descontar de ningún lado: el organizador que regala
-- cincuenta seguiría viendo cincuenta lugares para vender y el sábado
-- habría cincuenta personas de más en la puerta.
--
-- El término cuenta `entradas` sin orden, que es exactamente lo que la
-- cuenta de 0018 no puede ver: `v_emitidas` sale de `orden_items`, así
-- que toda entrada con `orden_id` ya está contada ahí y contarla otra vez
-- acá la restaría dos veces. El filtro es `orden_id is null` y no
-- `canal = 'cortesia'` a propósito: lo que decide si hay que contarla es
-- si tiene o no una orden que la cuente, no de qué canal vino.
--
-- Y la conversión a unidades. El cupo se mide en unidades (0018) y una
-- fila de `entradas` es una manilla, así que N manillas de cortesía de un
-- producto que emite M manillas por unidad son ceil(N/M) unidades. Para
-- el caso normal —una entrada suelta, M = 1— es exactamente N. Para un
-- combo de 10 del que se regalan 3 manillas, es 1: esas tres personas
-- ocupan una mesa que ya no se puede vender, y redondear para abajo sería
-- venderla dos veces.
--
-- `estado <> 'anulada'` es lo que hace que anular una cortesía devuelva
-- su lugar sin que ninguna función toque el cupo.
-- ============================================================
create or replace function disponibilidad_tipo(p_fase uuid, p_tipo uuid) returns int
  language plpgsql stable security definer set search_path = public as $function$
declare v_cupo int; v_emitidas int; v_retenidas int; v_cortesias int; v_manillas int;
begin
  select cupo into v_cupo from fase_precio where fase_id = p_fase and tipo_id = p_tipo;
  if not found then return 0; end if;
  if v_cupo is null then return null; end if;

  select coalesce(sum(i.cantidad), 0) into v_emitidas
    from orden_items i join ordenes o on o.id = i.orden_id
   where i.fase_id = p_fase and i.tipo_id = p_tipo and o.estado = 'pagada';

  select coalesce(sum(i.cantidad), 0) into v_retenidas
    from orden_items i join ordenes o on o.id = i.orden_id
   where i.fase_id = p_fase and i.tipo_id = p_tipo
     and o.estado = 'pendiente' and o.expira_at > now();

  select greatest(coalesce(manillas, 1), 1) into v_manillas
    from tipo_entrada where id = p_tipo;
  select coalesce(ceil(count(*)::numeric / coalesce(v_manillas, 1)), 0)::int
    into v_cortesias
    from entradas e
   where e.fase_id = p_fase and e.tipo_id = p_tipo
     and e.orden_id is null and e.estado <> 'anulada';

  return greatest(v_cupo - v_emitidas - v_cortesias - v_retenidas, 0);
end $function$;
revoke execute on function disponibilidad_tipo(uuid, uuid) from anon, public;
grant execute on function disponibilidad_tipo(uuid, uuid) to authenticated;

comment on function disponibilidad_tipo(uuid, uuid) is
  'Cuantas unidades quedan de un tipo en una fase. Resta lo vendido (orden_items de ordenes pagadas), lo retenido (pendientes vivas) y las cortesias (entradas sin orden, convertidas a unidades). Una anulada no resta por ninguno de los tres caminos.';

-- ============================================================
-- 4) resumen_evento — la alerta que las cortesías harían mentir
--
-- `alertas.manillas_sin_orden_pagada` cuenta entradas vivas cuya orden no
-- está pagada, y su propio comentario dice que en una base sana es CERO
-- siempre; por eso la tarjeta ni aparece cuando lo es. Una cortesía es,
-- por definición, una entrada viva sin orden pagada: con la primera
-- cortesía emitida esa alerta se prende para no apagarse nunca más, y una
-- alerta permanente es una alerta que se aprende a pasar de largo — justo
-- el día que deja de ser cero por el motivo de verdad.
--
-- Cambia UNA línea de 0033 y por eso la función se copia entera: Postgres
-- no sabe reemplazar medio cuerpo. El resto es idéntico a 0033, para que
-- el diff se lea de una.
--
-- Las cortesías no desaparecen del tablero: siguen contadas en `vendido`,
-- en `puerta` y en su propio renglón de `canales`, que es donde se las
-- mira. Lo que dejan de hacer es disfrazarse de fuga de plata.
-- ============================================================
create or replace function resumen_evento(p_evento uuid) returns jsonb
  language plpgsql stable security definer set search_path = public as $function$
declare
  v_org  uuid := mi_organizador();
  v_ev   eventos;
  v_fase uuid;
begin
  if not puede_editar() then raise exception 'Sin permiso'; end if;

  select * into v_ev from eventos where id = p_evento and organizador_id = v_org;
  if not found then return '{}'::jsonb; end if;

  v_fase := fase_vigente(p_evento);

  return jsonb_build_object(
    'evento', jsonb_build_object(
      'id', v_ev.id, 'slug', v_ev.slug, 'nombre', v_ev.nombre,
      'fecha', v_ev.fecha, 'estado', v_ev.estado,
      'fase_id', v_fase,
      'fase_nombre', (select f.nombre from evento_fase f where f.id = v_fase),
      'generado_at', now()),

    'vendido', (
      select jsonb_build_object(
        'manillas',          coalesce(count(*) filter (where e.estado <> 'anulada'), 0)::int,
        'manillas_validas',  coalesce(count(*) filter (where e.estado = 'valida'), 0)::int,
        'manillas_usadas',   coalesce(count(*) filter (where e.estado = 'usada'), 0)::int,
        'manillas_anuladas', coalesce(count(*) filter (where e.estado = 'anulada'), 0)::int)
        from entradas e
       where e.evento_id = p_evento and e.organizador_id = v_org)
      || (
      select jsonb_build_object(
        'ordenes',    coalesce(count(*), 0)::int,
        'unidades',   coalesce((select sum(i.cantidad) from orden_items i
                                 where i.orden_id in (select o2.id from ordenes o2
                                                       where o2.evento_id = p_evento
                                                         and o2.organizador_id = v_org
                                                         and o2.estado = 'pagada')), 0)::int,
        'recaudado',  coalesce(sum(o.subtotal), 0)::numeric(12,2),
        'fee',        coalesce(sum(o.fee), 0)::numeric(12,2),
        'total',      coalesce(sum(o.total), 0)::numeric(12,2),
        'ticket_promedio', case when count(*) = 0 then 0::numeric(12,2)
                                else (sum(o.subtotal) / count(*))::numeric(12,2) end)
        from ordenes o
       where o.evento_id = p_evento and o.organizador_id = v_org and o.estado = 'pagada'),

    'productos', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'tipo_id',             t.id,
               'nombre',              t.nombre,
               'categoria',           t.categoria,
               'activo',              t.activo,
               'manillas_por_unidad', t.manillas,
               'precio',              fp.precio,
               'cupo',                fp.cupo,
               'quedan',              case when fp.tipo_id is null then null
                                           else disponibilidad_tipo(v_fase, t.id) end,
               'en_venta',            (fp.tipo_id is not null and t.activo),
               'unidades',            coalesce(pt.unidades, 0),
               'manillas',            coalesce(mt.manillas, 0),
               'manillas_usadas',     coalesce(mt.usadas, 0),
               'manillas_anuladas',   coalesce(mt.anuladas, 0),
               'recaudado',           coalesce(pt.recaudado, 0)::numeric(12,2))
             order by t.orden, t.nombre), '[]'::jsonb)
        from tipo_entrada t
        left join fase_precio fp on fp.fase_id = v_fase and fp.tipo_id = t.id
        left join (
          select i.tipo_id,
                 sum(i.cantidad)::int as unidades,
                 sum(i.cantidad * i.precio_unitario)::numeric(12,2) as recaudado
            from orden_items i
            join ordenes o on o.id = i.orden_id
           where o.evento_id = p_evento and o.organizador_id = v_org
             and o.estado = 'pagada' and i.tipo_id is not null
           group by i.tipo_id) pt on pt.tipo_id = t.id
        left join (
          select e.tipo_id,
                 count(*) filter (where e.estado <> 'anulada')::int as manillas,
                 count(*) filter (where e.estado = 'usada')::int   as usadas,
                 count(*) filter (where e.estado = 'anulada')::int as anuladas
            from entradas e
           where e.evento_id = p_evento and e.organizador_id = v_org
             and e.tipo_id is not null
           group by e.tipo_id) mt on mt.tipo_id = t.id
       where t.evento_id = p_evento and t.organizador_id = v_org),

    'canales', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'canal',             c.canal,
               'manillas',          coalesce(x.manillas, 0),
               'manillas_usadas',   coalesce(x.usadas, 0),
               'manillas_anuladas', coalesce(x.anuladas, 0),
               'ordenes',           coalesce(x.ordenes, 0))
             order by c.pos), '[]'::jsonb)
        from (values ('publico', 1), ('rrpp', 2), ('puerta', 3), ('cortesia', 4))
             as c(canal, pos)
        left join (
          select e.canal,
                 count(*) filter (where e.estado <> 'anulada')::int as manillas,
                 count(*) filter (where e.estado = 'usada')::int    as usadas,
                 count(*) filter (where e.estado = 'anulada')::int  as anuladas,
                 count(distinct e.orden_id)::int                    as ordenes
            from entradas e
           where e.evento_id = p_evento and e.organizador_id = v_org
           group by e.canal) x on x.canal = c.canal),

    'estados', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'estado',   s.estado,
               'ordenes',  coalesce(x.n, 0),
               'subtotal', coalesce(x.sub, 0)::numeric(12,2),
               'fee',      coalesce(x.fee, 0)::numeric(12,2),
               'total',    coalesce(x.tot, 0)::numeric(12,2))
             order by s.pos), '[]'::jsonb)
        from (values ('pagada', 1), ('pendiente', 2), ('vencida', 3),
                     ('revision_manual', 4), ('anulada', 5)) as s(estado, pos)
        left join (
          select o.estado, count(*)::int as n,
                 sum(o.subtotal) as sub, sum(o.fee) as fee, sum(o.total) as tot
            from ordenes o
           where o.evento_id = p_evento and o.organizador_id = v_org
           group by o.estado) x on x.estado = s.estado),

    'puerta', (
      select jsonb_build_object(
        'emitidas',   coalesce(count(*) filter (where e.estado <> 'anulada'), 0)::int,
        'usadas',     coalesce(count(*) filter (where e.estado = 'usada'), 0)::int,
        'faltan',     coalesce(count(*) filter (where e.estado = 'valida'), 0)::int,
        'porcentaje', case when count(*) filter (where e.estado <> 'anulada') = 0 then 0::numeric(5,2)
                           else (100.0 * count(*) filter (where e.estado = 'usada')
                                 / count(*) filter (where e.estado <> 'anulada'))::numeric(5,2) end)
        from entradas e
       where e.evento_id = p_evento and e.organizador_id = v_org),

    'mesas', (
      select jsonb_build_object(
        'total',     coalesce(count(*), 0)::int,
        'asignadas', coalesce(count(*) filter (where m.orden_id is not null or a.id is not null), 0)::int,
        'libres',    coalesce(count(*) filter (where m.orden_id is null and a.id is null), 0)::int,
        'manillas',  coalesce(sum(m.manillas), 0)::int)
        from mesas m
        left join lateral (
          select o.id from ordenes o
           where o.mesa_asignada_id = m.id and o.organizador_id = v_org limit 1) a on true
       where m.evento_id = p_evento and m.organizador_id = v_org),

    'alertas', jsonb_build_object(

      'revision_manual', (
        select jsonb_build_object('ordenes', coalesce(count(*), 0)::int,
                                  'monto', coalesce(sum(o.total), 0)::numeric(12,2))
          from ordenes o
         where o.evento_id = p_evento and o.organizador_id = v_org
           and o.estado = 'revision_manual'),

      'vencidas', (
        select jsonb_build_object('ordenes', coalesce(count(*), 0)::int,
                                  'monto', coalesce(sum(o.total), 0)::numeric(12,2))
          from ordenes o
         where o.evento_id = p_evento and o.organizador_id = v_org
           and o.estado = 'vencida'),

      'pendientes_vencidas', (
        select jsonb_build_object('ordenes', coalesce(count(*), 0)::int,
                                  'monto', coalesce(sum(o.total), 0)::numeric(12,2))
          from ordenes o
         where o.evento_id = p_evento and o.organizador_id = v_org
           and o.estado = 'pendiente' and o.expira_at <= now()),

      'pendientes_vivas', (
        select jsonb_build_object('ordenes', coalesce(count(*), 0)::int,
                                  'monto', coalesce(sum(o.total), 0)::numeric(12,2))
          from ordenes o
         where o.evento_id = p_evento and o.organizador_id = v_org
           and o.estado = 'pendiente' and o.expira_at > now()),

      'mesas_sin_asignar', (
        select jsonb_build_object(
                 'ordenes',  coalesce(count(*), 0)::int,
                 'manillas', coalesce(sum(
                   (select count(*) from entradas e
                     where e.orden_id = o.id and e.estado <> 'anulada')), 0)::int,
                 'monto',    coalesce(sum(o.subtotal), 0)::numeric(12,2))
          from ordenes o
         where o.evento_id = p_evento and o.organizador_id = v_org
           and o.estado = 'pagada'
           and o.mesa_asignada_id is null
           and not exists (select 1 from mesas m where m.orden_id = o.id)
           and exists (select 1 from orden_items i
                        left join tipo_entrada t on t.id = i.tipo_id
                       where i.orden_id = o.id
                         and (i.mesa_id is not null or t.categoria = 'mesa'))),

      -- La línea que cambia respecto de 0033: `e.canal <> 'cortesia'`.
      -- Una cortesía es una entrada viva sin orden pagada a propósito y
      -- por decisión de alguien que firmó el motivo en admin_bitacora. Lo
      -- que esta alerta busca es lo otro: gente que pasa el molinete y
      -- nadie decidió ni cobró nada.
      'manillas_sin_orden_pagada', (
        select coalesce(count(*), 0)::int
          from entradas e
          left join ordenes o on o.id = e.orden_id
         where e.evento_id = p_evento and e.organizador_id = v_org
           and e.estado <> 'anulada'
           and e.canal <> 'cortesia'
           and (o.id is null or o.estado <> 'pagada'))));
end $function$;
revoke execute on function resumen_evento(uuid) from anon, public;
grant execute on function resumen_evento(uuid) to authenticated;

comment on function resumen_evento(uuid) is
  'El tablero de un evento: lo vendido, el desglose por producto / canal /
   estado de orden, el avance de la puerta, el estado de las mesas y las
   cifras de fuga (revisión manual, vencidas, mesas pagadas sin asignar).
   Exige puede_editar(). Acota por mi_organizador() adentro: con el evento
   de otro organizador devuelve {}. Lo recaudado sale de ordenes.subtotal,
   nunca de sumar entradas.precio. Las cortesías no cuentan como manillas
   sin orden pagada: son entradas sin orden por decisión firmada.';

-- ============================================================
-- 5) emitir_orden — la única puerta de emisión, ahora también para la
--    revisión manual
--
-- Confirmar una revisión manual es emitir las entradas de esa orden. La
-- tentación es escribir la emisión de nuevo adentro de resolver_revision:
-- es cómo se termina con dos caminos que emiten, que difieren en algo
-- —las manillas de un combo, el precio congelado, la mesa que se marca
-- pagada— y que al año nadie sabe cuál es el bueno.
--
-- Así que se reusa esta, y para eso hace falta que sepa que la están
-- llamando desde una revisión resuelta. Dos cosas cambian y solo con la
-- bandera puesta:
--
--   · `revision_manual` deja de ser un motivo para negarse. Sigue
--     siéndolo para el callback de la pasarela y para el navegador, que
--     son los que llaman sin bandera: una orden en revisión no se emite
--     sola porque alguien apriete "verificar pago" otra vez.
--   · El vencimiento deja de aplicar. Una orden que estuvo dos días en
--     revisión venció hace rato, y vencerla de nuevo sería negarle la
--     entrada a alguien a quien YA se le cobró. El chequeo se acota a
--     `estado = 'pendiente'`, que es el único caso en el que expirar
--     significa algo: la reserva viva que no llegó a pagarse.
--
-- La firma cambia, así que va drop + create con la firma vieja completa.
-- El cuerpo que se copia es el de 0027 —el último, el que escribe
-- `canal = 'rrpp'` y el `rrpp_id` en cada entrada—, no el de 0019: copiar
-- una versión vieja de una función que ya fue parcheada cuatro veces es
-- cómo se deshace un arreglo sin que nadie lo note.
-- Y OJO con el `revoke` de abajo: un drop + create deja la función con el
-- execute que Postgres le da a PUBLIC por defecto. Sin esa línea, anon
-- podría emitir órdenes (invariante 3 lo atraparía, pero recién en el
-- test). No lleva grant a authenticated y eso no es un olvido: la emisión
-- la disparan las Edge Functions con service_role, que no pasan por los
-- grants; darle execute a authenticated sería dejar que cualquier admin
-- emita cualquier orden sin que se cobre nada.
-- ============================================================
drop function if exists emitir_orden(uuid, numeric, text);
drop function if exists emitir_orden(uuid, numeric, text, boolean);
create function emitir_orden(
  p_orden uuid, p_monto_cobrado numeric default null, p_pago_ref text default null,
  p_desde_revision boolean default false
) returns jsonb
  language plpgsql volatile security definer set search_path = public as $function$
declare o ordenes; v_n int; v_it record; i int; v_manillas int; v_canal text;
begin
  select * into o from ordenes where id = p_orden for update;
  if not found then raise exception 'ORDEN_INEXISTENTE: %', p_orden; end if;

  if o.estado = 'pagada' then
    select count(*) into v_n from entradas where orden_id = p_orden;
    return jsonb_build_object('ok', true, 'orden', p_orden, 'entradas', v_n, 'repetida', true);
  end if;
  if o.estado = 'anulada' then
    return jsonb_build_object('ok', false, 'motivo', 'ANULADA');
  end if;
  if o.estado = 'revision_manual' and not coalesce(p_desde_revision, false) then
    return jsonb_build_object('ok', false, 'motivo', 'REVISION_MANUAL');
  end if;

  -- Solo una reserva viva puede vencer. Una orden en revisión resuelta ya
  -- pasó por caja: su expira_at es historia, no una regla.
  if o.estado = 'pendiente' and o.expira_at <= now() then
    update ordenes set estado = 'vencida' where id = p_orden and estado = 'pendiente';
    return jsonb_build_object('ok', false, 'motivo', 'VENCIDA');
  end if;

  if p_monto_cobrado is not null and p_monto_cobrado <> o.total then
    update ordenes set estado = 'revision_manual', pago_ref = coalesce(p_pago_ref, pago_ref),
                       monto_cobrado = p_monto_cobrado
     where id = p_orden;
    return jsonb_build_object('ok', false, 'motivo', 'MONTO',
                              'esperado', o.total, 'cobrado', p_monto_cobrado);
  end if;

  -- Se decide una vez, antes del bucle: todas las entradas de una orden
  -- vienen del mismo lugar.
  v_canal := case when o.rrpp_id is not null then 'rrpp' else 'publico' end;

  for v_it in select * from orden_items where orden_id = p_orden loop
    if v_it.tipo_id is not null then
      -- cuánta gente entra con UNA unidad de este tipo
      select coalesce(manillas, 1) into v_manillas from tipo_entrada where id = v_it.tipo_id;
      for i in 1 .. (v_it.cantidad * greatest(v_manillas, 1)) loop
        insert into entradas (organizador_id, evento_id, orden_id, code, canal,
                              tipo_id, fase_id, rrpp_id, cliente, precio)
        values (o.organizador_id, o.evento_id, p_orden, nuevo_code(), v_canal,
                v_it.tipo_id, v_it.fase_id, o.rrpp_id, o.comprador_nombre,
                v_it.precio_unitario);
      end loop;
    else
      insert into entradas (organizador_id, evento_id, orden_id, code, canal,
                            mesa_id, rrpp_id, cliente, precio)
      select o.organizador_id, o.evento_id, p_orden, nuevo_code(), v_canal,
             m.id, o.rrpp_id, o.comprador_nombre, 0
        from mesas m, generate_series(1, m.manillas) where m.id = v_it.mesa_id;
      update mesas set estado = 'pagada', updated_at = now() where id = v_it.mesa_id;
    end if;
  end loop;

  update ordenes set estado = 'pagada', pagada_at = now(),
                     pago_ref = coalesce(p_pago_ref, pago_ref)
   where id = p_orden;
  select count(*) into v_n from entradas where orden_id = p_orden;
  return jsonb_build_object('ok', true, 'orden', p_orden, 'entradas', v_n, 'repetida', false);
end $function$;
revoke execute on function emitir_orden(uuid, numeric, text, boolean) from anon, public;

comment on function emitir_orden(uuid, numeric, text, boolean) is
  'Emite las entradas de una orden y la deja pagada. Idempotente: repetirla no duplica nada. Se niega con VENCIDA si la reserva expiro sin pagarse, con MONTO si la pasarela cobro otra cifra (y ahi la manda a revision_manual guardando monto_cobrado), y con REVISION_MANUAL o ANULADA segun el estado. p_desde_revision solo la usa resolver_revision(): saltea la negativa por revision_manual y el vencimiento, que en una orden ya cobrada no significan nada. Sin grant a authenticated: la llaman las Edge Functions con service_role.';

-- ============================================================
-- 6) anular_orden — deshacer una compra entera
--
-- Anula sus entradas, la deja en 'anulada' y suelta las mesas que
-- ocupaba. El cupo vuelve solo (ver el bloque 3): acá no hay una línea
-- que lo toque.
--
-- ── por qué una entrada 'usada' frena la anulación ───────────
--
-- Esa persona ya entró. Anular su manilla no la saca de adentro: lo único
-- que cambia es que el tablero pasa a decir que entró menos gente de la
-- que hay, y el que cuenta cabezas en la puerta deja de poder confiar en
-- el número. Por eso el camino por defecto se niega y dice CUÁNTAS
-- entraron, que es el dato con el que se decide qué hacer.
--
-- Y por eso seguir es un parámetro aparte y explícito, no un "si igual
-- insiste". Hay motivos legítimos —un contracargo de alguien que sí
-- entró es el caso típico: la plata se va, la persona ya bailó—. Cuando
-- se usa, las manillas usadas se anulan también y el "ya entraron" del
-- tablero baja. Es el precio, y se paga a ojos abiertos: la fila conserva
-- su `used_at` y su `portero_id` intactos, y admin_bitacora guarda
-- cuántas de las anuladas ya habían entrado. El ingreso sigue escrito en
-- los dos lados; lo que cambia es que esas manillas dejan de contar como
-- vendidas.
--
-- ── las dos puntas de la mesa ────────────────────────────────
--
-- Una orden puede tener mesa por `ordenes.mesa_asignada_id` (el admin la
-- repartió, 0029) o por `mesas.orden_id` (el cliente compró esa chapa,
-- 0015). Se sueltan las dos: soltar una sola deja una mesa vendida a una
-- compra que ya no existe, y eso se descubre el sábado con dos grupos
-- parados. La primera se suelta llamando a liberar_mesa() y no repitiendo
-- su update acá: es la función que ya sabe hacerlo bien, con el update
-- condicional que no le roba la mesa a otro.
-- ============================================================
drop function if exists anular_orden(uuid, text, boolean);
create function anular_orden(p_orden uuid, p_motivo text,
                             p_incluir_usadas boolean default false) returns jsonb
  language plpgsql volatile security definer set search_path = public as $function$
declare
  v_org    uuid := mi_organizador();
  v_motivo text := btrim(coalesce(p_motivo, ''));
  o ordenes;
  v_usadas int; v_anuladas int; v_chapas int;
  v_mesa jsonb; v_libero boolean := false;
begin
  if not puede_editar() then raise exception 'Sin permiso'; end if;
  if v_motivo = '' then
    raise exception 'MOTIVO_REQUERIDO: sin motivo no se anula. Una anulación sin motivo, tres meses después, es indistinguible de un error o de un robo.';
  end if;

  select * into o from ordenes where id = p_orden for update;
  if not found then raise exception 'ORDEN_INEXISTENTE: %', p_orden; end if;
  -- El corte de tenant, adentro. p_orden llega del navegador y puede ser
  -- de otro cliente: `security definer` se saltea la RLS.
  if o.organizador_id is distinct from v_org then raise exception 'Sin permiso'; end if;

  if o.estado = 'anulada' then
    return jsonb_build_object('ok', true, 'orden', p_orden, 'ya_estaba', true,
      'entradas_anuladas', 0, 'usadas_incluidas', 0, 'mesa_liberada', false,
      'motivo', 'Esa compra ya estaba anulada.');
  end if;

  select count(*) into v_usadas from entradas
   where orden_id = p_orden and estado = 'usada';
  if v_usadas > 0 and not coalesce(p_incluir_usadas, false) then
    raise exception 'HAY_USADAS: % de esta compra ya % al evento. Anularlas no las saca de adentro; si aun así hay que anularla (un contracargo), volvé pidiendo que se incluyan.',
      v_usadas, case when v_usadas = 1 then 'entró' else 'entraron' end;
  end if;

  update entradas set estado = 'anulada'
   where orden_id = p_orden and estado <> 'anulada';
  get diagnostics v_anuladas = row_count;

  if o.mesa_asignada_id is not null then
    v_mesa := liberar_mesa(p_orden);
    v_libero := coalesce((v_mesa->>'libero')::boolean, false);
  end if;

  update mesas set orden_id = null, estado = 'disponible', updated_at = now()
   where orden_id = p_orden and organizador_id = v_org;
  get diagnostics v_chapas = row_count;

  update ordenes set estado = 'anulada' where id = p_orden;

  insert into admin_bitacora (organizador_id, evento_id, accion, orden_id,
                              motivo, actor_id, detalle)
  values (v_org, o.evento_id, 'orden_anulada', p_orden, v_motivo, auth.uid(),
          jsonb_build_object(
            'estado_previo',    o.estado,
            'comprador',        o.comprador_nombre,
            'entradas_anuladas', v_anuladas,
            'usadas_incluidas', case when coalesce(p_incluir_usadas, false) then v_usadas else 0 end,
            'subtotal',         o.subtotal,
            'total',            o.total,
            'pago_ref',         o.pago_ref,
            'mesa_liberada',    (v_libero or v_chapas > 0)));

  return jsonb_build_object('ok', true, 'orden', p_orden, 'ya_estaba', false,
    'entradas_anuladas', v_anuladas,
    'usadas_incluidas', case when coalesce(p_incluir_usadas, false) then v_usadas else 0 end,
    'mesa_liberada', (v_libero or v_chapas > 0),
    'estado_previo', o.estado,
    'motivo', format('Compra anulada: %s %s y %s.',
      v_anuladas,
      case when v_anuladas = 1 then 'manilla' else 'manillas' end,
      case when (v_libero or v_chapas > 0) then 'la mesa vuelve al ruedo'
           else 'el cupo vuelve a la venta' end));
end $function$;
revoke execute on function anular_orden(uuid, text, boolean) from anon, public;
grant execute on function anular_orden(uuid, text, boolean) to authenticated;

comment on function anular_orden(uuid, text, boolean) is
  'Anula una compra entera: sus entradas pasan a anulada, la orden queda anulada y las mesas que ocupaba (por mesa_asignada_id y por mesas.orden_id) vuelven a estar libres. El cupo se libera solo porque la orden deja de estar pagada — la funcion no lo toca. Exige puede_editar() y que la orden sea del organizador de quien llama, resuelto con mi_organizador() adentro. El motivo es obligatorio y no puede ser blanco. Se niega si alguna manilla ya entro al evento, diciendo cuantas; p_incluir_usadas es la salida explicita para un contracargo. Deja fila en admin_bitacora.';

-- ============================================================
-- 7) anular_entrada — una manilla suelta
--
-- La manilla perdida, la duplicada, el QR que alguien reenvió por
-- WhatsApp. La compra sigue en pie: se cobró y el resto de sus manillas
-- entran.
--
-- Por eso esto NO devuelve cupo cuando la entrada vino de una orden, y
-- está bien: la unidad se vendió y se cobró, lo que se perdió es una
-- manilla. La excepción es la cortesía, que no tiene orden que la sostenga
-- y por lo tanto sí devuelve su lugar — pero eso también pasa solo, por el
-- `estado <> 'anulada'` de disponibilidad_tipo. Acá no hay ninguna resta.
-- ============================================================
drop function if exists anular_entrada(uuid, text, boolean);
create function anular_entrada(p_entrada uuid, p_motivo text,
                               p_incluir_usadas boolean default false) returns jsonb
  language plpgsql volatile security definer set search_path = public as $function$
declare
  v_org    uuid := mi_organizador();
  v_motivo text := btrim(coalesce(p_motivo, ''));
  e entradas;
begin
  if not puede_editar() then raise exception 'Sin permiso'; end if;
  if v_motivo = '' then
    raise exception 'MOTIVO_REQUERIDO: sin motivo no se anula. Una anulación sin motivo, tres meses después, es indistinguible de un error o de un robo.';
  end if;

  select * into e from entradas where id = p_entrada for update;
  if not found then raise exception 'ENTRADA_INEXISTENTE: %', p_entrada; end if;
  if e.organizador_id is distinct from v_org then raise exception 'Sin permiso'; end if;

  if e.estado = 'anulada' then
    return jsonb_build_object('ok', true, 'entrada', p_entrada, 'code', e.code,
      'ya_estaba', true, 'motivo', format('La manilla %s ya estaba anulada.', e.code));
  end if;

  if e.estado = 'usada' and not coalesce(p_incluir_usadas, false) then
    raise exception 'HAY_USADAS: 1 — la manilla % ya entró al evento. Anularla no la saca de adentro; si aun así hay que hacerlo (un contracargo), volvé pidiendo que se incluya.', e.code;
  end if;

  update entradas set estado = 'anulada' where id = p_entrada;

  insert into admin_bitacora (organizador_id, evento_id, accion, orden_id, entrada_id,
                              motivo, actor_id, detalle)
  values (v_org, e.evento_id, 'entrada_anulada', e.orden_id, p_entrada, v_motivo, auth.uid(),
          jsonb_build_object(
            'code',          e.code,
            'estado_previo', e.estado,
            'canal',         e.canal,
            'cliente',       e.cliente,
            'precio',        e.precio,
            -- Solo una cortesía devuelve su lugar al cupo: es la única
            -- entrada que el cupo cuenta por sí misma.
            'devuelve_cupo', (e.orden_id is null)));

  return jsonb_build_object('ok', true, 'entrada', p_entrada, 'code', e.code,
    'ya_estaba', false, 'estado_previo', e.estado,
    'devuelve_cupo', (e.orden_id is null),
    'motivo', format('Manilla %s anulada.', e.code));
end $function$;
revoke execute on function anular_entrada(uuid, text, boolean) from anon, public;
grant execute on function anular_entrada(uuid, text, boolean) to authenticated;

comment on function anular_entrada(uuid, text, boolean) is
  'Anula UNA manilla sin tocar su compra: la perdida, la duplicada, el QR reenviado. Exige puede_editar() y que la entrada sea del organizador de quien llama. Motivo obligatorio. Se niega si esa manilla ya entro al evento, salvo p_incluir_usadas explicito. No devuelve cupo si la entrada tenia orden —la unidad se vendio y se cobro—; una cortesia si lo devuelve, y eso pasa solo. Deja fila en admin_bitacora.';

-- ============================================================
-- 8) emitir_cortesias — regalar entradas sin inventar plata
--
-- La prensa, el DJ, la marca que puso la barra. Salen con
-- `canal = 'cortesia'`, `precio = 0` y sin orden: no hay nada que cobrar
-- y no hay comprador. Que no tengan orden es lo que las hace honestas en
-- los reportes — ninguna suma a `recaudado`, ninguna infla el ticket
-- promedio, y `ventas_rrpp_base` (0026) no se las atribuye a nadie.
--
-- ── consumen cupo, y por eso necesitan fase ──────────────────
--
-- Una cortesía ocupa un lugar físico igual que una entrada vendida. El
-- organizador que regala cincuenta tiene que ver que le quedan cincuenta
-- menos para vender, o el aforo se descubre en la puerta. El cupo vive en
-- el cruce fase × tipo (0004), así que la entrada necesita `fase_id`:
-- sale de fase_vigente(), la misma que usa crear_orden(). Sin fase
-- vigente no se emite — no habría contra qué descontar.
--
-- Y si no queda cupo, se niega. Podría no hacerlo: son del organizador,
-- que sabrá. Pero el que regala de más no descubre el problema acá, lo
-- descubre en la puerta con gente afuera, y ahí ya no hay nada que
-- decidir.
--
-- ── el tope ─────────────────────────────────────────────────
--
-- Cincuenta por llamada. Un p_cantidad sin techo es un dedo apoyado en el
-- 0 que emite diez mil entradas, y no hay forma de deshacerlas de a una.
-- El número va en el mensaje de error: un "no se puede" sin la cifra
-- obliga a adivinar dónde está el límite probando.
-- ============================================================
drop function if exists emitir_cortesias(uuid, uuid, int, text, text);
create function emitir_cortesias(p_evento uuid, p_tipo uuid, p_cantidad int,
                                 p_para text, p_motivo text) returns jsonb
  language plpgsql volatile security definer set search_path = public as $function$
declare
  v_org    uuid := mi_organizador();
  v_motivo text := btrim(coalesce(p_motivo, ''));
  v_para   text := btrim(coalesce(p_para, ''));
  v_tope   int  := 50;
  v_tipo   tipo_entrada;
  v_fase   uuid; v_manillas int; v_disp int; v_pide int;
  v_codes  text[] := '{}'; v_code text; i int;
begin
  if not puede_editar() then raise exception 'Sin permiso'; end if;
  if v_motivo = '' then
    raise exception 'MOTIVO_REQUERIDO: una cortesía sin motivo es una entrada que nadie firmó.';
  end if;
  -- A nombre de quién van no es adorno: es lo que la puerta lee en el
  -- cartel cuando escanea. Una cortesía a nombre de nadie es una manilla
  -- que cualquiera puede reclamar.
  if v_para = '' then
    raise exception 'PARA_REQUERIDO: decí a nombre de quién van (la prensa, el DJ, la marca).';
  end if;
  if p_cantidad is null or p_cantidad < 1 then
    raise exception 'CANTIDAD_INVALIDA: son cortesías de a una para arriba, llegó %.', coalesce(p_cantidad, 0);
  end if;
  if p_cantidad > v_tope then
    raise exception 'TOPE_CORTESIAS: el máximo por vez son % manillas y se pidieron %. Si de verdad son más, van en varias tandas.', v_tope, p_cantidad;
  end if;

  -- Tenant y evento, adentro y con la misma respuesta para "no existe"
  -- que para "no es tuyo": así no sirve de oráculo de qué uuids hay en la
  -- base del vecino.
  if not exists (select 1 from eventos ev
                  where ev.id = p_evento and ev.organizador_id = v_org) then
    raise exception 'Sin permiso';
  end if;

  select * into v_tipo from tipo_entrada
   where id = p_tipo and evento_id = p_evento and organizador_id = v_org;
  if not found then
    raise exception 'TIPO_INEXISTENTE: ese producto no es de este evento.';
  end if;

  v_fase := fase_vigente(p_evento);
  if v_fase is null then
    raise exception 'SIN_FASE: este evento no tiene ninguna fase abierta hoy, así que no hay contra qué descontar el cupo. Abrí una fase y volvé.';
  end if;

  v_manillas := greatest(coalesce(v_tipo.manillas, 1), 1);
  v_pide := ceil(p_cantidad::numeric / v_manillas)::int;
  v_disp := disponibilidad_tipo(v_fase, p_tipo);
  if v_disp is not null and v_pide > v_disp then
    raise exception 'SIN_CUPO: de % % y estas cortesías necesitan %.',
      v_tipo.nombre,
      case when v_disp = 1 then 'queda 1 unidad' else format('quedan %s unidades', v_disp) end,
      case when v_pide = 1 then '1' else v_pide::text end;
  end if;

  for i in 1 .. p_cantidad loop
    insert into entradas (organizador_id, evento_id, orden_id, code, canal,
                          tipo_id, fase_id, cliente, precio)
    values (v_org, p_evento, null, nuevo_code(), 'cortesia',
            p_tipo, v_fase, v_para, 0)
    returning code into v_code;
    v_codes := v_codes || v_code;
  end loop;

  insert into admin_bitacora (organizador_id, evento_id, accion,
                              motivo, actor_id, detalle)
  values (v_org, p_evento, 'cortesias_emitidas', v_motivo, auth.uid(),
          jsonb_build_object(
            'para',             v_para,
            'cantidad',         p_cantidad,
            'tipo_id',          p_tipo,
            'tipo',             v_tipo.nombre,
            'fase_id',          v_fase,
            'unidades_de_cupo', v_pide,
            'codes',            to_jsonb(v_codes)));

  return jsonb_build_object('ok', true, 'evento', p_evento,
    'tipo_id', p_tipo, 'tipo', v_tipo.nombre, 'fase_id', v_fase,
    'cantidad', p_cantidad, 'para', v_para, 'codes', to_jsonb(v_codes),
    'quedan', disponibilidad_tipo(v_fase, p_tipo),
    'motivo', format('%s %s de %s a nombre de %s.',
      p_cantidad,
      case when p_cantidad = 1 then 'cortesía' else 'cortesías' end,
      v_tipo.nombre, v_para));
end $function$;
revoke execute on function emitir_cortesias(uuid, uuid, int, text, text) from anon, public;
grant execute on function emitir_cortesias(uuid, uuid, int, text, text) to authenticated;

comment on function emitir_cortesias(uuid, uuid, int, text, text) is
  'Emite N entradas de regalo: canal cortesia, precio 0, sin orden, a nombre de p_para (va en entradas.cliente). Consumen cupo: llevan la fase vigente y disponibilidad_tipo() las cuenta, asi que el organizador ve que le quedan menos para vender. Tope de 50 por llamada, dicho en el error. Exige puede_editar() y que el evento y el tipo sean del organizador de quien llama. Motivo y destinatario obligatorios. Devuelve los codigos emitidos y deja fila en admin_bitacora con quien las emitio.';

-- ============================================================
-- 9) resolver_revision — el caso más delicado del sistema
--
-- Una orden cae en `revision_manual` cuando la pasarela cobró un monto
-- distinto al esperado (0019). Del lado de la base: plata cobrada y cero
-- entradas emitidas. Del otro lado: una persona que pagó y no recibió
-- nada, mirando una pantalla que le dice "lo estamos revisando".
--
-- Dos decisiones y ninguna es automática, porque la información que hace
-- falta no está en la base: hay que mirar la pasarela con el `pago_ref`,
-- ver cuánto entró de verdad y decidir si eso alcanza. Por eso el motivo
-- acá es todavía más obligatorio que en los otros dos casos: es la
-- decisión que alguien va a tener que justificar.
--
-- Confirmar reusa emitir_orden(), no una segunda emisión (ver el bloque
-- 5). Anular reusa anular_orden(), con lo cual el registro y la liberación
-- de mesas salen gratis y salen iguales. Por eso anular NO escribe una
-- fila propia en admin_bitacora: la de anular_orden ya dice todo, y su
-- `detalle->>'estado_previo'` vale 'revision_manual', que es exactamente
-- el dato "esto venía de una revisión". Dos filas por una decisión serían
-- dos veces el mismo motivo y una cuenta inflada.
-- ============================================================
drop function if exists resolver_revision(uuid, text, text);
create function resolver_revision(p_orden uuid, p_decision text, p_motivo text) returns jsonb
  language plpgsql volatile security definer set search_path = public as $function$
declare
  v_org    uuid := mi_organizador();
  v_motivo text := btrim(coalesce(p_motivo, ''));
  v_dec    text := lower(btrim(coalesce(p_decision, '')));
  o ordenes; v_r jsonb; v_n int;
begin
  if not puede_editar() then raise exception 'Sin permiso'; end if;
  if v_motivo = '' then
    raise exception 'MOTIVO_REQUERIDO: sin motivo no se resuelve. Es la decisión que alguien va a tener que justificar.';
  end if;
  if v_dec not in ('confirmar', 'anular') then
    raise exception 'DECISION_INVALIDA: es confirmar o anular, llegó "%".', coalesce(p_decision, '');
  end if;

  select * into o from ordenes where id = p_orden for update;
  if not found then raise exception 'ORDEN_INEXISTENTE: %', p_orden; end if;
  if o.organizador_id is distinct from v_org then raise exception 'Sin permiso'; end if;

  if o.estado <> 'revision_manual' then
    raise exception 'NO_ESTA_EN_REVISION: esa orden está %, no en revisión manual.', o.estado;
  end if;

  if v_dec = 'anular' then
    -- El registro y las mesas los hace anular_orden(). Acá no se repite
    -- nada: repetirlo es cómo las dos versiones empiezan a diferir.
    return anular_orden(p_orden, v_motivo) || jsonb_build_object('decision', 'anular');
  end if;

  v_r := emitir_orden(p_orden, null, null, true);
  if not coalesce((v_r->>'ok')::boolean, false) then
    -- No debería pasar (el estado ya se chequeó arriba y el vencimiento no
    -- aplica), pero si pasa la transacción se cae entera: media confirmación
    -- —orden pagada sin entradas, o al revés— es peor que no haber tocado nada.
    raise exception 'NO_SE_PUDO_EMITIR: %', coalesce(v_r->>'motivo', 'sin motivo');
  end if;
  v_n := coalesce((v_r->>'entradas')::int, 0);

  insert into admin_bitacora (organizador_id, evento_id, accion, orden_id,
                              motivo, actor_id, detalle)
  values (v_org, o.evento_id, 'revision_confirmada', p_orden, v_motivo, auth.uid(),
          jsonb_build_object(
            'comprador',     o.comprador_nombre,
            'entradas',      v_n,
            'total',         o.total,
            'monto_cobrado', o.monto_cobrado,
            'diferencia',    case when o.monto_cobrado is null then null
                                  else (o.monto_cobrado - o.total) end,
            'pago_ref',      o.pago_ref));

  return jsonb_build_object('ok', true, 'decision', 'confirmar', 'orden', p_orden,
    'entradas', v_n,
    'motivo', format('Revisión confirmada: %s %s emitidas.',
      v_n, case when v_n = 1 then 'manilla' else 'manillas' end));
end $function$;
revoke execute on function resolver_revision(uuid, text, text) from anon, public;
grant execute on function resolver_revision(uuid, text, text) to authenticated;

comment on function resolver_revision(uuid, text, text) is
  'Cierra una orden en revision_manual. p_decision confirmar emite sus entradas reusando emitir_orden(); anular la cierra reusando anular_orden(). Exige puede_editar() y que la orden sea del organizador de quien llama. Motivo obligatorio en las dos. Solo trabaja sobre ordenes que esten en revision_manual: sobre cualquier otra se niega diciendo en que estado esta.';

-- ============================================================
-- 10) ordenes_en_revision — la lista que el tablero no ofrecía
--
-- `resumen_evento` cuenta estas órdenes en `alertas.revision_manual`
-- desde 0033 y no daba forma de llegar a ellas. Esta es la lista, con lo
-- que hace falta para decidir al lado: lo esperado, lo que la pasarela
-- dijo haber cobrado, la diferencia ya restada, y el `pago_ref` para ir a
-- buscarla en el panel de la pasarela.
--
-- `diferencia` viene calculada y no se deja para la pantalla: dos
-- pantallas restando lo mismo es cómo una de las dos termina restando al
-- revés, y acá el signo es la decisión (cobró de menos / cobró de más).
--
-- Con un evento que no es del organizador dice 'Sin permiso', igual que
-- con uno que no existe. No es lo que hace resumen_evento —que devuelve
-- {} para no ser un oráculo—: acá la respuesta es la MISMA en los dos
-- casos, así que no hay nada que preguntarle.
-- ============================================================
drop function if exists ordenes_en_revision(uuid);
create function ordenes_en_revision(p_evento uuid) returns jsonb
  language plpgsql stable security definer set search_path = public as $function$
declare v_org uuid := mi_organizador();
begin
  if not puede_editar() then raise exception 'Sin permiso'; end if;
  if not exists (select 1 from eventos e
                  where e.id = p_evento and e.organizador_id = v_org) then
    raise exception 'Sin permiso';
  end if;

  return (
    select coalesce(jsonb_agg(jsonb_build_object(
             'orden_id',      o.id,
             'comprador',     o.comprador_nombre,
             'telefono',      o.comprador_telefono,
             'email',         o.comprador_email,
             'subtotal',      o.subtotal::numeric(12,2),
             'fee',           o.fee::numeric(12,2),
             'total',         o.total::numeric(12,2),
             'monto_cobrado', o.monto_cobrado,
             'diferencia',    case when o.monto_cobrado is null then null
                                   else (o.monto_cobrado - o.total)::numeric(12,2) end,
             'pago_ref',      o.pago_ref,
             'fecha',         o.created_at,
             'rrpp_nombre',   pr.nombre,
             'productos',     coalesce(it.productos, '[]'::jsonb),
             'detalle',       coalesce(it.detalle, ''),
             'unidades',      coalesce(it.unidades, 0))
           order by o.created_at desc, o.id), '[]'::jsonb)
      from ordenes o
      -- El join a perfiles acota por organizador igual que en 0033: esta
      -- función corre como definer, así que la RLS de perfiles no la frena.
      left join perfiles pr on pr.id = o.rrpp_id and pr.organizador_id = v_org
      left join lateral (
        select sum(i.cantidad)::int as unidades,
               jsonb_agg(jsonb_build_object(
                 'nombre',    coalesce(t.nombre, 'Mesa ' || m.etiqueta),
                 'cantidad',  i.cantidad,
                 'precio_unitario', i.precio_unitario::numeric(12,2))
               order by t.orden nulls last, t.nombre nulls last) as productos,
               string_agg(coalesce(t.nombre, 'Mesa ' || m.etiqueta) ||
                          case when i.cantidad > 1 then ' ×' || i.cantidad else '' end,
                          ' + ' order by t.orden nulls last, t.nombre nulls last) as detalle
          from orden_items i
          left join tipo_entrada t on t.id = i.tipo_id
          left join mesas m on m.id = i.mesa_id
         where i.orden_id = o.id) it on true
     where o.evento_id = p_evento
       and o.organizador_id = v_org
       and o.estado = 'revision_manual');
end $function$;
revoke execute on function ordenes_en_revision(uuid) from anon, public;
grant execute on function ordenes_en_revision(uuid) to authenticated;

comment on function ordenes_en_revision(uuid) is
  'Las ordenes del evento que quedaron en revision_manual, con lo esperado, lo que la pasarela dijo haber cobrado, la diferencia ya restada y el pago_ref para ir a buscarla. Exige puede_editar(); con un evento que no es del organizador dice Sin permiso, lo mismo que con uno que no existe.';

-- ============================================================
-- 11) bitacora_admin — leer el registro
--
-- Un registro que nadie puede leer desde la aplicación es un registro que
-- solo existe para el que tiene el PAT, y esta migración existe justamente
-- para que las decisiones dejen de necesitar un PAT.
--
-- Tope explícito y la respuesta dice si cortó, igual que bitacora_puerta:
-- PostgREST corta en 1000 sin avisar y una respuesta truncada que no se
-- declara truncada es peor que un error, porque el que audita cuenta lo
-- que ve y le da bien.
-- ============================================================
drop function if exists bitacora_admin(uuid);
create function bitacora_admin(p_evento uuid) returns jsonb
  language plpgsql stable security definer set search_path = public as $function$
declare v_org   uuid := mi_organizador();
        v_tope  int  := 200;
        v_total int;
        v_filas jsonb;
begin
  if not puede_editar() then raise exception 'Sin permiso'; end if;
  if not exists (select 1 from eventos e
                  where e.id = p_evento and e.organizador_id = v_org) then
    raise exception 'Sin permiso';
  end if;

  -- El total se cuenta sin el tope: es lo único con lo que después se
  -- puede decir la verdad sobre si la lista quedó cortada.
  select count(*) into v_total from admin_bitacora b
   where b.organizador_id = v_org and b.evento_id = p_evento;

  select coalesce(jsonb_agg(to_jsonb(d) order by d.ocurrio_at desc), '[]'::jsonb)
    into v_filas
    from (
      select b.id, b.ocurrio_at, b.accion, b.motivo, b.detalle,
             b.orden_id, b.entrada_id,
             b.actor_id, pa.nombre as actor
        from admin_bitacora b
        left join perfiles pa on pa.id = b.actor_id
       where b.organizador_id = v_org and b.evento_id = p_evento
       order by b.ocurrio_at desc
       limit v_tope
    ) d;

  return jsonb_build_object('evento', p_evento, 'total', v_total, 'tope', v_tope,
                            'cortada', v_total > v_tope, 'filas', v_filas);
end $function$;
revoke execute on function bitacora_admin(uuid) from anon, public;
grant execute on function bitacora_admin(uuid) to authenticated;

comment on function bitacora_admin(uuid) is
  'Lee admin_bitacora de un evento, lo mas nuevo primero, con tope de 200 filas — la respuesta trae total, tope y cortada para no mentir por omision. Exige puede_editar() y acota por mi_organizador() adentro.';
