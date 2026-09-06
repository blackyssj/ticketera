-- ============================================================
-- 0056 — la puerta cuando se cae el internet
--
-- Hoy la puerta no decide nada sola: cada QR es una llamada a
-- `validar_entrada`. En un boliche con wifi eso anda. En una feria, en
-- una carpa, en un predio con mil teléfonos peleando la misma antena, se
-- cae — y cuando se cae la fila se detiene por completo, porque el
-- portero no tiene NADA: ni la lista, ni el nombre, ni forma de saber si
-- el código que está mirando existe.
--
-- Esto agrega las dos mitades que faltan para que el teléfono pueda
-- trabajar solo un rato:
--
--   padron_puerta()      se baja la lista entera ANTES, mientras hay señal
--   sincronizar_puerta() sube los ingresos que se hicieron sin ella
--
-- ── por qué el padrón vuelve como UN jsonb y no como filas ───
--
-- PostgREST corta en 1000 filas sin avisar. Una feria con 3.000 entradas
-- dejaría al portero con un padrón incompleto y sin ningún error: las
-- 2.000 personas que faltan llegarían a la puerta y su entrada figuraría
-- como inexistente. Un jsonb es una sola fila y no lo toca ese corte.
--
-- Las claves van en una letra (c, n, t, e, u). Con 3.000 entradas eso son
-- unos 90 KB de diferencia en algo que se guarda en el teléfono del
-- portero y se vuelve a bajar cada vez que hay señal.
--
-- ── por qué el ingreso sin señal NO es la verdad ─────────────
--
-- Dos teléfonos sin conexión no se ven entre ellos. Los dos pueden dejar
-- pasar el mismo código y los dos van a mostrar verde. Eso no se puede
-- evitar sin señal — se puede DETECTAR después, y esa es la diferencia
-- entre un problema que se descubre en la puerta y uno que aparece en la
-- planilla del día siguiente.
--
-- Por eso `sincronizar_puerta` no es un update en masa: es el mismo
-- update condicional de 0032, uno por código, y devuelve qué pasó con
-- cada uno. El que entró primero se queda con el ingreso; el segundo
-- vuelve como conflicto, con la hora del primero, para que el
-- organizador sepa exactamente cuántas manillas se duplicaron y cuáles.
--
-- ── por qué se ordena por la hora del escaneo ────────────────
--
-- Si dos teléfonos escanearon el mismo código, el que gana tiene que ser
-- el que lo escaneó ANTES, no el que tuvo señal primero. Ordenar por `at`
-- antes de aplicar es lo que hace que el resultado no dependa de cuál
-- teléfono se reconectó antes.
--
-- ── por qué la hora del teléfono no se cree ──────────────────
--
-- `used_at` sale del reloj del portero, que puede estar en otra zona
-- horaria o directamente mal. Una hora futura hace que la entrada figure
-- usada mañana; una de 2019 rompe cualquier informe por hora. Se acepta
-- solo si cae en una ventana razonable; si no, se usa la de ahora, que
-- es peor que la real pero nunca absurda.
--
-- Idempotente: `drop function if exists` con la firma completa delante de
-- cada create (invariante 4).
-- ============================================================

-- ── el padrón ───────────────────────────────────────────────
drop function if exists padron_puerta(uuid);
create function padron_puerta(p_evento uuid) returns jsonb
  language plpgsql stable security definer set search_path = public as $function$
declare
  v_org uuid := mi_organizador();
  v_nombre text; v_fecha date;
  v_total int; v_lista jsonb;
  -- Tope de cordura. Con más que esto el teléfono no es el lugar: el
  -- padrón se guarda entero en el navegador y bajarlo por una antena de
  -- feria tarda. Se avisa con `truncado` en vez de devolver una lista
  -- corta en silencio, que es la falla que este archivo viene a evitar.
  v_tope int := 20000;
begin
  if not (es_portero() or puede_editar()) then raise exception 'Sin permiso'; end if;

  select nombre, fecha into v_nombre, v_fecha
    from eventos where id = p_evento and organizador_id = v_org;
  if not found then
    raise exception 'EVENTO_INEXISTENTE: ese evento no es tuyo.';
  end if;

  select count(*) into v_total
    from entradas where organizador_id = v_org and evento_id = p_evento;

  select coalesce(jsonb_agg(f order by f->>'c'), '[]'::jsonb) into v_lista
    from (
      select jsonb_build_object(
               'c', e.code,
               'n', e.cliente,
               't', coalesce(t.nombre, case when e.mesa_id is not null then 'Mesa' end),
               'e', e.estado,
               'u', e.used_at) as f
        from entradas e
        left join tipo_entrada t on t.id = e.tipo_id
       where e.organizador_id = v_org and e.evento_id = p_evento
       order by e.code
       limit v_tope
    ) s;

  return jsonb_build_object(
    'ok', true,
    'evento', p_evento,
    'nombre', v_nombre,
    'fecha', v_fecha,
    'generado_at', now(),
    'total', v_total,
    'truncado', v_total > v_tope,
    'entradas', v_lista);
end $function$;
revoke execute on function padron_puerta(uuid) from anon, public;
grant execute on function padron_puerta(uuid) to authenticated;

comment on function padron_puerta(uuid) is
  'La lista entera de entradas de un evento para que la puerta pueda trabajar sin señal. Vuelve como un jsonb y no como filas porque PostgREST corta en 1000 sin avisar. Claves cortas: c=code, n=cliente, t=tipo, e=estado, u=used_at.';

-- ── subir lo que se hizo sin señal ──────────────────────────
drop function if exists sincronizar_puerta(uuid, jsonb);
create function sincronizar_puerta(p_evento uuid, p_ingresos jsonb) returns jsonb
  language plpgsql volatile security definer set search_path = public as $function$
declare
  v_org uuid := mi_organizador();
  r record; v_id uuid; v_estado text; v_at timestamptz; v_used timestamptz;
  v_res jsonb := '[]'::jsonb;
  v_ok int := 0; v_conf int := 0; v_otro int := 0;
begin
  if not (es_portero() or puede_editar()) then raise exception 'Sin permiso'; end if;

  if jsonb_typeof(coalesce(p_ingresos, 'null'::jsonb)) <> 'array' then
    raise exception 'INGRESOS_INVALIDOS: se espera una lista.';
  end if;
  -- Un tope por llamada para que un teléfono con la noche entera guardada
  -- no mande una transacción de veinte minutos. El escáner corta en tandas.
  if jsonb_array_length(p_ingresos) > 500 then
    raise exception 'DEMASIADOS: mandá de a 500 como mucho.';
  end if;

  if not exists (select 1 from eventos where id = p_evento and organizador_id = v_org) then
    raise exception 'EVENTO_INEXISTENTE: ese evento no es tuyo.';
  end if;

  for r in
    select upper(btrim(x->>'code')) as code,
           (x->>'at')::timestamptz  as at
      from jsonb_array_elements(p_ingresos) x
     where btrim(coalesce(x->>'code','')) <> ''
     -- El que escaneó primero gana. Sin este orden, gana el que se
     -- reconectó primero, que no tiene nada que ver con quién entró.
     order by (x->>'at')::timestamptz nulls last
  loop
    -- La hora del teléfono se acepta solo si es creíble.
    v_at := case
              when r.at is null then now()
              when r.at > now() + interval '5 minutes' then now()
              when r.at < now() - interval '2 days'    then now()
              else r.at
            end;

    update entradas
       set estado = 'usada', used_at = v_at, portero_id = auth.uid()
     where organizador_id = v_org
       and evento_id = p_evento
       and code = r.code
       and estado = 'valida'
    returning id into v_id;

    if v_id is not null then
      v_ok := v_ok + 1;
      v_res := v_res || jsonb_build_object('code', r.code, 'resultado', 'valida');
      continue;
    end if;

    select estado, used_at into v_estado, v_used
      from entradas
     where organizador_id = v_org and evento_id = p_evento and code = r.code;

    if v_estado is null then
      v_otro := v_otro + 1;
      v_res := v_res || jsonb_build_object('code', r.code, 'resultado', 'no_existe');
    elsif v_estado = 'usada' then
      -- Alguien más ya lo había consumido. Es el caso que importa: esa
      -- persona ya está adentro y entró dos veces con la misma manilla.
      v_conf := v_conf + 1;
      v_res := v_res || jsonb_build_object('code', r.code, 'resultado', 'usada',
                                           'used_at', v_used);
    else
      v_otro := v_otro + 1;
      v_res := v_res || jsonb_build_object('code', r.code, 'resultado', v_estado);
    end if;
  end loop;

  return jsonb_build_object(
    'ok', true, 'aplicados', v_ok, 'conflictos', v_conf, 'otros', v_otro,
    'detalle', v_res);
end $function$;
revoke execute on function sincronizar_puerta(uuid, jsonb) from anon, public;
grant execute on function sincronizar_puerta(uuid, jsonb) to authenticated;

comment on function sincronizar_puerta(uuid, jsonb) is
  'Sube los ingresos que la puerta hizo sin señal. Mismo update condicional de 0032, uno por codigo y ordenados por la hora del escaneo: el que entro primero se queda con el ingreso y el resto vuelve como conflicto con la hora del primero.';
