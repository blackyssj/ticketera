-- ============================================================
-- 0029 — quién se sienta dónde
--
-- Desde 0015 la mesa se vende como producto: el comprador paga "Combo
-- Sábados", no M7. La mesa física se la da alguien del equipo después, y
-- `ordenes.mesa_asignada_id` existe desde entonces para anotarlo. Nadie lo
-- escribía. Esto es lo que lo escribe.
--
-- Dos funciones simétricas, asignar_mesa() y liberar_mesa(), con el mismo
-- permiso y el mismo mecanismo dado vuelta.
--
-- ── por qué solo admin/staff, y el relacionador no ──
--
-- El relacionador vende el combo y ve el plano, pero no reparte. Reparte
-- una sola persona. No es una cuestión de confianza: dos personas
-- repartiendo el mismo salón es exactamente cómo dos grupos terminan
-- parados frente a la misma mesa un sábado a la noche, cada uno con su
-- captura de pantalla, y en la puerta eso no se discute con la base de
-- datos — se discute a los gritos con alguien del equipo que no tiene cómo
-- saber quién tenía razón. El candado de abajo evita que la base se
-- contradiga; que haya UN solo repartidor evita que se contradigan las
-- personas, que es la mitad que ningún `update` puede resolver.
--
-- Por eso la guardia es `puede_editar()` a secas, igual que
-- guardar_precios() y ventas_por_rrpp() (0026), y con el mismo raise
-- 'Sin permiso' para que la pantalla no tenga que aprender dos formas de
-- que le digan que no.
--
-- ── por qué la condición va DENTRO del update ──
--
-- Aun con un solo repartidor autorizado, esa persona tiene dos pestañas
-- abiertas, o son dos del equipo el mismo día. Preguntar "¿está libre?" y
-- después escribir es una carrera: las dos leen "libre", las dos escriben,
-- las dos le dicen a su cliente que la M7 es suya. El que pierde se entera
-- cuando llega al salón. Por eso la condición viaja adentro del `update`:
--
--     where id = p_mesa and (orden_id is null or orden_id = p_orden)
--
-- Postgres serializa las dos escrituras sobre la misma fila: la segunda
-- espera, re-evalúa el `where` con lo que dejó la primera, y toca 0 filas.
-- Es el mismo mecanismo con el que crear_orden() toma la mesa del plano
-- (0009) y con el que se toma el cupo por fase; no hay una segunda forma
-- de hacerlo bien.
--
-- El `where` también se lleva la coherencia (mismo evento, mismo
-- organizador): así no queda ni un chequeo afuera que alguien pueda
-- confundir con el candado. Cuando el update toca 0 filas recién ahí se
-- lee la mesa, y esa lectura no decide nada — solo elige qué frase
-- mostrar.
--
-- ── por qué se lockea la orden primero ──
--
-- La otra mitad de la carrera es dos mesas distintas para la MISMA orden a
-- la vez: las dos pasarían el `where` de mesas (cada una sobre su fila) y
-- una quedaría ocupada apuntando a una orden que ya no la mira. El
-- `for update` sobre la orden las serializa. El orden de los locks es
-- ordenes → mesas, igual que en emitir_orden(), para que las dos funciones
-- no se traben entre sí.
--
-- ── por qué el resto devuelve jsonb en vez de raise ──
--
-- El que lee el error está parado frente al cliente. Un `raise` le llega a
-- PostgREST como un 400 con texto de Postgres adentro, y la pantalla no
-- tiene con qué armar la frase: no sabe la etiqueta de la mesa ni el
-- nombre del que la tiene. Así que la frase se arma acá. Va en `motivo`,
-- lista para mostrar tal cual; el código de máquina va aparte en `codigo`
-- — al revés que emitir_orden(), que mete el código en `motivo` porque a
-- esa la llama una Edge Function y no una persona. El permiso es la
-- excepción y sí levanta: no es un resultado del reparto, es alguien que
-- no debería haber llegado hasta acá.
-- ============================================================

-- Segunda línea de defensa, y la única que no depende de que todos pasen
-- por estas funciones: `ordenes escribir` (0012) deja al staff hacer
-- `update ordenes` a mano, y a mano se puede poner la misma mesa en dos
-- órdenes. El índice lo vuelve imposible en la tabla, no en el código.
-- Es el mismo índice que orden_items ya tiene sobre mesa_id (0006).
create unique index if not exists ordenes_mesa_asignada_uq
  on ordenes (mesa_asignada_id) where mesa_asignada_id is not null;

-- ── asignar ─────────────────────────────────────────────────
create or replace function asignar_mesa(p_orden uuid, p_mesa uuid) returns jsonb
  language plpgsql volatile security definer set search_path = public as $function$
declare
  o ordenes; m mesas; v_previa uuid; v_estado_mesa text; v_n int;
  v_ocupa ordenes; v_quien text;
begin
  -- Reparte el equipo, no el que vendió. Va antes de leer nada para que un
  -- rrpp no pueda usar esta función ni como oráculo de qué órdenes existen.
  if not puede_editar() then raise exception 'Sin permiso'; end if;

  -- lock de la orden antes que nada: fija el orden de los locks y frena
  -- dos asignaciones simultáneas sobre la misma compra.
  select * into o from ordenes where id = p_orden for update;
  if not found then
    return jsonb_build_object('ok', false, 'codigo', 'ORDEN_INEXISTENTE',
                              'motivo', 'No encontré esa orden.');
  end if;

  -- puede_editar() solo dice que sos admin o staff de TU tenant, y esta
  -- función corre como definer, así que sin este corte el staff de un
  -- cliente acomodaría el salón de otro.
  if o.organizador_id is distinct from mi_organizador() then
    raise exception 'Sin permiso';
  end if;

  -- Una mesa en una orden anulada o vencida es una mesa muerta ocupada:
  -- nadie se va a sentar ahí y nadie la va a liberar.
  if o.estado in ('anulada', 'vencida') then
    return jsonb_build_object('ok', false, 'codigo', 'ORDEN_NO_ASIGNABLE',
      'motivo', 'La orden está ' || o.estado || ': no corresponde darle una mesa.');
  end if;

  v_previa := o.mesa_asignada_id;

  -- Si la orden ya está pagada la mesa queda 'pagada'; si todavía no,
  -- 'reservada', que es lo que 0005 definió para "la comprometió el
  -- staff". Poner 'pagada' sobre una orden pendiente le mentiría a la
  -- pantalla del salón.
  v_estado_mesa := case when o.estado = 'pagada' then 'pagada' else 'reservada' end;

  -- ── el candado ──
  -- Coherencia y exclusión, las dos adentro del where. 0 filas puede ser
  -- cualquiera de las tres cosas; abajo se averigua cuál para la frase.
  update mesas set orden_id = p_orden, estado = v_estado_mesa, updated_at = now()
   where id = p_mesa
     and evento_id = o.evento_id
     and organizador_id = o.organizador_id
     and (orden_id is null or orden_id = p_orden)
  returning * into m;
  get diagnostics v_n = row_count;

  if v_n = 0 then
    select * into m from mesas where id = p_mesa;
    -- Una mesa de otro organizador se contesta igual que una que no
    -- existe: confirmar la etiqueta ya sería contarle a un tenant qué
    -- tiene el otro.
    if not found or m.organizador_id is distinct from o.organizador_id then
      return jsonb_build_object('ok', false, 'codigo', 'MESA_INEXISTENTE',
                                'motivo', 'No encontré esa mesa.');
    end if;
    if m.evento_id is distinct from o.evento_id then
      return jsonb_build_object('ok', false, 'codigo', 'MESA_DE_OTRO_EVENTO',
        'motivo', 'La mesa ' || m.etiqueta || ' es de otro evento.');
    end if;

    -- Está tomada. El mensaje dice cuál y de quién: el que lo lee tiene al
    -- cliente enfrente y necesita saber a quién ir a preguntarle.
    select * into v_ocupa from ordenes where id = m.orden_id;
    -- coalesce en las dos puntas: sin nombre de comprador, o sin orden que
    -- la ocupe, un `||` con null dejaría el motivo entero en null y la
    -- pantalla mostraría un cartel vacío justo cuando más se lo necesita.
    v_quien := coalesce(nullif(trim(v_ocupa.comprador_nombre), ''), 'otro comprador');
    return jsonb_build_object('ok', false, 'codigo', 'MESA_TOMADA',
      'mesa', m.id, 'etiqueta', m.etiqueta, 'orden_ocupante', m.orden_id,
      'motivo', 'La mesa ' || m.etiqueta || ' ya está asignada a ' || v_quien ||
                ' (orden ' || coalesce(left(m.orden_id::text, 8), 'sin identificar') ||
                '). Liberala antes de reasignarla.');
  end if;

  -- ── liberar la mesa anterior ──
  -- Sin esto, cada cambio de opinión deja una mesa ocupada para siempre por
  -- una orden que ya está sentada en otra. También va condicionado: se
  -- suelta solo si sigue siendo de esta orden.
  if v_previa is not null and v_previa <> p_mesa then
    update mesas set orden_id = null, estado = 'disponible', updated_at = now()
     where id = v_previa and orden_id = p_orden;
  end if;

  update ordenes set mesa_asignada_id = p_mesa where id = p_orden;

  return jsonb_build_object('ok', true, 'orden', p_orden, 'mesa', m.id,
                            'etiqueta', m.etiqueta, 'estado', m.estado,
                            'manillas', m.manillas,
                            'mesa_liberada', case when v_previa <> p_mesa then v_previa end,
                            'repetida', v_previa is not distinct from p_mesa,
                            'motivo', 'Mesa ' || m.etiqueta || ' asignada.');
end $function$;
revoke execute on function asignar_mesa(uuid, uuid) from anon, public;
grant execute on function asignar_mesa(uuid, uuid) to authenticated;

comment on function asignar_mesa(uuid, uuid) is
  'Le da a una orden su mesa física. La toma con update condicional —la condición adentro del where, nunca en un if previo— así dos personas asignando a la vez no se pisan. Libera la mesa que la orden tuviera antes. Exige puede_editar(): el relacionador vende el combo, pero el salón lo reparte el equipo. Devuelve jsonb; en `motivo` va la frase para mostrar tal cual y en `codigo` el motivo de máquina.';

-- ── liberar ─────────────────────────────────────────────────
-- La misma historia al revés: mismo permiso, mismo lock primero sobre la
-- orden, y el mismo update condicional — solo suelta la mesa si sigue
-- atada a esta orden, así no le arrebata la mesa a quien la haya tomado
-- entre medio.
create or replace function liberar_mesa(p_orden uuid) returns jsonb
  language plpgsql volatile security definer set search_path = public as $function$
declare o ordenes; m mesas; v_n int;
begin
  if not puede_editar() then raise exception 'Sin permiso'; end if;

  select * into o from ordenes where id = p_orden for update;
  if not found then
    return jsonb_build_object('ok', false, 'codigo', 'ORDEN_INEXISTENTE',
                              'motivo', 'No encontré esa orden.');
  end if;

  if o.organizador_id is distinct from mi_organizador() then
    raise exception 'Sin permiso';
  end if;

  if o.mesa_asignada_id is null then
    return jsonb_build_object('ok', true, 'orden', p_orden, 'libero', false,
                              'motivo', 'Esa orden no tenía mesa asignada.');
  end if;

  update mesas set orden_id = null, estado = 'disponible', updated_at = now()
   where id = o.mesa_asignada_id and orden_id = p_orden
  returning * into m;
  get diagnostics v_n = row_count;

  -- La orden suelta su lado igual aunque la mesa ya no fuera suya: dejarle
  -- el puntero sería seguir mostrando en pantalla una mesa de otro.
  update ordenes set mesa_asignada_id = null where id = p_orden;

  return jsonb_build_object('ok', true, 'orden', p_orden, 'libero', v_n > 0,
    'mesa', o.mesa_asignada_id, 'etiqueta', m.etiqueta,
    'motivo', case when v_n > 0
                then 'Mesa ' || m.etiqueta || ' liberada.'
                else 'La orden ya no tenía esa mesa; se limpió igual.' end);
end $function$;
revoke execute on function liberar_mesa(uuid) from anon, public;
grant execute on function liberar_mesa(uuid) to authenticated;

comment on function liberar_mesa(uuid) is
  'Suelta la mesa de una orden y la deja disponible. Mismo permiso que asignar_mesa() —puede_editar(), el reparto es del equipo— y el mismo update condicional al revés: solo la libera si sigue atada a esta orden.';
