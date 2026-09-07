-- ============================================================
-- 0068b — la lista de compradores tampoco, cuando la bandera está apagada
-- Ver el porqué en 0068: la lista es el conteo de las ventas por otro
-- camino, y el corte tiene que estar en la base, no en la pantalla.
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

  -- 0068: al relacionador de un organizador que apagó `rrpp_ve_ventas` no
  -- se le devuelve nada. Su lista de compradores ES el conteo de sus
  -- ventas —una fila por compra— así que taparle el total de arriba y
  -- dejarle la lista abajo no le tapa nada.
  if not v_edita
     and not coalesce((select rrpp_ve_ventas from organizadores where id = v_org), true) then
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
