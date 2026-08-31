-- ============================================================
-- 0042 — quién escaneó qué en la puerta
--
-- `bitacora_puerta()` (0034, paginada en 0040) ya devuelve el detalle: una
-- fila por escaneo, lo más nuevo primero. Eso contesta "¿qué pasó con esta
-- manilla?" y no contesta la otra pregunta, la que aparece a la mañana
-- siguiente con cuatro personas escaneando: "¿cuánto hizo cada uno?".
-- Sacarla del detalle obliga a leer mil filas y contarlas a ojo, que es
-- exactamente lo que nadie hace — así que en la práctica ese número no
-- existía.
--
-- ── por qué `deshechas` es la columna que importa ──
-- Validar y rechazar son movimientos que no agrandan la lista de gente
-- adentro: validar consume una manilla que estaba vendida, rechazar no
-- toca nada. Deshacer sí: devuelve una manilla ya consumida al estado
-- `valida`, o sea la vuelve a hacer utilizable. Es el único movimiento de
-- la puerta con el que alguien de adentro puede hacer entrar gente de más
-- —se marca el ingreso, se deshace, la misma manilla vuelve a servir— y
-- por eso va contado aparte y al lado de los otros, no escondido en el
-- detalle. Tres deshechos en una noche son dedos gordos; cuarenta son
-- otra cosa, y la diferencia entre las dos lecturas es un número que
-- alguien tiene que poder mirar sin pedirle nada a nadie.
--
-- `deshechas_ajenas` afina esa misma pregunta y sale gratis, porque
-- `portero_previo` ya está guardado en la fila (0034): deshacer el propio
-- escaneo es corregirse; deshacer el que marcó el compañero es otra
-- historia y merece verse separada de la primera.
--
-- ── se cuenta desde `puerta_bitacora` y no desde `entradas` ──
-- `entradas.portero_id` guarda UN portero: el del último ingreso vigente.
-- Un deshacer lo pone en null y un reingreso lo pisa, así que contar por
-- ahí diría que el que deshizo no hizo nada — justo el dato que esta
-- función existe para mostrar. La bitácora es append-only y guarda cada
-- movimiento con su actor: es la única fuente que puede contestar esto.
--
-- ── quién la puede llamar: solo `puede_editar()` ──
-- Más cerrada que `bitacora_puerta()`, que le deja al portero ver lo suyo.
-- Acá no hay "lo suyo": un resumen de una sola fila no le contesta ninguna
-- pregunta al portero (sus propios escaneos ya los tiene en la bitácora,
-- con alcance 'mios'), y la versión completa es auditoría de los
-- compañeros, que no es su trabajo. `es_portero()` no aparece a propósito.
--
-- ── el corte de tenant va escrito adentro ──
-- `security definer` significa que las policies NO corren. p_evento llega
-- del navegador y puede ser el uuid de otro cliente. Devuelve `{}` —el
-- mismo vacío para "no existe" que para "no es tuyo"— así no sirve de
-- oráculo de qué uuids hay en la base del vecino, igual que
-- `conteo_puerta()` (0035) y `resumen_evento()` (0033).
--
-- Idempotente: `drop function` con la firma completa antes del create
-- (invariante 4 — dos firmas vivas dejan a PostgREST sin poder elegir y la
-- función queda muerta sin que nada avise). Se puede correr dos veces.
-- ============================================================

drop function if exists resumen_puerta(uuid);

create function resumen_puerta(p_evento uuid) returns jsonb
  language plpgsql stable security definer set search_path = public as $function$
declare v_org uuid := mi_organizador();
begin
  -- El `if` de la pantalla es comodidad de interfaz; el que manda es éste.
  -- Un rrpp llega hasta acá si escribe la llamada a mano, y acá rebota.
  if not coalesce(puede_editar(), false) then
    raise exception 'Sin permiso';
  end if;

  if not exists (select 1 from eventos
                  where id = p_evento and organizador_id = v_org) then
    return '{}'::jsonb;
  end if;

  return jsonb_build_object(
    'evento',      p_evento,
    'generado_at', now())
  || (
    -- Los totales del evento salen de la MISMA subconsulta que las filas,
    -- sumando el arreglo ya armado. Contarlos por separado con un segundo
    -- `count(*)` es como empiezan a discrepar: alguien cambia el filtro de
    -- una y la otra queda vieja, y el encabezado dice un número que no es
    -- la suma de lo que hay debajo justo la noche en que hay que
    -- discutirlo.
    select jsonb_build_object(
      'porteros', coalesce(jsonb_agg(to_jsonb(x) order by
                             x.ingresos desc, x.movimientos desc, x.portero),
                           '[]'::jsonb),
      'total', jsonb_build_object(
        'porteros',         count(*)::int,
        'movimientos',      coalesce(sum(x.movimientos), 0)::int,
        'ingresos',         coalesce(sum(x.ingresos), 0)::int,
        'validadas',        coalesce(sum(x.validadas), 0)::int,
        'reingresos',       coalesce(sum(x.reingresos), 0)::int,
        'rechazadas',       coalesce(sum(x.rechazadas), 0)::int,
        'deshechas',        coalesce(sum(x.deshechas), 0)::int,
        'deshechas_ajenas', coalesce(sum(x.deshechas_ajenas), 0)::int,
        'primero_at',       min(x.primero_at),
        'ultimo_at',        max(x.ultimo_at)))
      from (
        select b.actor_id,
               -- El nombre puede faltar si el perfil se borró: la fila de
               -- la bitácora sobrevive igual (es append-only y apunta a
               -- perfiles, no al revés). Un `left join` con un rótulo
               -- explícito es mejor que la fila desapareciendo del
               -- resumen, que es lo que haría un join a secas — y lo que
               -- desaparecería sería justamente la del que ya no está.
               coalesce(p.nombre, 'Perfil borrado') as portero,
               p.rol,
               coalesce(p.activo, false) as activo,
               count(*)::int as movimientos,
               -- "Cuántas manillas dejó pasar": validada es el primer
               -- ingreso y reingreso es el que vuelve a entrar después de
               -- un deshacer. Las dos son una persona cruzando la puerta
               -- por decisión de este portero, así que se suman — y se
               -- muestran también por separado, porque un evento con
               -- muchos reingresos ya es una anomalía en sí misma.
               count(*) filter (where b.accion = 'validada')::int   as validadas,
               count(*) filter (where b.accion = 'reingreso')::int  as reingresos,
               count(*) filter (where b.accion in ('validada','reingreso'))::int as ingresos,
               count(*) filter (where b.accion = 'rechazada')::int  as rechazadas,
               count(*) filter (where b.accion = 'deshecha')::int   as deshechas,
               count(*) filter (where b.accion = 'deshecha'
                                  and b.portero_previo is not null
                                  and b.portero_previo <> b.actor_id)::int as deshechas_ajenas,
               -- Primer y último escaneo: el turno real, que casi nunca es
               -- el turno anunciado. Sirve para leer todo lo demás — 200
               -- ingresos en seis horas y 200 en veinte minutos no son el
               -- mismo dato.
               min(b.ocurrio_at) as primero_at,
               max(b.ocurrio_at) as ultimo_at
          from puerta_bitacora b
          left join perfiles p on p.id = b.actor_id
         where b.organizador_id = v_org
           and b.evento_id = p_evento
         group by b.actor_id, p.nombre, p.rol, p.activo
      ) x);
end $function$;

revoke execute on function resumen_puerta(uuid) from anon, public;
grant execute on function resumen_puerta(uuid) to authenticated;

comment on function resumen_puerta(uuid) is
  'Que hizo cada portero en la puerta de un evento: validadas, reingresos, rechazadas en modo filtro, deshechas (y cuantas de esas eran de otro portero) y su primer y ultimo escaneo, mas los totales del evento. Sale de puerta_bitacora y no de entradas.portero_id, que guarda un solo portero y lo pierde al deshacer. Acotada por mi_organizador() adentro y solo para puede_editar(): un portero no audita a los otros porteros.';
