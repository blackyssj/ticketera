-- ============================================================
-- 0032 — validar, rechazar y deshacer una entrada en la puerta
--
-- La validación es UN update condicional, no un select seguido de un
-- update. Preguntar primero y actualizar después es una carrera: dos
-- porteros escanean el mismo QR, los dos leen 'valida', los dos escriben,
-- y entran dos personas con una manilla. La condición va adentro del
-- where:
--
--     update entradas set estado = 'usada' ... where ... and estado = 'valida'
--
-- Si vuelve fila, ESTE escaneo la consumió. Si no vuelve, recién ahí se
-- averigua por qué. En read committed el segundo update queda esperando
-- el lock de la fila y, cuando el primero commitea, vuelve a evaluar el
-- where contra la versión nueva: ya dice 'usada', matchea cero filas y el
-- segundo portero recibe 'usada'. Un solo ingreso, sin bloqueo explícito.
--
-- Y por eso `used_at` no se pisa nunca: el update pide estado = 'valida',
-- así que el segundo escaneo no llega a escribir. La hora que se devuelve
-- es la del PRIMER ingreso, que es lo único con lo que se le puede
-- contestar a alguien que jura que no entró.
--
-- ── el corte de tenant va escrito adentro ──
-- Las tres son `security definer` porque `entradas` no tiene `update`
-- para `authenticated` (0012 se lo revocó a propósito: la puerta escribe
-- por función, no por policy). Definer significa que las policies no
-- corren, así que `organizador_id = mi_organizador()` no lo pone nadie si
-- no se escribe acá. Sin eso, un portero que adivine evento y code quema
-- la entrada de otro organizador. Va en el where de las tres, y también
-- en la lectura de después: una entrada de otro tenant se responde
-- `no_existe`, que para quien pregunta es la verdad.
--
-- ── por qué `anulada` no es `no_existe` ──
-- Para quien está afuera son la misma cara. Para el portero no: una
-- existió y alguien la dio de baja — hay a quién llamar y qué reclamar —
-- y la otra nunca existió. Responder lo mismo a las dos convierte una
-- discusión de treinta segundos en una de diez minutos.
--
-- ── el modo filtro ──
-- Rechaza sin consumir. Sirve para no dejar entrar a alguien sin quemarle
-- el ticket: la entrada queda válida y la persona ve el mismo cartel que
-- una falsa. No escribe nada — el rechazo no se persiste porque todavía
-- no hay dónde, y agregarle una columna a `entradas` para esto es una
-- decisión de esquema que no entra en esta tarea. Lo que sí garantiza es
-- lo que promete el nombre por el lado importante: no toca el estado.
--
-- ── deshacer ──
-- En la puerta se escanea de más: la fila empuja, el teléfono lee dos
-- veces, alguien pasa el QR del amigo por error. Sin esto la única salida
-- es entrar a la base un sábado a las dos de la mañana. Solo revierte
-- 'usada' → 'valida'. Una 'anulada' no se revive desde acá: eso lo dio de
-- baja alguien a propósito y no es un error de escaneo.
--
-- Idempotente: `drop function if exists` con la firma completa antes de
-- cada `create` (invariante 4 — dos firmas vivas dejan a PostgREST sin
-- poder elegir y la función queda muerta sin que nada avise).
-- ============================================================

drop function if exists validar_entrada(uuid, text);
drop function if exists marcar_filtro_entrada(uuid, text);
drop function if exists descheckin_entrada(uuid, text);
drop function if exists puerta_entrada(uuid, text, text);

-- ── la ficha que se dibuja en la pantalla ───────────────────
-- Cuerpo compartido de las tres. Si cada una armara su propio jsonb, en
-- algún momento una devolvería un campo que las otras no y el escáner
-- tendría que preguntarse cuál llamó. Acota por mi_organizador() adentro,
-- igual que el resto.
create or replace function puerta_entrada(p_evento uuid, p_code text, p_resultado text)
returns jsonb
  language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
           'resultado', p_resultado,
           'code',      e.code,
           'cliente',   e.cliente,
           'tipo',      coalesce(t.nombre, case when e.mesa_id is not null then 'Mesa' end),
           'canal',     e.canal,
           'estado',    e.estado,
           'used_at',   e.used_at,
           'entrada',   e.id)
    from entradas e
    left join tipo_entrada t on t.id = e.tipo_id
   where e.organizador_id = mi_organizador()
     and e.evento_id = p_evento
     and e.code = upper(trim(p_code))
$$;
revoke execute on function puerta_entrada(uuid, text, text) from public, anon, authenticated;

comment on function puerta_entrada(uuid, text, text) is
  'La ficha de una entrada para la pantalla de la puerta, con el resultado que le pase quien llama. Cuerpo compartido de validar/filtro/descheckin para que las tres devuelvan la misma forma. No se expone: se llama solo desde ellas.';

-- ── validar: el update condicional ──────────────────────────
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
    return puerta_entrada(p_evento, v_code, 'valida');
  end if;

  -- No volvió fila. Recién ahora se averigua por qué, y cada motivo se
  -- responde distinto.
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
  'Consume una entrada en la puerta. resultado: valida (la consumio ESTE escaneo), usada (con la hora del primer ingreso), anulada o no_existe. La condicion va adentro del update: dos porteros escaneando el mismo QR entran uno solo.';

-- ── modo filtro: rechaza sin consumir ───────────────────────
create or replace function marcar_filtro_entrada(p_evento uuid, p_code text) returns jsonb
  language plpgsql volatile security definer set search_path = public as $function$
declare v_code text := upper(trim(coalesce(p_code, '')));
        v_estado text;
begin
  if not (es_portero() or puede_editar()) then raise exception 'Sin permiso'; end if;

  select estado into v_estado from entradas
   where organizador_id = mi_organizador() and evento_id = p_evento and code = v_code;

  if v_estado is null then
    return jsonb_build_object('resultado', 'no_existe', 'code', v_code, 'filtro', true);
  end if;
  -- Ni un update en toda la función: eso es exactamente lo que se promete.
  -- Devuelve el estado real para que el portero sepa qué está rechazando,
  -- aunque afuera se vea el mismo cartel que una falsa.
  return puerta_entrada(p_evento, v_code, v_estado) || jsonb_build_object('filtro', true);
end $function$;
revoke execute on function marcar_filtro_entrada(uuid, text) from anon, public;
grant execute on function marcar_filtro_entrada(uuid, text) to authenticated;

comment on function marcar_filtro_entrada(uuid, text) is
  'Rechaza en la puerta SIN consumir: la entrada queda como estaba y la persona ve el mismo cartel que una falsa. Sirve para no quemarle el ticket a alguien que no entra hoy. No escribe nada.';

-- ── deshacer ────────────────────────────────────────────────
create or replace function descheckin_entrada(p_evento uuid, p_code text) returns jsonb
  language plpgsql volatile security definer set search_path = public as $function$
declare v_code text := upper(trim(coalesce(p_code, '')));
        v_id uuid; v_estado text;
begin
  if not (es_portero() or puede_editar()) then raise exception 'Sin permiso'; end if;

  -- Mismo patrón condicional: solo revierte lo que está 'usada'. Si dos
  -- deshacen a la vez, el segundo no encuentra nada que deshacer.
  update entradas
     set estado = 'valida', used_at = null, portero_id = null
   where organizador_id = mi_organizador()
     and evento_id = p_evento
     and code = v_code
     and estado = 'usada'
  returning id into v_id;

  if v_id is not null then
    return puerta_entrada(p_evento, v_code, 'valida');
  end if;

  select estado into v_estado from entradas
   where organizador_id = mi_organizador() and evento_id = p_evento and code = v_code;
  if v_estado is null then
    return jsonb_build_object('resultado', 'no_existe', 'code', v_code);
  end if;
  -- No estaba usada: se devuelve como está, sin inventar un ingreso que
  -- deshacer. Una 'anulada' sale 'anulada' — revivirla no es deshacer un
  -- escaneo, es otra decisión y la toma otro.
  return puerta_entrada(p_evento, v_code, v_estado);
end $function$;
revoke execute on function descheckin_entrada(uuid, text) from anon, public;
grant execute on function descheckin_entrada(uuid, text) to authenticated;

comment on function descheckin_entrada(uuid, text) is
  'Deshace un ingreso: usada -> valida, y le borra used_at y portero_id. En la puerta se escanea de mas y sin esto la unica salida es tocar la base. Solo revierte usada: una anulada no se revive desde aca.';
