-- ============================================================
-- 0089 — borrar un tipo de entrada que todavia no vendio
--
-- Las fases se pueden borrar desde 0043. Los tipos no, y el hueco se nota
-- el dia que alguien arma su primer evento: modelo "Welcome Ticket",
-- "First Offering", "Second Offering" como TIPOS cuando en realidad son
-- escalones de precio en el tiempo —o sea fases—, se da cuenta, y no
-- tiene como deshacerlo. Queda con filas de mas en la grilla para
-- siempre.
--
-- Paso de verdad la primera vez que un evento se armo sin ayuda.
--
-- ── por que no alcanza el delete crudo ──
--
-- `orden_items.tipo_id` es on delete RESTRICT: un tipo que se vendio ya lo
-- frena la base. Pero `entradas.tipo_id` es on delete SET NULL, y ahi no
-- frena nada: un tipo que solo repartio cortesias se borra sin chistar y
-- esas entradas quedan sin nombre. En la puerta, el portero escanea y lee
-- "(sin tipo)" en vez de "VIP", que es justo el dato que necesita para
-- saber si esa persona entra por donde esta parado.
--
-- Por eso la guardia se escribe aca y no se deja en los FK: se cuentan las
-- dos cosas, items y entradas, antes de tocar nada.
--
-- ── que se lleva ──
--
-- `fase_precio` es on delete cascade: se van los precios que ese tipo
-- tenia cargados en cada fase, que es lo correcto —son del cruce, no
-- existen sin el tipo— y el mensaje lo dice para que nadie lo descubra
-- mirando la grilla.
--
-- ── que se hace en su lugar cuando ya vendio ──
--
-- Se le deja el precio VACIO en todas las fases: deja de venderse y
-- desaparece de la pagina, y las entradas que ya emitio conservan su
-- nombre. El error lo dice, porque un mensaje que solo prohibe deja al
-- organizador buscando un boton que no existe.
-- ============================================================

create function borrar_tipo(p_tipo uuid) returns jsonb
  language plpgsql volatile security definer set search_path = public as $function$
declare v_org      uuid := mi_organizador();
        v_nombre   text;
        v_evento   uuid;
        v_entradas int;
        v_items    int;
        v_precios  int;
        v_borrados int;
begin
  if not coalesce(puede_editar(), false) then
    raise exception 'Sin permiso';
  end if;

  select t.nombre, t.evento_id into v_nombre, v_evento
    from tipo_entrada t
   where t.id = p_tipo and t.organizador_id = v_org;
  if v_nombre is null then
    raise exception 'Sin permiso';
  end if;

  select count(*) into v_entradas from entradas    where tipo_id = p_tipo;
  select count(*) into v_items    from orden_items where tipo_id = p_tipo;

  if v_entradas > 0 or v_items > 0 then
    raise exception 'TIPO_CON_VENTAS: «%» ya tiene % detras, asi que borrarlo dejaria esas entradas sin nombre y en la puerta se leerian en blanco. Un tipo que vendio no se borra: se deja de vender poniendole el precio vacio en todas las fases.',
      v_nombre,
      case when v_entradas > 0
           then format('%s %s emitida%s', v_entradas,
                       case when v_entradas = 1 then 'entrada' else 'entradas' end,
                       case when v_entradas = 1 then '' else 's' end)
           else format('%s %s', v_items,
                       case when v_items = 1 then 'compra' else 'compras' end)
      end;
  end if;

  select count(*) into v_precios from fase_precio where tipo_id = p_tipo;

  delete from tipo_entrada where id = p_tipo and organizador_id = v_org;
  get diagnostics v_borrados = row_count;
  -- Cero filas sin error: la escritura no falla, simplemente no pasa nada,
  -- y arriba se avisa "listo". Mismo tratamiento que en borrar_fase.
  if v_borrados <> 1 then
    raise exception 'NO_SE_BORRO: el tipo «%» sigue ahi. No lo toque.', v_nombre;
  end if;

  return jsonb_build_object(
    'ok',      true,
    'tipo',    p_tipo,
    'evento',  v_evento,
    'nombre',  v_nombre,
    'precios', v_precios,
    'motivo',  format('Borre «%s»%s.', v_nombre,
                 case when v_precios = 0 then ''
                      when v_precios = 1 then ' y el precio que tenia cargado'
                      else format(' y los %s precios que tenia cargados', v_precios) end));
end $function$;

revoke execute on function borrar_tipo(uuid) from anon, public;
grant execute on function borrar_tipo(uuid) to authenticated;

comment on function borrar_tipo(uuid) is
  'Borra un tipo de entrada y los precios que tenia en cada fase, solo si no tiene ningun item de orden ni ninguna entrada detras. Existe porque entradas.tipo_id es on delete set null: un tipo que solo repartio cortesias no lo frena ningun FK y el delete crudo dejaria esas entradas sin nombre, ilegibles en la puerta. Un tipo que vendio se saca de la venta dejando el precio vacio, no se borra, y el error lo dice. Acotado por mi_organizador() adentro y solo para puede_editar().';

-- ── control ─────────────────────────────────────────────────
select * from chequeo_funciones_sin_guardia();
