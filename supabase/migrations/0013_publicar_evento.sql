-- ============================================================
-- 0013 — publicar
--
-- Un evento publicado sin fase abierta hace que la landing responda
-- SIN_FASE, y el organizador ve una página rota sin entender por qué. El
-- chequeo vive en la base y no en el botón: el botón es comodidad, la
-- función es la garantía.
--
-- Despublicar NO pide nada. Es la salida de emergencia cuando el evento
-- salió con un precio mal.
--
-- Idempotente a propósito, como 0012: `create or replace function` en las
-- dos, así se puede correr esta migración dos veces seguidas sin fallar
-- por "function already exists" — es la única forma de verificarla contra
-- una base que ya la tiene aplicada.
--
-- `text[] || 'literal'` con el literal sin tipar resuelve ambiguo en
-- plpgsql: intenta leer el string como literal de array (`malformed array
-- literal`) en vez de agregarlo como elemento. Los `::text` en cada
-- `v_faltan := v_faltan || '...'::text` son necesarios, no cosméticos.
-- ============================================================

create or replace function listo_para_publicar(p_evento uuid) returns jsonb
  language plpgsql stable security definer set search_path = public as $function$
declare v_faltan text[] := '{}'; v_org uuid; v_fase uuid;
begin
  select organizador_id into v_org from eventos where id = p_evento;
  if v_org is null then raise exception 'EVENTO_INEXISTENTE: %', p_evento; end if;
  if v_org <> mi_organizador() then raise exception 'Sin acceso a este evento'; end if;

  if not exists (select 1 from tipo_entrada
                  where evento_id = p_evento and activo) then
    v_faltan := v_faltan || 'Falta al menos un tipo de entrada'::text;
  end if;

  v_fase := fase_vigente(p_evento);
  if v_fase is null then
    v_faltan := v_faltan || 'Ninguna fase está abierta en este momento'::text;
  elsif not exists (select 1 from fase_precio where fase_id = v_fase) then
    v_faltan := v_faltan || 'La fase abierta no tiene ningún precio cargado'::text;
  end if;

  return jsonb_build_object('ok', array_length(v_faltan, 1) is null,
                            'faltan', to_jsonb(v_faltan));
end $function$;
revoke execute on function listo_para_publicar(uuid) from anon, public;
grant execute on function listo_para_publicar(uuid) to authenticated;

create or replace function publicar_evento(p_evento uuid, p_publicar boolean default true)
returns jsonb
  language plpgsql volatile security definer set search_path = public as $function$
declare v_org uuid; v_r jsonb;
begin
  if not puede_editar() then raise exception 'Sin permiso'; end if;
  select organizador_id into v_org from eventos where id = p_evento;
  if v_org is null then raise exception 'EVENTO_INEXISTENTE: %', p_evento; end if;
  if v_org <> mi_organizador() then raise exception 'Sin acceso a este evento'; end if;

  if not p_publicar then
    update eventos set estado = 'borrador' where id = p_evento;
    return jsonb_build_object('ok', true, 'estado', 'borrador');
  end if;

  v_r := listo_para_publicar(p_evento);
  if (v_r->>'ok')::boolean is not true then
    raise exception 'NO_PUBLICABLE: %', array_to_string(
      array(select jsonb_array_elements_text(v_r->'faltan')), ' · ');
  end if;

  update eventos set estado = 'publicado' where id = p_evento;
  return jsonb_build_object('ok', true, 'estado', 'publicado');
end $function$;
revoke execute on function publicar_evento(uuid, boolean) from anon, public;
grant execute on function publicar_evento(uuid, boolean) to authenticated;
