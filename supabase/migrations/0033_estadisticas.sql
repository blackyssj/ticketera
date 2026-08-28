-- ============================================================
-- 0033 — las estadísticas del evento y el plano de mesas
--
-- Tres funciones para dos pantallas: el tablero del administrador y el
-- plano que miran el administrador y el relacionador.
--
--   resumen_evento(ev)          — el tablero. Exige puede_editar().
--   compradores_evento(ev, mío) — quién compró qué. El rrpp ve lo suyo.
--   mesas_evento(ev)            — el plano. Todos lo llaman; el corte es
--                                 qué devuelve, no si se puede llamar.
--
-- ── por qué lo recaudado sale de ordenes.subtotal ───────────
--
-- Es la decisión de 0026 y acá se repite igual, porque en este evento se
-- puede medir: la suma de `entradas.precio` da 144.220 Bs donde entraron
-- 13.720. Un combo de 10 manillas a 5.500 emite diez entradas con
-- precio 5.500 cada una (0016), y las entradas que salen de una mesa
-- física se emiten con precio 0 (0027). Las dos formas de sumar entradas
-- mienten, una para arriba y otra para abajo. El subtotal de la orden es
-- la única cifra que no miente en ninguno de los dos casos. Es el
-- subtotal y no el total: el fee es de la plataforma, no del organizador,
-- y se informa aparte para que nadie lo confunda con recaudación.
--
-- ── por qué unidades y manillas son dos números distintos ───
--
-- Desde 0016, una unidad de un tipo con `manillas > 1` emite N filas en
-- `entradas`. Una fila de `entradas` ES una manilla: es lo que escanea la
-- puerta. Así que hay dos varas y ninguna reemplaza a la otra:
--
--   unidades  — lo que compró el cliente. Es la vara del CUPO, la misma
--               que usa disponibilidad_tipo() desde 0018 (sum de
--               orden_items.cantidad). Medir el cupo en manillas fue el
--               bug que dejó a Branca Lounge en 0 con una sola venta.
--   manillas  — la gente que entra. Es la vara de la PUERTA.
--
-- Un combo de 10 vendido una vez son 1 unidad y 10 manillas. Las dos
-- cifras van juntas en cada producto para que nadie tenga que dividir.
--
-- ── por qué el rrpp no ve los nombres de los demás ──────────
--
-- Los compradores de un relacionador son sus contactos: es lo que se
-- lleva si se va, y no es dato de la casa. compradores_evento() le
-- devuelve solo sus órdenes, y mesas_evento() le muestra TODAS las mesas
-- con su estado —necesita saber qué queda libre para vender— pero sin el
-- nombre de las que tiene otro. El corte se resuelve adentro de las
-- funciones, no con un parámetro: `p_solo_mios` sirve para que el admin
-- pida "solo lo mío", nunca para que un rrpp pida "lo de todos".
--
-- Idempotente a propósito, como 0012/0013/0017: drop + create con la
-- firma completa (invariante 4 vigila que no queden dos firmas vivas de
-- la misma función, que es como PostgREST se queda sin candidata y la
-- función muere sin avisar).
-- ============================================================

drop function if exists resumen_evento(uuid);
drop function if exists compradores_evento(uuid, boolean);
drop function if exists mesas_evento(uuid);

-- ============================================================
-- 1) resumen_evento — el tablero del administrador
--
-- No está para que el número de lo vendido quede lindo: está para
-- encontrar dónde se escapa la plata. Por eso `alertas` existe como
-- bloque propio y repite cifras que también viven en `estados`. Un total
-- que promedia una orden en revisión manual con una pagada esconde
-- exactamente lo que hay que mirar.
-- ============================================================
create or replace function resumen_evento(p_evento uuid) returns jsonb
  language plpgsql stable security definer set search_path = public as $function$
declare
  v_org  uuid := mi_organizador();
  v_ev   eventos;
  v_fase uuid;
begin
  if not puede_editar() then raise exception 'Sin permiso'; end if;

  -- El corte de tenant. p_evento llega del navegador y puede ser de otro
  -- cliente: sin este chequeo, `security definer` se saltea la RLS y el
  -- tablero de un organizador muestra la caja de otro. Devuelve vacío en
  -- vez de explotar, y con el mismo vacío para "no existe" que para "no
  -- es tuyo": así no se puede usar como oráculo de qué uuids existen.
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

    -- ── lo vendido ────────────────────────────────────────
    -- Las manillas se cuentan por el estado de la PROPIA entrada, no por
    -- el de su orden: una entrada 'valida' pasa el molinete aunque su
    -- orden esté hecha un lío, así que es el número que describe lo que
    -- va a pasar en la puerta. La discrepancia con lo cobrado no se tapa,
    -- se informa abajo en alertas.manillas_sin_orden_pagada.
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

    -- ── por producto ──────────────────────────────────────
    -- `quedan` sale de disponibilidad_tipo() (0018), no de una resta
    -- propia: es la misma cuenta que decide si una venta entra o no, y
    -- tener dos versiones es cómo el tablero termina diciendo que hay
    -- cupo mientras el checkout dice SIN_CUPO.
    --
    -- Se llama solo si el tipo tiene precio en la fase vigente, porque
    -- disponibilidad_tipo() devuelve 0 cuando no encuentra la fila de
    -- fase_precio, y ese 0 se lee como "agotado" cuando en realidad es
    -- "no se vende en esta fase". Sin fila, `quedan` va en null y
    -- `en_venta` en false, que es lo que pasa de verdad.
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
        -- Lo recaudado por producto se reparte con cantidad × precio_unitario,
        -- que es exactamente como crear_orden() arma el subtotal (0025): la
        -- suma de los productos de una orden da su subtotal, ni un centavo
        -- más. Sumar entradas.precio acá daría 10 veces el combo.
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

    -- ── por canal ─────────────────────────────────────────
    -- Los cuatro canales salen siempre, con cero si no vendieron nada:
    -- una fila que desaparece obliga a la pantalla a inventar los huecos,
    -- y "no hay ventas por puerta" es información, no ausencia de dato.
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

    -- ── por estado de orden ───────────────────────────────
    -- Los cinco estados, siempre, con su plata. `revision_manual` no se
    -- suma a nada ni se esconde: es una orden que la pasarela cobró por
    -- un monto distinto al esperado (0027) y alguien la tiene que mirar a
    -- mano. Es plata cobrada que todavía no es una entrada.
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

    -- ── la puerta ─────────────────────────────────────────
    -- A mitad de la noche la pregunta no es cuánto se vendió sino cuánta
    -- gente falta entrar. `faltan` es esa resta ya hecha.
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

    -- ── las mesas ─────────────────────────────────────────
    -- `ocupada` mira las DOS puntas de la relación: mesas.orden_id (que
    -- escribe crear_orden cuando alguien compra una chapa concreta, y
    -- libera vencer_ordenes) y ordenes.mesa_asignada_id (que escribe el
    -- administrador cuando reparte las mesas de los combos, 0015). Hoy
    -- ninguna función escribe las dos a la vez, así que mirar una sola
    -- deja mesas figurando libres que ya tienen dueño — y una mesa
    -- vendida dos veces se descubre en la puerta, con la gente adentro.
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

    -- ── por dónde se escapa la plata ──────────────────────
    -- Las mismas órdenes que ya están en `estados`, pero sacadas del
    -- montón a propósito. Son las tres cifras que hay que resolver antes
    -- de que abra la puerta, y un total las esconde.
    'alertas', jsonb_build_object(

      -- Cobrada por un monto distinto al esperado. Es plata que entró y
      -- no tiene entrada emitida del otro lado.
      'revision_manual', (
        select jsonb_build_object('ordenes', coalesce(count(*), 0)::int,
                                  'monto', coalesce(sum(o.total), 0)::numeric(12,2))
          from ordenes o
         where o.evento_id = p_evento and o.organizador_id = v_org
           and o.estado = 'revision_manual'),

      -- Retuvo cupo y nunca pagó. Lo que se pierde no es plata cobrada,
      -- es la venta que no se pudo hacer mientras el cupo estaba tomado.
      'vencidas', (
        select jsonb_build_object('ordenes', coalesce(count(*), 0)::int,
                                  'monto', coalesce(sum(o.total), 0)::numeric(12,2))
          from ordenes o
         where o.evento_id = p_evento and o.organizador_id = v_org
           and o.estado = 'vencida'),

      -- Ya se les pasó la hora pero el barrido (0011) todavía no corrió:
      -- siguen diciendo 'pendiente' y siguen reteniendo cupo en la
      -- lectura ingenua. Van aparte de `vencidas` porque son las mismas
      -- órdenes en un estado que todavía miente.
      'pendientes_vencidas', (
        select jsonb_build_object('ordenes', coalesce(count(*), 0)::int,
                                  'monto', coalesce(sum(o.total), 0)::numeric(12,2))
          from ordenes o
         where o.evento_id = p_evento and o.organizador_id = v_org
           and o.estado = 'pendiente' and o.expira_at <= now()),

      -- Alguien está pagando ahora mismo. No es una fuga, es contexto
      -- para no confundir el cupo retenido con cupo vendido.
      'pendientes_vivas', (
        select jsonb_build_object('ordenes', coalesce(count(*), 0)::int,
                                  'monto', coalesce(sum(o.total), 0)::numeric(12,2))
          from ordenes o
         where o.evento_id = p_evento and o.organizador_id = v_org
           and o.estado = 'pendiente' and o.expira_at > now()),

      -- El número que hay que llevar a cero antes de abrir: compras de
      -- mesa pagadas a las que nadie les dijo todavía qué mesa les tocó.
      -- Se excluyen las que ya tienen una mesa apuntándolas por
      -- mesas.orden_id: esas están asignadas, solo que por la otra punta.
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

      -- Manillas que pasan el molinete y cuya orden no está pagada.
      -- En una base sana esto es 0. Si no lo es, hay gente entrando con
      -- una entrada que nadie cobró, y no hay total que lo muestre.
      'manillas_sin_orden_pagada', (
        select coalesce(count(*), 0)::int
          from entradas e
          left join ordenes o on o.id = e.orden_id
         where e.evento_id = p_evento and e.organizador_id = v_org
           and e.estado <> 'anulada'
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
   nunca de sumar entradas.precio.';

-- ============================================================
-- 2) compradores_evento — quién compró qué
--
-- Una fila por orden pagada. El permiso tiene dos caminos y los dos se
-- resuelven acá adentro:
--
--   puede_editar()  → todas las del evento. p_solo_mios recorta a las
--                     suyas, para el admin que además vende.
--   cualquier otro  → SOLO las de rrpp_id = auth.uid(), ignorando
--                     p_solo_mios. Un parámetro no puede ampliar lo que
--                     ve un relacionador: sería exactamente el agujero
--                     que 0026 existe para cerrar.
-- ============================================================
create or replace function compradores_evento(
  p_evento uuid, p_solo_mios boolean default false
) returns jsonb
  language plpgsql stable security definer set search_path = public as $function$
declare
  v_org   uuid    := mi_organizador();
  v_yo    uuid    := auth.uid();
  v_edita boolean := puede_editar();
  v_solo  uuid;
begin
  if v_org is null or v_yo is null then return '[]'::jsonb; end if;
  if not exists (select 1 from eventos e
                  where e.id = p_evento and e.organizador_id = v_org) then
    return '[]'::jsonb;
  end if;

  -- Quién queda adentro. Para el que no puede editar, v_solo es SIEMPRE
  -- él mismo: p_solo_mios ni se mira.
  v_solo := case when not v_edita then v_yo
                 when p_solo_mios then v_yo
                 else null end;

  return (
    select coalesce(jsonb_agg(jsonb_build_object(
             'orden_id',         o.id,
             'comprador',        o.comprador_nombre,
             'telefono',         o.comprador_telefono,
             'email',            o.comprador_email,
             -- El detalle y su versión en una línea, para no obligar a la
             -- pantalla a rearmar el texto (y a que dos pantallas lo
             -- rearmen distinto).
             'productos',        coalesce(it.productos, '[]'::jsonb),
             'detalle',          coalesce(it.detalle, ''),
             'unidades',         coalesce(it.unidades, 0),
             -- Las manillas se cuentan de `entradas`, que es donde una
             -- fila ES una manilla. Multiplicar cantidad × manillas del
             -- tipo daría lo mismo hoy, pero se rompe el día que alguien
             -- edite tipo_entrada.manillas después de emitida la orden.
             'manillas',         coalesce(ma.manillas, 0),
             'manillas_usadas',  coalesce(ma.usadas, 0),
             'manillas_anuladas',coalesce(ma.anuladas, 0),
             'pagado',           o.subtotal::numeric(12,2),
             'fee',              o.fee::numeric(12,2),
             'total',            o.total::numeric(12,2),
             'fecha',            coalesce(o.pagada_at, o.created_at),
             'rrpp_id',          o.rrpp_id,
             'rrpp_nombre',      pr.nombre,
             'canal',            case when o.rrpp_id is not null then 'rrpp' else 'publico' end,
             'mesa_id',          m.id,
             'mesa_etiqueta',    m.etiqueta,
             'mesa_planta',      m.planta)
           order by coalesce(o.pagada_at, o.created_at) desc, o.id), '[]'::jsonb)
      from ordenes o
      -- El join a perfiles acota por organizador igual que en 0026: esta
      -- función corre como definer, así que la RLS de perfiles no la
      -- frena, y un rrpp_id de otro tenant filtraría el nombre de esa
      -- persona.
      left join perfiles pr on pr.id = o.rrpp_id and pr.organizador_id = v_org
      left join mesas m on m.id = o.mesa_asignada_id and m.organizador_id = v_org
      left join lateral (
        select sum(i.cantidad)::int as unidades,
               jsonb_agg(jsonb_build_object(
                 'nombre',    coalesce(t.nombre, 'Mesa ' || m2.etiqueta),
                 'categoria', coalesce(t.categoria, 'mesa'),
                 'cantidad',  i.cantidad,
                 'manillas',  i.cantidad * coalesce(t.manillas, m2.manillas, 1),
                 'precio_unitario', i.precio_unitario::numeric(12,2))
               order by t.orden nulls last, t.nombre nulls last) as productos,
               string_agg(coalesce(t.nombre, 'Mesa ' || m2.etiqueta) ||
                          case when i.cantidad > 1 then ' ×' || i.cantidad else '' end,
                          ' + ' order by t.orden nulls last, t.nombre nulls last) as detalle
          from orden_items i
          left join tipo_entrada t on t.id = i.tipo_id
          left join mesas m2 on m2.id = i.mesa_id
         where i.orden_id = o.id) it on true
      left join lateral (
        select count(*) filter (where e.estado <> 'anulada')::int as manillas,
               count(*) filter (where e.estado = 'usada')::int    as usadas,
               count(*) filter (where e.estado = 'anulada')::int  as anuladas
          from entradas e where e.orden_id = o.id) ma on true
     where o.evento_id = p_evento
       and o.organizador_id = v_org
       and o.estado = 'pagada'
       and (v_solo is null or o.rrpp_id = v_solo));
end $function$;
revoke execute on function compradores_evento(uuid, boolean) from anon, public;
grant execute on function compradores_evento(uuid, boolean) to authenticated;

comment on function compradores_evento(uuid, boolean) is
  'Una fila por orden pagada del evento: comprador, teléfono, productos,
   unidades, manillas, lo pagado, la fecha, el relacionador y la mesa
   asignada. Con puede_editar() devuelve todas; sin él, SOLO las de
   auth.uid() y p_solo_mios se ignora. p_solo_mios existe para que el
   admin que además vende pida "solo lo mío", nunca para ampliar lo que
   ve un relacionador. Con el evento de otro organizador devuelve [].';

-- ============================================================
-- 3) mesas_evento — el plano
--
-- Lo llama cualquier authenticated del organizador: el relacionador
-- necesita ver qué queda libre para vender. El corte no es si puede
-- llamar, es qué le vuelve — el nombre de quien tiene la mesa sale solo
-- si es puede_editar() o si esa orden la vendió él. Para el resto, una
-- mesa ocupada es "ocupada" y nada más: no tiene por qué leerse la lista
-- de invitados del evento entero.
--
-- `orden_id` se oculta con el mismo criterio que el nombre. Un uuid no es
-- un nombre, pero es un handle, y no hay razón para dárselo a quien no
-- puede ver a quién pertenece.
-- ============================================================
create or replace function mesas_evento(p_evento uuid) returns jsonb
  language plpgsql stable security definer set search_path = public as $function$
declare
  v_org   uuid    := mi_organizador();
  v_yo    uuid    := auth.uid();
  v_edita boolean := puede_editar();
begin
  if v_org is null then return '[]'::jsonb; end if;
  if not exists (select 1 from eventos e
                  where e.id = p_evento and e.organizador_id = v_org) then
    return '[]'::jsonb;
  end if;

  return (
    select coalesce(jsonb_agg(jsonb_build_object(
             'id',        m.id,
             'etiqueta',  m.etiqueta,
             'planta',    m.planta,
             'categoria', m.categoria,
             'x',         m.x,
             'y',         m.y,
             'w',         m.w,
             'manillas',  m.manillas,
             'precio',    m.precio::numeric(12,2),
             'estado',    m.estado,
             -- Ocupada por cualquiera de las dos puntas: la chapa que se
             -- compró directo (mesas.orden_id) o el combo al que el
             -- administrador le asignó esta mesa (ordenes.mesa_asignada_id).
             -- Mirar una sola deja mesas figurando libres que ya tienen
             -- dueño, y eso se descubre en la puerta.
             'ocupada',   (o.id is not null),
             'mia',       (o.rrpp_id is not null and o.rrpp_id = v_yo),
             -- Acá está el corte. El estado de la orden sí sale para
             -- todos: saber si una mesa está bloqueada (alguien pagando)
             -- o pagada es lo que necesita el que vende, y no es un dato
             -- de nadie.
             'orden_estado', o.estado,
             'orden_id',  case when v_edita or (o.rrpp_id is not null and o.rrpp_id = v_yo)
                               then o.id else null end,
             'comprador', case when v_edita or (o.rrpp_id is not null and o.rrpp_id = v_yo)
                               then o.comprador_nombre else null end,
             'rrpp_id',   case when v_edita or (o.rrpp_id is not null and o.rrpp_id = v_yo)
                               then o.rrpp_id else null end,
             'rrpp_nombre', case when v_edita or (o.rrpp_id is not null and o.rrpp_id = v_yo)
                                 then pr.nombre else null end)
           order by m.planta, m.etiqueta), '[]'::jsonb)
      from mesas m
      left join lateral (
        select o.id, o.estado, o.rrpp_id, o.comprador_nombre
          from ordenes o
         where o.organizador_id = v_org
           and (o.id = m.orden_id
                or (o.mesa_asignada_id = m.id and o.estado = 'pagada'))
         -- Si las dos puntas apuntan a órdenes distintas gana la chapa
         -- comprada directo, que es la que bloqueó el lugar primero.
         order by (o.id = m.orden_id) desc nulls last, o.created_at
         limit 1) o on true
      left join perfiles pr on pr.id = o.rrpp_id and pr.organizador_id = v_org
     where m.evento_id = p_evento and m.organizador_id = v_org);
end $function$;
revoke execute on function mesas_evento(uuid) from anon, public;
grant execute on function mesas_evento(uuid) to authenticated;

comment on function mesas_evento(uuid) is
  'El plano del evento: una fila por mesa con posición, precio, manillas y
   si está ocupada. Lo llama cualquier authenticated del organizador —el
   relacionador necesita ver qué queda libre—, pero el nombre de quien la
   tiene sale solo si es puede_editar() o si esa orden la vendió él. Con
   el evento de otro organizador devuelve [].';
