-- ============================================================
-- 0067 — anular una cortesía ya no dice que devuelve cupo
--
-- Consecuencia directa de 0065. Mientras las cortesías restaban del
-- cupo, anular una lo devolvía y `anular_entrada` lo informaba con
-- `devuelve_cupo: true`. Ahora el cupo no las cuenta, así que no hay
-- lugar que devolver — y seguir diciéndolo dejaría a la pantalla
-- prometiendo una entrada más para vender que no aparece por ningún
-- lado.
--
-- El campo se queda en la respuesta y en la bitácora, en false: sacarlo
-- rompería a quien lo lea, y su valor sigue siendo la respuesta correcta
-- a la pregunta que hace. Hoy el único camino que devuelve cupo es
-- anular la ORDEN entera, que es donde vive la unidad vendida.
-- ============================================================

create or replace function anular_entrada(p_entrada uuid, p_motivo text,
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
            -- Desde 0065 el cupo no cuenta las cortesías, así que anular
            -- una no devuelve nada: nunca había ocupado un lugar. Y una
            -- manilla de una orden pagada tampoco — esa unidad se vendió.
            -- El único camino que devuelve cupo es anular la orden entera.
            'devuelve_cupo', false));

  return jsonb_build_object('ok', true, 'entrada', p_entrada, 'code', e.code,
    'ya_estaba', false, 'estado_previo', e.estado,
    'devuelve_cupo', false,
    'motivo', format('Manilla %s anulada.', e.code));
end $function$;
revoke execute on function anular_entrada(uuid, text, boolean) from anon, public;
grant execute on function anular_entrada(uuid, text, boolean) to authenticated;
