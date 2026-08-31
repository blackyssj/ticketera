-- ============================================================
-- 0040 — exportables: sacar de la base lo que la base ya sabe
--
-- Hasta hoy el panel muestra todo en pantalla y no deja bajar nada. El
-- organizador que le tiene que pasar la lista al contador, o cruzar la
-- recaudación con lo que le depositó la pasarela, copia de la pantalla a
-- mano. Eso no es una molestia: es la forma más barata de que un número
-- llegue mal a un cierre contable.
--
-- Esta migración no inventa un solo dato. Agrega una función que faltaba
-- (`entradas_evento`) y le pone paginado a las dos bitácoras que ya
-- existían, para que un archivo pueda salir COMPLETO.
--
-- ── por qué paginado y no un tope más grande ─────────────────
--
-- `bitacora_admin` (0038) corta en 200 y `bitacora_puerta` (0034) en 500.
-- Los dos topes son buenos para la pantalla y mentira para un archivo: un
-- CSV con 200 de 340 decisiones no se nota, y el que audita cuenta lo que
-- ve y le da bien. Subir el tope no arregla nada, solo mueve el número
-- donde va a fallar.
--
-- Tampoco alcanza con "traer la tabla por PostgREST": PostgREST corta en
-- 1000 filas sin avisar y sin decirlo en ningún lado de la respuesta.
--
-- Así que las tres funciones de acá contestan lo mismo: un pedazo, más
-- `total` contado SIN el tope y `desde`/`tope`/`cortada` para que el que
-- llama sepa si le falta y pueda volver a pedir. Un archivo completo es
-- entonces un bucle que termina cuando juntó `total` filas, y un archivo
-- incompleto es imposible en silencio.
--
-- El orden de cada consulta es determinístico —siempre con `id` al final
-- del `order by`— porque un paginado sobre un orden ambiguo repite filas
-- y se come otras: dos páginas que empatan en `ocurrio_at` pueden salir
-- en distinto orden en cada llamada, y ahí el archivo miente sin que
-- ningún tope haya cortado nada.
--
-- ── el cambio de firma ───────────────────────────────────────
--
-- `bitacora_admin(uuid)` y `bitacora_puerta(uuid, uuid)` cambian de firma
-- para recibir `p_desde` y `p_tope`. Va `drop function` con la firma
-- vieja completa antes del `create`: dos firmas vivas del mismo nombre
-- dejan a PostgREST sin candidata y la función muere sin avisar
-- (invariante 4). Los parámetros nuevos tienen default, así que quien
-- llame con un solo argumento sigue viendo lo mismo de antes.
--
-- Nadie las llamaba todavía desde la aplicación, así que este cambio no
-- rompe ninguna pantalla en vuelo.
--
-- Idempotente: `drop function if exists` con la firma completa delante de
-- cada función. Correrla dos veces seguidas no falla.
-- ============================================================

-- ============================================================
-- 1) entradas_evento — la lista que se imprime
--
-- Una fila por manilla emitida, anuladas incluidas y marcadas como tales.
-- Es la lista de papel de la puerta: cuando el 4G del boliche se cae, el
-- portero busca el código que le muestra el cliente y necesita ver ahí
-- mismo si esa manilla está anulada, a nombre de quién está y a qué hora
-- entró. Una lista que oculta las anuladas es peor que ninguna, porque
-- deja pasar justo la que se anuló.
--
-- Ordenada por `code`: es el dato con el que se busca en un papel. Por
-- nombre parece más humano, pero el que llega a la puerta muestra un QR
-- con un código, no un apellido.
--
-- El permiso es `puede_editar() or es_portero()`. El portero entra porque
-- ésta es su lista de contingencia. Un relacionador NO: la lista trae
-- todas las manillas del evento, también las que no vendió él.
-- ============================================================
drop function if exists entradas_evento(uuid);
drop function if exists entradas_evento(uuid, int);
drop function if exists entradas_evento(uuid, int, int);
create function entradas_evento(p_evento uuid, p_desde int default 0,
                                p_tope int default 1000) returns jsonb
  language plpgsql stable security definer set search_path = public as $function$
declare v_org   uuid := mi_organizador();
        v_desde int  := greatest(coalesce(p_desde, 0), 0);
        v_tope  int  := least(greatest(coalesce(p_tope, 1000), 1), 5000);
        v_total int;
        v_filas jsonb;
begin
  if not (puede_editar() or es_portero()) then raise exception 'Sin permiso'; end if;
  -- El mismo 'Sin permiso' para "no es tuyo" que para "no existe": si
  -- contestara distinto, esta función sería un oráculo de qué uuids hay
  -- en la base del vecino.
  if not exists (select 1 from eventos e
                  where e.id = p_evento and e.organizador_id = v_org) then
    raise exception 'Sin permiso';
  end if;

  select count(*) into v_total
    from entradas e where e.evento_id = p_evento and e.organizador_id = v_org;

  select coalesce(jsonb_agg(to_jsonb(d) order by d.code), '[]'::jsonb)
    into v_filas
    from (
      select e.id, e.code, e.cliente, e.canal, e.estado, e.precio,
             e.used_at, e.created_at,
             t.nombre   as tipo,
             t.categoria,
             m.etiqueta as mesa,
             pp.nombre  as portero,
             pr.nombre  as rrpp,
             e.orden_id,
             o.comprador_nombre    as comprador,
             o.comprador_telefono  as telefono
        from entradas e
        left join tipo_entrada t on t.id = e.tipo_id
        left join mesas   m  on m.id  = e.mesa_id  and m.organizador_id  = v_org
        -- Los joins a perfiles acotan por organizador igual que en 0033:
        -- esta función corre como definer, así que la RLS de perfiles no
        -- la frena y un id de otro tenant filtraría el nombre de esa
        -- persona.
        left join perfiles pp on pp.id = e.portero_id and pp.organizador_id = v_org
        left join perfiles pr on pr.id = e.rrpp_id    and pr.organizador_id = v_org
        left join ordenes  o  on o.id  = e.orden_id   and o.organizador_id  = v_org
       where e.evento_id = p_evento
         and e.organizador_id = v_org
       order by e.code
       limit v_tope offset v_desde
    ) d;

  return jsonb_build_object('evento', p_evento, 'total', v_total,
                            'desde', v_desde, 'tope', v_tope,
                            'devueltas', jsonb_array_length(v_filas),
                            'cortada', v_total > v_desde + jsonb_array_length(v_filas),
                            'filas', v_filas);
end $function$;
revoke execute on function entradas_evento(uuid, int, int) from anon, public;
grant execute on function entradas_evento(uuid, int, int) to authenticated;

comment on function entradas_evento(uuid, int, int) is
  'Una fila por manilla emitida del evento —anuladas incluidas y marcadas—: codigo, a nombre de quien, tipo, canal, estado, hora de ingreso, portero, mesa y la compra de la que salio. Ordenada por codigo, que es como se busca en un papel. Pagina con p_desde/p_tope y devuelve total, desde, tope, devueltas y cortada: un archivo completo es el bucle que junta total filas. Exige puede_editar() o es_portero() y acota por mi_organizador() adentro; con un evento ajeno dice Sin permiso, lo mismo que con uno que no existe.';

-- ============================================================
-- 2) bitacora_admin — ahora paginable
--
-- Mismo cuerpo que en 0038 más el paginado, y dos datos más por fila que
-- la pantalla necesitaba y no tenía: el nombre del comprador de la orden
-- tocada y el código de la manilla tocada. Sin ellos, la bitácora dice
-- "orden_anulada" y un uuid, y para saber de quién era esa compra hay que
-- ir a buscarla a otra pantalla — que es exactamente el momento en que
-- alguien deja de leer la bitácora.
--
-- El motivo ya venía. Es la columna que la base hace obligatoria y la
-- razón de que esta tabla exista, así que viaja siempre.
-- ============================================================
drop function if exists bitacora_admin(uuid);
drop function if exists bitacora_admin(uuid, int);
drop function if exists bitacora_admin(uuid, int, int);
create function bitacora_admin(p_evento uuid, p_desde int default 0,
                               p_tope int default 200) returns jsonb
  language plpgsql stable security definer set search_path = public as $function$
declare v_org   uuid := mi_organizador();
        v_desde int  := greatest(coalesce(p_desde, 0), 0);
        v_tope  int  := least(greatest(coalesce(p_tope, 200), 1), 5000);
        v_total int;
        v_filas jsonb;
begin
  if not puede_editar() then raise exception 'Sin permiso'; end if;
  if not exists (select 1 from eventos e
                  where e.id = p_evento and e.organizador_id = v_org) then
    raise exception 'Sin permiso';
  end if;

  -- El total se cuenta sin el tope: es lo único con lo que después se
  -- puede decir la verdad sobre si la lista quedó cortada.
  select count(*) into v_total from admin_bitacora b
   where b.organizador_id = v_org and b.evento_id = p_evento;

  select coalesce(jsonb_agg(to_jsonb(d) order by d.ocurrio_at desc, d.id desc), '[]'::jsonb)
    into v_filas
    from (
      select b.id, b.ocurrio_at, b.accion, b.motivo, b.detalle,
             b.orden_id, b.entrada_id,
             b.actor_id, pa.nombre as actor,
             o.comprador_nombre as comprador,
             e.code
        from admin_bitacora b
        left join perfiles pa on pa.id = b.actor_id
        left join ordenes  o  on o.id  = b.orden_id   and o.organizador_id  = v_org
        left join entradas e  on e.id  = b.entrada_id and e.organizador_id  = v_org
       where b.organizador_id = v_org and b.evento_id = p_evento
       order by b.ocurrio_at desc, b.id desc
       limit v_tope offset v_desde
    ) d;

  return jsonb_build_object('evento', p_evento, 'total', v_total,
                            'desde', v_desde, 'tope', v_tope,
                            'devueltas', jsonb_array_length(v_filas),
                            'cortada', v_total > v_desde + jsonb_array_length(v_filas),
                            'filas', v_filas);
end $function$;
revoke execute on function bitacora_admin(uuid, int, int) from anon, public;
grant execute on function bitacora_admin(uuid, int, int) to authenticated;

comment on function bitacora_admin(uuid, int, int) is
  'Lee admin_bitacora de un evento, lo mas nuevo primero, con el comprador de la orden y el codigo de la manilla que toco cada decision. Pagina con p_desde/p_tope y devuelve total, desde, tope, devueltas y cortada para no mentir por omision. Exige puede_editar() y acota por mi_organizador() adentro.';

-- ============================================================
-- 3) bitacora_puerta — ahora paginable
--
-- Mismo cuerpo que en 0034 más el paginado. Lo que NO cambia es quién ve
-- qué: sin `puede_editar()` sigue devolviendo solo lo que hizo quien
-- pregunta, y `alcance` sigue diciéndolo en la respuesta para que la
-- pantalla no tenga que adivinarlo ni —peor— rehacer esa decisión por su
-- cuenta. Un portero necesita revisar sus propios escaneos ("¿lo deshice
-- o no?") y no necesita auditar a los otros porteros.
-- ============================================================
drop function if exists bitacora_puerta(uuid, uuid);
drop function if exists bitacora_puerta(uuid, uuid, int);
drop function if exists bitacora_puerta(uuid, uuid, int, int);
create function bitacora_puerta(p_evento uuid, p_entrada uuid default null,
                                p_desde int default 0, p_tope int default 500) returns jsonb
  language plpgsql stable security definer set search_path = public as $function$
declare v_org   uuid    := mi_organizador();
        v_todo  boolean := coalesce(puede_editar(), false);
        v_desde int     := greatest(coalesce(p_desde, 0), 0);
        v_tope  int     := least(greatest(coalesce(p_tope, 500), 1), 5000);
        v_total int;
        v_filas jsonb;
begin
  if not (es_portero() or v_todo) then raise exception 'Sin permiso'; end if;

  select count(*) into v_total
    from puerta_bitacora b
   where b.organizador_id = v_org
     and b.evento_id = p_evento
     and (p_entrada is null or b.entrada_id = p_entrada)
     and (v_todo or b.actor_id = auth.uid());

  select coalesce(jsonb_agg(to_jsonb(d) order by d.ocurrio_at desc, d.id desc), '[]'::jsonb)
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
       order by b.ocurrio_at desc, b.id desc
       limit v_tope offset v_desde
    ) d;

  return jsonb_build_object(
    'evento',    p_evento,
    'entrada',   p_entrada,
    'alcance',   case when v_todo then 'evento' else 'mios' end,
    'total',     v_total,
    'desde',     v_desde,
    'tope',      v_tope,
    'devueltas', jsonb_array_length(v_filas),
    'cortada',   v_total > v_desde + jsonb_array_length(v_filas),
    'filas',     v_filas);
end $function$;
revoke execute on function bitacora_puerta(uuid, uuid, int, int) from anon, public;
grant execute on function bitacora_puerta(uuid, uuid, int, int) to authenticated;

comment on function bitacora_puerta(uuid, uuid, int, int) is
  'Lee la bitacora de la puerta. Con p_entrada, la historia de esa entrada; sin el, la del evento, lo mas nuevo primero. Pagina con p_desde/p_tope y devuelve total, desde, tope, devueltas y cortada para no mentir por omision. Acotada por mi_organizador() adentro. Sin puede_editar() devuelve solo lo que hizo quien pregunta, y lo dice en alcance.';
