-- ============================================================
-- 0043 — borrar una fase, y solo si no vendió nada
--
-- Editar el nombre, el `desde` y el `hasta` de una fase ya se puede sin
-- función: la policy "fases escribir" de 0012 deja a admin/staff hacer
-- `update` sobre `evento_fase` de su organizador, y eso alcanza porque un
-- update no destruye nada que otra fila esté señalando. Borrar es otra
-- cosa y por eso existe este archivo.
--
-- ── qué pasa hoy si alguien borra una fase con ventas ──
-- Las tres referencias a `evento_fase` se comportan distinto y ninguna
-- protege del todo (`ordenes` no tiene `fase_id`: la fase de una compra
-- vive en sus items):
--
--   orden_items.fase_id  → on delete restrict   (frena, con un error feo)
--   entradas.fase_id     → on delete set null   (NO frena: vacía la columna)
--   fase_precio.fase_id  → on delete cascade    (se lleva los precios)
--
-- El agujero es `entradas`. Una cortesía se emite sin orden (0038: el
-- insert va con `orden_id = null`) pero sí con `fase_id`, porque de esa
-- fase salió el cupo que consumió. O sea: un evento que solo repartió
-- cortesías en una fase no tiene ningún item que la frene, el `delete`
-- pasa limpio, y las cortesías quedan con `fase_id` en null — sin nada
-- que diga contra qué cupo se descontaron.
-- `disponibilidad_tipo()` (0008) cuenta emitidas por `fase_id`, así que
-- después de eso el cupo de esa fase vuelve a estar entero y se puede
-- vender de nuevo lo que ya se regaló.
--
-- Y aun donde el FK sí frena, frena con `23503` y el texto crudo de
-- Postgres. El que lo lee no se entera de lo único que necesita saber:
-- que una fase con ventas no se borra, se CIERRA poniéndole `hasta`. La
-- diferencia importa — cerrar deja los precios y las entradas apuntando
-- a algo, borrar los dejaría apuntando a nada.
--
-- Por eso la cuenta va acá adentro y no en la pantalla: el `if` del
-- navegador es comodidad de interfaz, y este borrado no se puede quedar
-- en eso. Sin la función, cualquiera con sesión de admin lo hace con un
-- `delete` a PostgREST y las policies lo dejan pasar.
--
-- ── no anota en admin_bitacora, a propósito ──
-- Esa bitácora registra decisiones sobre plata que ya entró: anulaciones,
-- cortesías, cierres. Acá, por construcción, no hay nada de eso: si
-- hubiera un solo item de orden o una sola entrada colgando, no borra.
-- Lo que se borra es una fase que no vendió nunca, más sus precios, que
-- son un catálogo que nadie usó. Anotarlo sería ruido en el único lugar
-- donde el ruido se paga caro.
--
-- ── el corte de tenant va escrito adentro ──
-- `security definer` significa que las policies NO corren. p_fase llega
-- del navegador. Una fase de otro organizador contesta 'Sin permiso', el
-- mismo error que una que no existe: si contestara distinto sería un
-- oráculo de qué uuids hay en la base del vecino.
--
-- Idempotente: `drop function` con la firma completa antes del create
-- (invariante 4). Se puede correr dos veces.
-- ============================================================

drop function if exists borrar_fase(uuid);

create function borrar_fase(p_fase uuid) returns jsonb
  language plpgsql volatile security definer set search_path = public as $function$
declare v_org      uuid := mi_organizador();
        v_nombre   text;
        v_evento   uuid;
        v_entradas int;
        v_items    int;
        v_precios  int;
        v_borradas int;
begin
  if not coalesce(puede_editar(), false) then
    raise exception 'Sin permiso';
  end if;

  select f.nombre, f.evento_id into v_nombre, v_evento
    from evento_fase f
   where f.id = p_fase and f.organizador_id = v_org;
  if v_nombre is null then
    raise exception 'Sin permiso';
  end if;

  select count(*) into v_entradas from entradas    where fase_id = p_fase;
  select count(*) into v_items    from orden_items where fase_id = p_fase;

  if v_entradas > 0 or v_items > 0 then
    -- El mensaje dice qué hacer en su lugar, no solo que no se puede. Un
    -- error que solo prohíbe deja al organizador buscando el botón que no
    -- existe; éste lo manda al que sí existe.
    raise exception 'FASE_CON_VENTAS: «%» ya tiene % detrás, así que borrarla dejaría esas entradas sin fase y su cupo volvería a estar libre. Una fase que vendió no se borra: se cierra poniéndole una fecha de fin.',
      v_nombre,
      case when v_entradas > 0
           then format('%s %s emitida%s', v_entradas,
                       case when v_entradas = 1 then 'entrada' else 'entradas' end,
                       case when v_entradas = 1 then '' else 's' end)
           else format('%s %s', v_items,
                       case when v_items = 1 then 'compra' else 'compras' end)
      end;
  end if;

  select count(*) into v_precios from fase_precio where fase_id = p_fase;

  delete from evento_fase where id = p_fase and organizador_id = v_org;
  get diagnostics v_borradas = row_count;
  -- Cero filas sin error es el modo en que este proyecto ya se comió dos
  -- sorpresas: la escritura no falla, simplemente no pasa nada, y arriba
  -- se avisa "listo". Acá el vacío se trata como fallo.
  if v_borradas <> 1 then
    raise exception 'NO_SE_BORRO: la fase «%» sigue ahí. No la toqué.', v_nombre;
  end if;

  return jsonb_build_object(
    'ok',       true,
    'fase',     p_fase,
    'evento',   v_evento,
    'nombre',   v_nombre,
    'precios',  v_precios,
    'motivo',   format('Borré la fase «%s»%s.', v_nombre,
                  case when v_precios = 0 then ''
                       when v_precios = 1 then ' y el precio que colgaba de ella'
                       else format(' y los %s precios que colgaban de ella', v_precios) end));
end $function$;

revoke execute on function borrar_fase(uuid) from anon, public;
grant execute on function borrar_fase(uuid) to authenticated;

comment on function borrar_fase(uuid) is
  'Borra una fase y los precios que cuelgan de ella, solo si no tiene ningun item de orden ni ninguna entrada detras. Existe porque entradas.fase_id es on delete set null: una fase que solo repartio cortesias no la frena ningun FK y el delete crudo dejaria esas entradas sin fase, con su cupo otra vez libre. Una fase que vendio se cierra con hasta, no se borra, y el error lo dice. Acotada por mi_organizador() adentro y solo para puede_editar().';
