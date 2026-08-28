-- ============================================================
-- 0017 — tres huecos que dejó una revisión: la carrera del `orden` de
-- las fases, un `cerrado` que se reabre sin fricción, y una grilla de
-- precios que se guarda en dos requests HTTP separados.
--
-- Idempotente a propósito, como 0012/0013: se puede correr esta migración
-- dos veces seguidas sin fallar — es la única forma de verificarla contra
-- una base que ya la tiene aplicada.
-- ============================================================

-- ── 1) la carrera del `orden`: dos personas creando una fase a la vez
-- leen el mismo `select max(orden)` y escriben el mismo valor, en dos
-- requests separados sin transacción. `fase_vigente()` (0004) resolvía
-- con `order by f.orden limit 1` sin desempate, así que una fase empatada
-- podía vender al precio de la fase equivocada según cómo Postgres
-- decidiera devolver las filas ese día.
--
-- Dos arreglos, los dos hacen falta: el `unique` solo evita empates
-- FUTUROS, no arregla los que ya existan; el desempate en `fase_vigente()`
-- es la red por si el `unique` alguna vez se relaja o se bypassea.
-- ============================================================

-- Desempate de filas existentes ANTES de crear el índice único: si dos
-- fases del mismo evento ya comparten `orden`, el índice fallaría al
-- crearse. Se renumeran TODAS las fases de cada evento afectado (no solo
-- las empatadas) en el mismo orden relativo que ya tenían — así ninguna
-- fase sin problema cambia de posición — y adentro de un grupo empatado
-- gana la fase que `fase_vigente()` resuelve HOY, todavía con su
-- definición vieja sin desempate: es la llamada tal cual la hace la app
-- ahora mismo, así que renumerar no puede cambiar a qué precio se está
-- vendiendo en este momento. El resto de los empates (sin fase vigente
-- de por medio) se resuelve por `id`, determinista aunque arbitrario.
do $$
declare v_evento uuid;
begin
  for v_evento in
    select evento_id from evento_fase
    group by evento_id
   having count(*) <> count(distinct orden)
  loop
    update evento_fase f
       set orden = r.v_nuevo
      from (
        select id,
               row_number() over (
                 order by orden,
                          (id = fase_vigente(v_evento)) desc,
                          id
               ) - 1 as v_nuevo
          from evento_fase
         where evento_id = v_evento
      ) r
     where f.id = r.id
       and f.orden <> r.v_nuevo;
  end loop;
end $$;

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'evento_fase_orden_uk') then
    alter table evento_fase add constraint evento_fase_orden_uk unique (evento_id, orden);
  end if;
end $$;

-- Firma sin cambios respecto de 0004 (p_evento uuid, returns uuid):
-- `create or replace` alcanza, no hace falta `drop function`. El único
-- cambio es el `order by`: ahora nunca depende del plan de Postgres.
create or replace function fase_vigente(p_evento uuid) returns uuid
  language sql stable security definer set search_path = public as $$
  select f.id from evento_fase f
   where f.evento_id = p_evento and f.activo
     and (f.desde is null or f.desde <= now())
     and (f.hasta is null or f.hasta >  now())
   order by f.orden, f.id limit 1 $$;
revoke execute on function fase_vigente(uuid) from anon, public;
grant execute on function fase_vigente(uuid) to authenticated;

-- ============================================================
-- 2) un evento `cerrado` no se reabre con un clic distraído
--
-- `publicar_evento()` (0013) no miraba el estado previo: publicaba desde
-- `cerrado` como si viniera de `borrador`, y despublicar un `cerrado` lo
-- mandaba a `borrador` perdiendo esa marca. Cerrar un evento es una
-- decisión deliberada — reabrirlo tiene que serlo también, así que no
-- puede ser el mismo botón que publica/despublica un borrador cualquiera.
--
-- Firma sin cambios (p_evento uuid, p_publicar boolean default true):
-- `create or replace` alcanza.
-- ============================================================
create or replace function publicar_evento(p_evento uuid, p_publicar boolean default true)
returns jsonb
  language plpgsql volatile security definer set search_path = public as $function$
declare v_org uuid; v_estado text; v_r jsonb;
begin
  if not puede_editar() then raise exception 'Sin permiso'; end if;
  select organizador_id, estado into v_org, v_estado from eventos where id = p_evento;
  if v_org is null or v_org <> mi_organizador() then
    raise exception 'No encontramos ese evento';
  end if;

  if v_estado = 'cerrado' then
    raise exception 'Este evento está cerrado. No se puede volver a publicar ni pasar a borrador con este botón — si de verdad hay que reabrirlo, es una decisión aparte: cambiá el estado a mano en la base, a propósito.';
  end if;

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

-- ============================================================
-- 3) guardar la grilla de precios en una sola transacción
--
-- Hoy el navegador manda un `delete` por cada celda vaciada y después un
-- `upsert` con el resto — requests HTTP separados. Si el upsert falla, los
-- borrados ya se aplicaron: la base perdió precios y al organizador le
-- dice "no se pudo guardar". Y los errores del `delete` nunca se leen.
--
-- `guardar_precios()` hace las dos cosas adentro de la misma llamada, que
-- es la misma transacción: si algo falla, no queda nada a mitad de
-- camino. Reusa el patrón de mensaje de `publicar_evento()` — "No
-- encontramos ese evento" — para no confirmar por canal lateral qué uuids
-- existen.
-- ============================================================
create or replace function guardar_precios(p_evento uuid, p_filas jsonb) returns jsonb
  language plpgsql volatile security definer set search_path = public as $function$
declare v_org uuid; v_malas int; v_borrados int; v_guardados int;
begin
  if not puede_editar() then raise exception 'Sin permiso'; end if;
  select organizador_id into v_org from eventos where id = p_evento;
  if v_org is null or v_org <> mi_organizador() then
    raise exception 'No encontramos ese evento';
  end if;

  -- Toda fase y todo tipo de p_filas tienen que ser de ESTE evento. Si
  -- alguno no, no se escribe nada — es lo que impide que alguien le meta
  -- un precio al catálogo de otro evento. La verificación va ANTES de
  -- tocar la tabla, así una fila mala frena a las demás en vez de dejar
  -- el resto escrito.
  select count(*) into v_malas
    from jsonb_array_elements(coalesce(p_filas, '[]'::jsonb)) f
   where not exists (select 1 from evento_fase ef
                       where ef.id = (f->>'fase_id')::uuid and ef.evento_id = p_evento)
      or not exists (select 1 from tipo_entrada t
                       where t.id = (f->>'tipo_id')::uuid and t.evento_id = p_evento);
  if v_malas > 0 then
    raise exception 'No encontramos esa fase o ese tipo en este evento';
  end if;

  -- Borra, de las fases de ESTE evento, lo que no vino en p_filas. Un
  -- precio vacío significa "ese tipo no se vende en esa fase" y tiene que
  -- desaparecer, no quedar en 0.
  delete from fase_precio fp
   using evento_fase ef
   where fp.fase_id = ef.id and ef.evento_id = p_evento
     and not exists (
       select 1 from jsonb_array_elements(coalesce(p_filas, '[]'::jsonb)) f
        where (f->>'fase_id')::uuid = fp.fase_id and (f->>'tipo_id')::uuid = fp.tipo_id);
  get diagnostics v_borrados = row_count;

  insert into fase_precio (organizador_id, fase_id, tipo_id, precio, cupo)
  select v_org, (f->>'fase_id')::uuid, (f->>'tipo_id')::uuid,
         (f->>'precio')::numeric(12,2), nullif(f->>'cupo', '')::int
    from jsonb_array_elements(coalesce(p_filas, '[]'::jsonb)) f
  on conflict (fase_id, tipo_id) do update
    set precio = excluded.precio, cupo = excluded.cupo;
  get diagnostics v_guardados = row_count;

  return jsonb_build_object('ok', true, 'guardados', v_guardados, 'borrados', v_borrados);
end $function$;
revoke execute on function guardar_precios(uuid, jsonb) from anon, public;
grant execute on function guardar_precios(uuid, jsonb) to authenticated;

comment on function guardar_precios(uuid, jsonb) is
  'Reemplaza en una sola transacción los precios de un evento: inserta o
   actualiza las filas de p_filas y borra las que no vinieron. p_filas es
   un jsonb array de {"fase_id","tipo_id","precio","cupo"}, cupo puede ser
   null. No se le otorga a anon.';
