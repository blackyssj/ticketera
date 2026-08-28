-- ============================================================
-- 0034 — la bitácora de la puerta, para que deshacer deje huella
--
-- 0032 dejó la puerta andando y con un agujero adentro. `descheckin_entrada`
-- hace esto:
--
--     update entradas set estado = 'valida', used_at = null, portero_id = null
--
-- O sea: deshacer BORRA la huella. Después de un descheckin la fila no se
-- acuerda de que la entrada llegó a usarse, ni de a qué hora, ni de quién la
-- deshizo. Un portero hace entrar a diez personas con la misma manilla
-- —validar, deshacer, validar, deshacer— y a la mañana siguiente esa fila se
-- ve idéntica a una que entró una sola vez. Es el único lugar del sistema
-- donde alguien de adentro saca plata sin dejar rastro.
--
-- El permiso de deshacer NO se toca. En la puerta se escanea de más: la fila
-- empuja, el teléfono lee dos veces, alguien pasa el QR del amigo. Mandar al
-- portero a buscar un administrador cada vez es peor que el riesgo. Lo que
-- faltaba no era sacarle el permiso, era que quede escrito quién lo usó.
--
-- `marcar_filtro_entrada` tenía el mismo problema por el otro lado: rechaza y
-- no persiste nada, así que a la mañana no hay forma de saber que a alguien se
-- lo rechazó ni cuántas veces. Su propio comentario en 0032 lo decía —"no hay
-- dónde"—. Ahora hay dónde.
--
-- ── por qué `reingreso` es una acción propia ──
-- Podría alcanzar con `validada` y contar. No alcanza. Dos filas `validada`
-- sobre la misma entrada obligan al que audita a reconstruir la secuencia para
-- saber si hubo un deshacer en el medio o si es otra cosa; y reconstruir es
-- justo lo que no se hace a las tres de la mañana con doscientas entradas.
-- Con `reingreso` aparte, la pregunta que importa es un where:
--
--     select entrada_id, count(*) from puerta_bitacora
--      where evento_id = ... and accion = 'reingreso' group by 1
--
-- Eso es la lista de manillas que cruzaron la puerta más de una vez, sin
-- ventanas ni self-joins. Y como `reingreso` solo se escribe cuando ya había
-- una validación anterior para esa entrada, el par deshecha→reingreso ES la
-- forma del abuso: se ve de una.
--
-- ── qué NO se anota, y por qué ──
-- Un escaneo que rebota (la entrada ya estaba 'usada', o 'anulada') no deja
-- fila. No cambió nada, y la propia entrada ya dice con su `used_at` y su
-- `portero_id` quién dejó entrar a esa persona. Anotarlo sería la fila más
-- frecuente de la noche —escanear dos veces es lo normal— y ahogaría a las
-- cuatro que importan. Un code que no existe tampoco: no hay entrada a la cual
-- colgarle la fila, y una bitácora de tipeos mal no le sirve a nadie.
--
-- ── los índices ──
-- Se le van a hacer dos preguntas y hay un índice para cada una:
--   1) "todo lo que pasó con esta entrada"  → (entrada_id, ocurrio_at desc)
--   2) "todo lo que hizo este portero esta noche" → (evento_id, actor_id,
--      ocurrio_at desc); "esta noche" es el evento, que es como se cuenta acá.
-- No hay un tercero por (evento_id, ocurrio_at) para el resumen del admin a
-- propósito: el segundo ya filtra por evento y lo único que queda sin índice
-- es el orden, sobre las pocas miles de filas de una noche y con un limit
-- encima. Un índice más se paga en cada escaneo de la puerta, que es lo único
-- que en esta tabla tiene apuro.
--
-- ── append-only de verdad ──
-- `grant` de select e insert, nada más. Sin update, sin delete y sin truncate
-- (el invariante 6 lo exige, y Supabase los otorga solos en cada tabla nueva,
-- así que hay que revocarlos a mano). Una bitácora que se puede corregir no es
-- una bitácora.
--
-- La policy de insert existe igual, y no es una contradicción: obliga a que
-- `actor_id = auth.uid()`. En una tabla append-only eso quiere decir que lo
-- único que alguien puede escribir a mano es una fila firmada con su propio
-- nombre, al lado de todas las demás, y que después no puede sacar. No se
-- puede fraguar una fila a nombre de otro portero ni borrar la propia. El
-- camino real igual es la función: las tres de 0032 son `security definer`,
-- escriben la fila en la MISMA transacción que el update, y por eso no existe
-- el caso "el update salió y el log no" — si el escáner tuviera que hacer dos
-- llamadas, la segunda es la que no se hace.
--
-- ── `on delete cascade` sobre entradas, con los ojos abiertos ──
-- La bitácora se va con la entrada que describe. No es gratis y no se elige
-- por gusto: sin eso, borrar una entrada queda bloqueado para siempre, y el
-- que borra entradas hoy es `supabase/tests/carrera-puerta.py`, que siembra y
-- limpia su propio organizador de usar y tirar contra la base real. Con
-- restrict, ese test dejaría basura en producción en cada corrida. El riesgo
-- que se acepta es acotado: `authenticated` no tiene delete sobre `entradas`
-- (0012 se lo revocó), así que el único que puede disparar la cascada es el
-- dueño de la base, que es el mismo que podría dropear la tabla entera.
--
-- ── `clock_timestamp()` y no `now()` ──
-- `now()` es la hora de la transacción y no se mueve adentro de ella: tres
-- acciones en una misma transacción quedarían con la misma hora exacta y no
-- habría con qué ordenarlas. Una bitácora que no se puede ordenar no cuenta
-- ninguna historia. Acá interesa el instante, no el límite de la transacción.
--
-- Idempotente: `create table if not exists`, `create index if not exists`,
-- `drop policy if exists` delante de cada policy, y `create or replace` en las
-- tres funciones de 0032 (sus firmas no se tocan, así que no hace falta el
-- drop del invariante 4).
-- ============================================================

-- La tabla se llama `puerta_bitacora` y la función que la lee
-- `bitacora_puerta()`. Nombres distintos a propósito: con el mismo nombre
-- Postgres los deja convivir, pero un `bitacora_puerta(x)` de un argumento se
-- puede leer como selección de campo de un registro, y nadie quiere descubrir
-- eso en la puerta un sábado.
create table if not exists puerta_bitacora (
  id             uuid primary key default gen_random_uuid(),
  organizador_id uuid not null references organizadores on delete restrict,
  evento_id      uuid not null references eventos  on delete cascade,
  entrada_id     uuid not null references entradas on delete cascade,
  accion         text not null check (accion in ('validada','reingreso','deshecha','rechazada')),
  actor_id       uuid not null references perfiles(id),
  ocurrio_at     timestamptz not null default clock_timestamp(),
  estado_previo  text not null check (estado_previo in ('valida','usada','anulada')),
  -- Lo que `descheckin_entrada` borra de la fila. Va acá ANTES de borrarse: si
  -- no, la bitácora diría que alguien deshizo algo pero no qué había ahí, que
  -- es exactamente la mitad del dato que hace falta para reclamarle a alguien.
  used_at_previo timestamptz,
  portero_previo uuid references perfiles(id)
);

comment on table puerta_bitacora is
  'Una fila por cada cosa que le pasa a una entrada en el ingreso. Append-only: se agrega y se lee, no se edita ni se borra. La escriben las funciones de la puerta en la misma transaccion que el update.';
comment on column puerta_bitacora.accion is
  'validada (primer ingreso), reingreso (volvio a entrar despues de un deshacer), deshecha (se revirtio un ingreso), rechazada (modo filtro). Un escaneo que rebota no deja fila: no cambio nada.';
comment on column puerta_bitacora.actor_id is
  'Quien la hizo. Sale de auth.uid() adentro de la funcion, nunca de un parametro: si viniera por parametro, el navegador podria firmar con el nombre del companero.';
comment on column puerta_bitacora.used_at_previo is
  'La hora de ingreso que la entrada tenia antes de la accion. Solo la trae deshecha (y rechazada sobre una ya usada): es la huella que el descheckin borra de entradas.';
comment on column puerta_bitacora.portero_previo is
  'Quien habia marcado el ingreso que se deshizo. Deshacer lo pone en null en entradas; acá queda.';

create index if not exists puerta_bitacora_entrada_idx
  on puerta_bitacora (entrada_id, ocurrio_at desc);
create index if not exists puerta_bitacora_actor_idx
  on puerta_bitacora (evento_id, actor_id, ocurrio_at desc);

alter table puerta_bitacora enable row level security;

-- Leer: cada uno lo de su organizador; el portero, además, solo lo suyo. Un
-- portero no audita a los otros porteros — eso lo hace quien puede_editar().
-- Mismo molde que "ordenes leer" y "entradas leer" de 0012.
drop policy if exists "bitacora leer" on puerta_bitacora;
create policy "bitacora leer" on puerta_bitacora for select to authenticated
  using (organizador_id = mi_organizador()
         and (puede_editar() or actor_id = auth.uid()));

-- Escribir: solo hacia adelante y solo firmando con el propio uid. El exists()
-- ata la fila a una entrada del mismo organizador: sin él se podría anotar
-- sobre la entrada de otro tenant declarando el organizador propio.
drop policy if exists "bitacora agregar" on puerta_bitacora;
create policy "bitacora agregar" on puerta_bitacora for insert to authenticated
  with check (organizador_id = mi_organizador()
              and actor_id = auth.uid()
              and (es_portero() or puede_editar())
              and exists (select 1 from entradas e
                           where e.id = puerta_bitacora.entrada_id
                             and e.organizador_id = mi_organizador()));

-- El `revoke all` antes del grant no es ceremonia: Supabase otorga solo, por
-- default privileges, todo lo de una tabla nueva a anon y authenticated —
-- update, delete, truncate, trigger y references incluidos. Sin esta línea la
-- bitácora nace editable y borrable por cualquier usuario logueado.
revoke all on puerta_bitacora from anon, authenticated;
grant select, insert on puerta_bitacora to authenticated;

-- ── validar: la misma carrera de 0032, ahora con testigo ────
-- El update condicional no se mueve ni un caracter: sigue siendo ÉL la
-- pregunta, y es lo que `carrera-puerta.py` hostiga con dos sesiones reales.
-- El insert va después de que el update ya ganó, así que solo lo escribe el
-- escaneo que efectivamente consumió la entrada; el que perdió matchea cero
-- filas y no anota nada.
create or replace function validar_entrada(p_evento uuid, p_code text) returns jsonb
  language plpgsql volatile security definer set search_path = public as $function$
declare v_code text := upper(trim(coalesce(p_code, '')));
        v_id uuid; v_estado text;
begin
  if not (es_portero() or puede_editar()) then raise exception 'Sin permiso'; end if;

  -- El update ES la pregunta. No hay select antes: entre el select y el
  -- update cabe el otro portero.
  update entradas
     set estado = 'usada', used_at = now(), portero_id = auth.uid()
   where organizador_id = mi_organizador()
     and evento_id = p_evento
     and code = v_code
     and estado = 'valida'
  returning id into v_id;

  if v_id is not null then
    -- `validada` o `reingreso` según si esta entrada ya había cruzado la
    -- puerta alguna vez. La consulta cae justo en puerta_bitacora_entrada_idx.
    -- No se guarda used_at_previo: el update exigió estado = 'valida', y una
    -- entrada válida no tiene ingreso que guardar — es lo que la palabra
    -- significa. Esas dos columnas existen para deshacer, que es la única
    -- acción que borra algo.
    insert into puerta_bitacora (organizador_id, evento_id, entrada_id, accion,
                                 actor_id, estado_previo)
    select mi_organizador(), p_evento, v_id,
           case when exists (select 1 from puerta_bitacora b
                              where b.entrada_id = v_id
                                and b.accion in ('validada','reingreso'))
                then 'reingreso' else 'validada' end,
           auth.uid(), 'valida';
    return puerta_entrada(p_evento, v_code, 'valida');
  end if;

  -- No volvió fila. Recién ahora se averigua por qué, y cada motivo se
  -- responde distinto. Nada de esto se anota: no cambió nada.
  select estado into v_estado from entradas
   where organizador_id = mi_organizador() and evento_id = p_evento and code = v_code;

  if v_estado is null then
    return jsonb_build_object('resultado', 'no_existe', 'code', v_code);
  end if;
  -- 'usada' se devuelve con used_at, que es la hora del PRIMER ingreso:
  -- la fila no se tocó, así que sigue siendo la del que sí entró.
  return puerta_entrada(p_evento, v_code, v_estado);
end $function$;
revoke execute on function validar_entrada(uuid, text) from anon, public;
grant execute on function validar_entrada(uuid, text) to authenticated;

comment on function validar_entrada(uuid, text) is
  'Consume una entrada en la puerta y lo anota en puerta_bitacora (validada, o reingreso si ya habia cruzado antes). resultado: valida (la consumio ESTE escaneo), usada (con la hora del primer ingreso), anulada o no_existe. La condicion va adentro del update: dos porteros escaneando el mismo QR entran uno solo.';

-- ── modo filtro: rechaza sin consumir, pero deja constancia ──
create or replace function marcar_filtro_entrada(p_evento uuid, p_code text) returns jsonb
  language plpgsql volatile security definer set search_path = public as $function$
declare v_code text := upper(trim(coalesce(p_code, '')));
        v_id uuid; v_estado text; v_used timestamptz; v_portero uuid;
begin
  if not (es_portero() or puede_editar()) then raise exception 'Sin permiso'; end if;

  select id, estado, used_at, portero_id into v_id, v_estado, v_used, v_portero
    from entradas
   where organizador_id = mi_organizador() and evento_id = p_evento and code = v_code;

  if v_estado is null then
    -- No hay entrada a la cual colgarle la fila. Un code inventado no es un
    -- rechazo que alguien vaya a auditar: es un tipeo.
    return jsonb_build_object('resultado', 'no_existe', 'code', v_code, 'filtro', true);
  end if;

  -- Sigue sin tocar `entradas`, que es lo que promete el nombre: la persona no
  -- entra y la manilla le queda buena. Lo que cambia es que ahora el rechazo
  -- existe en algún lado — antes se lo llevaba el aire y a la mañana no había
  -- forma de saber a quién se rechazó ni cuántas veces.
  insert into puerta_bitacora (organizador_id, evento_id, entrada_id, accion,
                               actor_id, estado_previo, used_at_previo, portero_previo)
  values (mi_organizador(), p_evento, v_id, 'rechazada',
          auth.uid(), v_estado, v_used, v_portero);

  -- Devuelve el estado real para que el portero sepa qué está rechazando,
  -- aunque afuera se vea el mismo cartel que una falsa.
  return puerta_entrada(p_evento, v_code, v_estado) || jsonb_build_object('filtro', true);
end $function$;
revoke execute on function marcar_filtro_entrada(uuid, text) from anon, public;
grant execute on function marcar_filtro_entrada(uuid, text) to authenticated;

comment on function marcar_filtro_entrada(uuid, text) is
  'Rechaza en la puerta SIN consumir: la entrada queda como estaba y la persona ve el mismo cartel que una falsa. No toca entradas; si anota una fila rechazada en puerta_bitacora, porque un rechazo que no queda escrito no se puede revisar a la manana.';

-- ── deshacer: lo que se borra, se copia primero ─────────────
-- Acá cambia el mecanismo y conviene decir por qué, porque de lejos se parece
-- al bug que 0032 existe para no cometer.
--
-- El problema: hay que guardar el `used_at` y el `portero_id` que la fila tenía
-- ANTES de que el update se los borre. `returning` devuelve los valores nuevos
-- (null y null, o sea nada), y `returning old.*` recién existe en Postgres 18.
--
-- La solución NO es "select y después update" a secas —ese es el bug: dos
-- sesiones leen lo mismo y las dos siguen—. Es `select ... for update`, que es
-- otra cosa: toma el lock de la fila y, en read committed, cuando la otra
-- sesión commitea, vuelve a evaluar `estado = 'usada'` contra la versión nueva.
-- Si el otro ya deshizo, la fila dice 'valida', el select no la trae y acá no
-- se deshace nada. Exactamente el mismo desenlace que el update condicional,
-- con el bonus de que además devuelve lo que estaba. La `validar_entrada_ingenua`
-- de carrera-puerta.py se distingue de esto por una cosa y es justo esa: no
-- tiene `for update`.
create or replace function descheckin_entrada(p_evento uuid, p_code text) returns jsonb
  language plpgsql volatile security definer set search_path = public as $function$
declare v_code text := upper(trim(coalesce(p_code, '')));
        v_id uuid; v_estado text; v_used timestamptz; v_portero uuid;
begin
  if not (es_portero() or puede_editar()) then raise exception 'Sin permiso'; end if;

  -- Arbitra y captura en el mismo paso. Solo revierte lo que está 'usada'.
  select id, used_at, portero_id into v_id, v_used, v_portero
    from entradas
   where organizador_id = mi_organizador()
     and evento_id = p_evento
     and code = v_code
     and estado = 'usada'
     for update;

  if v_id is not null then
    update entradas
       set estado = 'valida', used_at = null, portero_id = null
     where id = v_id;

    -- El insert va con los valores capturados arriba, no con los de la fila,
    -- que a esta altura ya no los tiene. Esta es la fila que convierte
    -- "alguien deshizo algo" en "fulano deshizo el ingreso que mengano había
    -- marcado a tal hora".
    insert into puerta_bitacora (organizador_id, evento_id, entrada_id, accion,
                                 actor_id, estado_previo, used_at_previo, portero_previo)
    values (mi_organizador(), p_evento, v_id, 'deshecha',
            auth.uid(), 'usada', v_used, v_portero);

    return puerta_entrada(p_evento, v_code, 'valida');
  end if;

  select estado into v_estado from entradas
   where organizador_id = mi_organizador() and evento_id = p_evento and code = v_code;
  if v_estado is null then
    return jsonb_build_object('resultado', 'no_existe', 'code', v_code);
  end if;
  -- No estaba usada: se devuelve como está, sin inventar un ingreso que
  -- deshacer, y sin anotar nada. Una 'anulada' sale 'anulada' — revivirla no
  -- es deshacer un escaneo, es otra decisión y la toma otro.
  return puerta_entrada(p_evento, v_code, v_estado);
end $function$;
revoke execute on function descheckin_entrada(uuid, text) from anon, public;
grant execute on function descheckin_entrada(uuid, text) to authenticated;

comment on function descheckin_entrada(uuid, text) is
  'Deshace un ingreso: usada -> valida, y le borra used_at y portero_id. Antes de borrarlos los copia a puerta_bitacora con accion deshecha, que es la unica forma de que deshacer deje huella. Solo revierte usada: una anulada no se revive desde aca.';

-- ── leerla ──────────────────────────────────────────────────
-- Con p_entrada: la historia de esa entrada, que es la pregunta de la
-- discusión concreta ("esta manilla entró tres veces"). Sin él: la noche del
-- evento, lo más nuevo primero.
--
-- El tope es explícito y la respuesta dice si cortó. PostgREST corta en 1000
-- sin avisar y una noche pasa las 1000 sin esfuerzo: una respuesta truncada
-- que no se declara truncada es peor que un error, porque el que audita cuenta
-- lo que ve y le da bien. 500 deja margen cómodo por debajo de ese corte y
-- avisa mucho antes de llegar. Al que necesite la noche entera le queda la
-- tabla por PostgREST con su propia paginación: la policy de lectura ya deja
-- al admin ver todo lo de su organizador.
--
-- Sin puede_editar() devuelve solo lo que hizo quien pregunta. Un portero
-- necesita poder revisar sus propios escaneos —"¿lo deshice o no?"— y no
-- necesita ver los del compañero; el campo `alcance` lo dice en la respuesta
-- para que la pantalla no tenga que adivinarlo.
drop function if exists bitacora_puerta(uuid, uuid);
create function bitacora_puerta(p_evento uuid, p_entrada uuid default null) returns jsonb
  language plpgsql stable security definer set search_path = public as $function$
declare v_org   uuid    := mi_organizador();
        v_todo  boolean := coalesce(puede_editar(), false);
        v_tope  int     := 500;
        v_total int;
        v_filas jsonb;
begin
  if not (es_portero() or v_todo) then raise exception 'Sin permiso'; end if;

  -- El total se cuenta sin el tope: es lo único con lo que después se puede
  -- decir la verdad sobre si la lista quedó cortada.
  select count(*) into v_total
    from puerta_bitacora b
   where b.organizador_id = v_org
     and b.evento_id = p_evento
     and (p_entrada is null or b.entrada_id = p_entrada)
     and (v_todo or b.actor_id = auth.uid());

  select coalesce(jsonb_agg(to_jsonb(d) order by d.ocurrio_at desc), '[]'::jsonb)
    into v_filas
    from (
      select b.id, b.ocurrio_at, b.accion, b.estado_previo,
             b.entrada_id, e.code, e.cliente,
             b.actor_id, pa.nombre as actor,
             b.used_at_previo, b.portero_previo, pp.nombre as portero_previo_nombre
        from puerta_bitacora b
        join entradas e on e.id = b.entrada_id
        left join perfiles pa on pa.id = b.actor_id
        left join perfiles pp on pp.id = b.portero_previo
       where b.organizador_id = v_org
         and b.evento_id = p_evento
         and (p_entrada is null or b.entrada_id = p_entrada)
         and (v_todo or b.actor_id = auth.uid())
       order by b.ocurrio_at desc
       limit v_tope
    ) d;

  return jsonb_build_object(
    'evento',  p_evento,
    'entrada', p_entrada,
    'alcance', case when v_todo then 'evento' else 'mios' end,
    'total',   v_total,
    'tope',    v_tope,
    'cortada', v_total > v_tope,
    'filas',   v_filas);
end $function$;
revoke execute on function bitacora_puerta(uuid, uuid) from anon, public;
grant execute on function bitacora_puerta(uuid, uuid) to authenticated;

comment on function bitacora_puerta(uuid, uuid) is
  'Lee la bitacora de la puerta. Con p_entrada, la historia de esa entrada; sin el, la del evento, lo mas nuevo primero y con tope de 500 filas — la respuesta trae total, tope y cortada para no mentir por omision. Acotada por mi_organizador() adentro. Sin puede_editar() devuelve solo lo que hizo quien pregunta.';
