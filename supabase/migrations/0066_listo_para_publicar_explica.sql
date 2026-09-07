-- ============================================================
-- 0066 — decir POR QUÉ no se puede publicar
--
-- 0060 y 0061 le enseñaron a `fase_vigente` a saltear la fase que ya no
-- tiene nada que vender. Efecto colateral: `listo_para_publicar` perdió
-- su mejor mensaje. Antes, un evento con la fase abierta pero sin
-- precios cargados decía "Ningún tipo de entrada tiene precio en la fase
-- abierta"; ahora esa fase ni siquiera es vigente, así que lo único que
-- contesta es "Ninguna fase está abierta en este momento".
--
-- Los dos son ciertos y uno solo sirve. Al que le falta cargar la grilla
-- de precios, "ninguna fase está abierta" lo manda a mirar fechas, que
-- están bien.
--
-- Lo agarró `supabase/tests/policies.sql`, que probaba justamente ese
-- mensaje. La tentación era aflojar el test; el test tenía razón.
--
-- Ahora, cuando no hay fase vigente, se pregunta por qué y se contesta
-- distinto según el caso: no hay ninguna fase en su ventana de fechas,
-- la hay pero sin precios, o la hay con precios y agotada. Son tres
-- problemas con tres arreglos distintos y ninguno se parece.
-- ============================================================

create or replace function listo_para_publicar(p_evento uuid) returns jsonb
  language plpgsql stable security definer set search_path = public as $function$
declare v_faltan text[] := '{}'; v_org uuid; v_fase uuid; v_abierta uuid;
begin
  select organizador_id into v_org from eventos where id = p_evento;
  if v_org is null or v_org <> mi_organizador() then
    raise exception 'No encontramos ese evento';
  end if;

  if not exists (select 1 from tipo_entrada
                  where evento_id = p_evento and activo) then
    v_faltan := v_faltan || 'Falta al menos un tipo de entrada'::text;
  end if;

  v_fase := fase_vigente(p_evento);

  if v_fase is null then
    -- ¿Hay alguna fase dentro de su ventana de fechas? Si no la hay, el
    -- problema son las fechas. Si la hay, `fase_vigente` la salteó por
    -- otra cosa, y esa otra cosa es lo que hay que decir.
    select f.id into v_abierta from evento_fase f
     where f.evento_id = p_evento and f.activo
       and (f.desde is null or f.desde <= now())
       and (f.hasta is null or f.hasta >  now())
     order by f.orden limit 1;

    if v_abierta is null then
      v_faltan := v_faltan || 'Ninguna fase está abierta en este momento'::text;
    elsif not exists (select 1 from fase_precio fp
                        join tipo_entrada t on t.id = fp.tipo_id
                       where fp.fase_id = v_abierta and t.activo and t.en_cartelera) then
      v_faltan := v_faltan || 'Ningún tipo de entrada tiene precio en la fase abierta'::text;
    else
      -- Hay precios y aun así se salteó: sólo queda el cupo agotado.
      v_faltan := v_faltan || 'La fase abierta ya no tiene cupo para vender'::text;
    end if;

  elsif not exists (select 1 from fase_precio fp
                      join tipo_entrada t on t.id = fp.tipo_id
                     where fp.fase_id = v_fase
                       and t.evento_id = p_evento
                       and t.activo) then
    v_faltan := v_faltan || 'Ningún tipo de entrada tiene precio en la fase abierta'::text;
  end if;

  return jsonb_build_object('ok', array_length(v_faltan, 1) is null,
                            'faltan', to_jsonb(v_faltan));
end $function$;
revoke execute on function listo_para_publicar(uuid) from anon, public;
grant execute on function listo_para_publicar(uuid) to authenticated;

comment on function listo_para_publicar(uuid) is
  'Que le falta a un evento para poder publicarse. Cuando no hay fase vigente distingue entre las tres causas —sin fase en su ventana, sin precios cargados, o cupo agotado— porque son tres arreglos distintos.';
