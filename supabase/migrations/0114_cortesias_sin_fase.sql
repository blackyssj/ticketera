-- ============================================================
-- 0114 — las cortesías no dependen de una fase ni del cupo
--
-- Hasta acá emitir_cortesias() pedía una fase abierta (SIN_FASE) y que
-- quedara cupo en ella (SIN_CUPO), y grababa la cortesía con esa fase.
-- Eso venía de cuando una cortesía restaba cupo. Desde 0065 ya no resta
-- —el cupo es el límite de VENTA, no el aforo—, pero los dos frenos
-- quedaron, y con ellos el absurdo: no se puede invitar al DJ porque la
-- preventa se agotó, ni regalar entradas antes de que abra la venta, ni
-- después de que cierre la última fase.
--
-- Una cortesía es una decisión del organizador, firmada con motivo en
-- admin_bitacora, que no tiene nada que ver con lo que se está vendiendo.
-- Así que:
--
--   · no pide fase: se graba con fase_id null. En «Por fase» cae en la
--     línea «sin fase», que es justo lo que es, y no infla las ventas de
--     una fase que no la vendió;
--   · no mira el cupo: se emite aunque el tipo esté agotado, inactivo o
--     sin precio en ninguna fase. Lo único que hace falta del tipo es su
--     nombre (lo que lee la puerta) y cuántas manillas da;
--   · todo lo demás queda igual: motivo y destinatario obligatorios, tope
--     de 50 por vez, el tenant adentro, la bitácora, y la mesa sin
--     entradas que no tiene nada que regalar (0108).
--
-- La firma no cambia (mismos cinco argumentos), así que es create or
-- replace sin riesgo de dos firmas vivas.
-- ============================================================

create or replace function emitir_cortesias(p_evento uuid, p_tipo uuid, p_cantidad integer,
                                            p_para text, p_motivo text)
returns jsonb
  language plpgsql security definer set search_path = public as $function$
declare
  v_org    uuid := mi_organizador();
  v_motivo text := btrim(coalesce(p_motivo, ''));
  v_para   text := btrim(coalesce(p_para, ''));
  v_tope   int  := 50;
  v_tipo   tipo_entrada;
  v_codes  text[] := '{}'; v_code text; i int;
begin
  if not puede_editar() then raise exception 'Sin permiso'; end if;
  if v_motivo = '' then
    raise exception 'MOTIVO_REQUERIDO: una cortesía sin motivo es una entrada que nadie firmó.';
  end if;
  -- A nombre de quién van es lo que la puerta lee en el cartel cuando
  -- escanea. Una cortesía a nombre de nadie es una manilla que cualquiera
  -- puede reclamar.
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
  -- que para "no es tuyo".
  if not exists (select 1 from eventos ev
                  where ev.id = p_evento and ev.organizador_id = v_org) then
    raise exception 'Sin permiso';
  end if;
  select * into v_tipo from tipo_entrada
   where id = p_tipo and evento_id = p_evento and organizador_id = v_org;
  if not found then
    raise exception 'TIPO_INEXISTENTE: ese producto no es de este evento.';
  end if;
  if v_tipo.categoria = 'mesa' and v_tipo.manillas = 0 then
    raise exception 'MESA_SIN_ENTRADAS: «%» no incluye entradas, así que no hay nada que regalar. Regalá entradas de otro tipo.', v_tipo.nombre;
  end if;

  -- 0114: sin fase_vigente() y sin disponibilidad_tipo(). fase_id null.
  for i in 1 .. p_cantidad loop
    insert into entradas (organizador_id, evento_id, orden_id, code, canal,
                          tipo_id, fase_id, cliente, precio)
    values (v_org, p_evento, null, nuevo_code(), 'cortesia',
            p_tipo, null, v_para, 0)
    returning code into v_code;
    v_codes := v_codes || v_code;
  end loop;

  insert into admin_bitacora (organizador_id, evento_id, accion,
                              motivo, actor_id, detalle)
  values (v_org, p_evento, 'cortesias_emitidas', v_motivo, auth.uid(),
          jsonb_build_object(
            'para',     v_para,
            'cantidad', p_cantidad,
            'tipo_id',  p_tipo,
            'tipo',     v_tipo.nombre,
            'codes',    to_jsonb(v_codes)));

  return jsonb_build_object('ok', true, 'evento', p_evento,
    'tipo_id', p_tipo, 'tipo', v_tipo.nombre, 'fase_id', null,
    'cantidad', p_cantidad, 'para', v_para, 'codes', to_jsonb(v_codes),
    'motivo', format('%s %s de %s a nombre de %s.',
      p_cantidad,
      case when p_cantidad = 1 then 'cortesía' else 'cortesías' end,
      v_tipo.nombre, v_para));
end $function$;

revoke execute on function emitir_cortesias(uuid, uuid, integer, text, text) from anon, public;
grant execute on function emitir_cortesias(uuid, uuid, integer, text, text) to authenticated;

comment on function emitir_cortesias(uuid, uuid, integer, text, text) is
  'Regala manillas de un tipo del evento a nombre de alguien, con motivo obligatorio (admin_bitacora). No pide fase abierta ni mira el cupo (0114): se graban con fase_id null y canal cortesia. Tope 50 por vez. Exige puede_editar(); el tenant se resuelve adentro.';

-- ── control ─────────────────────────────────────────────────
select * from chequeo_funciones_sin_guardia();
