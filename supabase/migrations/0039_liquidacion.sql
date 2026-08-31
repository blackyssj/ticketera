-- ============================================================
-- 0039 — cerrar el evento y liquidar
--
-- Lo último que le faltaba al ciclo. Se podía crear un evento, venderlo,
-- escanearlo en la puerta y arreglar lo que salió mal; cuando terminaba,
-- no había forma de cerrarlo ni de saber cuánto le tocaba a cada uno.
-- `eventos.estado` acepta 'cerrado' desde 0003 y nadie lo escribía.
--
-- ── por qué la liquidación es una foto y no una consulta ─────
--
-- La tentación es calcularla al abrir la pantalla: los datos están todos
-- y `ventas_por_rrpp()` ya hace la cuenta. Pero entonces una anulación
-- hecha la semana siguiente cambiaría hacia atrás lo que la pantalla
-- decía el día que se pagó, y el comprobante de esa transferencia no
-- coincidiría con nada. El que reclama tiene razón y no hay con qué
-- contestarle.
--
-- Así que cerrar CONGELA. Se escriben los totales y una línea por
-- relacionador con lo que se le debe, y esas filas no se recalculan
-- nunca más. Si después se anula algo, la foto no se toca: la diferencia
-- se ve comparándola con lo de hoy, que es justamente lo que hay que
-- poder mirar. Taparla sería fingir que no pasó.
--
-- ── por qué el pago se marca con un update condicional ───────
--
-- "¿Ya le pagué a Nico?" es la pregunta que termina en pagar dos veces.
-- La condición de "todavía no se pagó" viaja DENTRO del update, igual
-- que la toma de cupo de 0009, la validación de 0032 y la asignación de
-- mesa de 0029. Dos personas del equipo marcando el mismo pago a la vez
-- no es el caso raro: es el viernes a la noche, con los dos mirando la
-- misma pantalla desde teléfonos distintos.
--
-- Idempotente: `create table if not exists`, `drop policy if exists`
-- delante de cada policy y `drop function if exists` con la firma
-- completa delante de cada función.
-- ============================================================

-- ── la foto ──────────────────────────────────────────────────
create table if not exists liquidacion (
  id             uuid primary key default gen_random_uuid(),
  organizador_id uuid not null references organizadores on delete restrict,
  evento_id      uuid not null references eventos on delete cascade,
  -- Un evento se puede reabrir y volver a cerrar: cada cierre es una foto
  -- propia. La vigente es la de version más alta; las viejas quedan para
  -- poder explicar con qué números se pagó aquella vez.
  version        int  not null default 1,
  vigente        boolean not null default true,
  bruto          numeric(12,2) not null,   -- sum(ordenes.subtotal) pagadas
  fee            numeric(12,2) not null,   -- lo de TICKETAZO
  cobrado        numeric(12,2) not null,   -- bruto + fee, lo que paso por la pasarela
  comisiones     numeric(12,2) not null,   -- lo de todos los relacionadores
  neto           numeric(12,2) not null,   -- bruto - comisiones, lo del organizador
  entradas       int not null,
  ordenes        int not null,
  cerrada_por    uuid not null references perfiles(id),
  cerrada_at     timestamptz not null default clock_timestamp(),
  motivo         text not null check (btrim(motivo) <> ''),
  detalle        jsonb not null default '{}'::jsonb
);
create unique index if not exists liquidacion_vigente_uq
  on liquidacion (evento_id) where vigente;
create index if not exists liquidacion_evento_idx on liquidacion (evento_id, version desc);

comment on table liquidacion is
  'La foto con la que se cerró un evento. No se recalcula: si después se anula algo, la diferencia se ve contra los datos de hoy, no se tapa reescribiendo esto.';

create table if not exists liquidacion_linea (
  id             uuid primary key default gen_random_uuid(),
  organizador_id uuid not null references organizadores on delete restrict,
  liquidacion_id uuid not null references liquidacion on delete cascade,
  perfil_id      uuid not null references perfiles(id),
  nombre         text not null,            -- congelado: el perfil se puede renombrar
  slug           text,
  entradas       int not null,
  recaudado      numeric(12,2) not null,
  comision_unitaria numeric(12,2) not null,
  comision       numeric(12,2) not null,
  -- el pago
  pagada_at      timestamptz,
  pagada_por     uuid references perfiles(id),
  pagado_monto   numeric(12,2),
  pagado_nota    text,
  unique (liquidacion_id, perfil_id)
);
create index if not exists liquidacion_linea_idx on liquidacion_linea (liquidacion_id);

comment on column liquidacion_linea.nombre is
  'El nombre con el que se cerró, copiado. Si mañana el perfil se renombra, el comprobante de ese pago tiene que seguir diciendo a quién se le pagó.';

-- ── RLS ──────────────────────────────────────────────────────
-- Se lee dentro del organizador; se escribe SOLO por las funciones de
-- abajo, que corren como definer. El `revoke all` antes del grant no es
-- ceremonia: Supabase otorga permisos por defecto a authenticated en cada
-- tabla nueva, así que sin esto la tabla nace escribible.
alter table liquidacion       enable row level security;
alter table liquidacion_linea enable row level security;

drop policy if exists "liquidacion: la de mi organizador" on liquidacion;
create policy "liquidacion: la de mi organizador" on liquidacion for select to authenticated
  using (organizador_id = mi_organizador() and puede_editar());

drop policy if exists "liquidacion linea: la de mi organizador" on liquidacion_linea;
create policy "liquidacion linea: la de mi organizador" on liquidacion_linea for select to authenticated
  using (organizador_id = mi_organizador() and puede_editar());

revoke all on liquidacion, liquidacion_linea from anon, authenticated;
grant select on liquidacion, liquidacion_linea to authenticated;

-- La bitácora de admin (0038) suma tres acciones. El check se recrea con
-- la lista entera: agregar valores a un check es drop + create, no alter.
alter table admin_bitacora drop constraint if exists admin_bitacora_accion_check;
alter table admin_bitacora add constraint admin_bitacora_accion_check
  check (accion in ('orden_anulada','entrada_anulada','cortesias_emitidas',
                    'revision_confirmada','evento_cerrado','evento_reabierto',
                    'comision_pagada'));

-- ── cerrar ───────────────────────────────────────────────────
drop function if exists cerrar_evento(uuid, text);
create function cerrar_evento(p_evento uuid, p_motivo text) returns jsonb
  language plpgsql volatile security definer set search_path = public as $function$
declare
  v_org    uuid := mi_organizador();
  v_yo     uuid := auth.uid();
  v_motivo text := btrim(coalesce(p_motivo, ''));
  e eventos; v_liq uuid; v_ver int;
  v_bruto numeric(12,2); v_fee numeric(12,2); v_ent int; v_ord int;
  v_com numeric(12,2) := 0; v_pend int; v_rev int;
begin
  if not puede_editar() then raise exception 'Sin permiso'; end if;
  if v_motivo = '' then
    raise exception 'MOTIVO_REQUERIDO: sin motivo no se cierra. El cierre es con lo que se le paga a la gente; dentro de un mes nadie se acuerda por qué se cerró ese día.';
  end if;

  -- for update: dos cierres a la vez sobre el mismo evento se serializan
  -- acá, y el segundo ve el estado que dejó el primero.
  select * into e from eventos where id = p_evento and organizador_id = v_org for update;
  if not found then raise exception 'EVENTO_INEXISTENTE: %', p_evento; end if;
  if e.estado = 'cerrado' then
    raise exception 'YA_CERRADO: este evento ya se cerró. Reabrilo si hay que rehacer la liquidación.';
  end if;

  -- Plata sin resolver. No frena el cierre —a veces hay que cerrar igual—
  -- pero viaja en la respuesta para que la pantalla lo muestre antes de
  -- que alguien firme una transferencia con la cuenta a medio hacer.
  select count(*) into v_rev  from ordenes
   where evento_id = p_evento and estado = 'revision_manual';
  select count(*) into v_pend from ordenes
   where evento_id = p_evento and estado = 'pendiente' and expira_at > now();

  select coalesce(sum(subtotal),0), coalesce(sum(fee),0), count(*)
    into v_bruto, v_fee, v_ord
    from ordenes where evento_id = p_evento and estado = 'pagada';
  select count(*) into v_ent
    from entradas where evento_id = p_evento and estado <> 'anulada';

  select coalesce(version,0) + 1 into v_ver from liquidacion
   where evento_id = p_evento order by version desc limit 1;
  v_ver := coalesce(v_ver, 1);
  update liquidacion set vigente = false where evento_id = p_evento and vigente;

  insert into liquidacion (organizador_id, evento_id, version, vigente, bruto, fee,
                           cobrado, comisiones, neto, entradas, ordenes,
                           cerrada_por, motivo, detalle)
  values (v_org, p_evento, v_ver, true, v_bruto, v_fee, v_bruto + v_fee, 0,
          v_bruto, v_ent, v_ord, v_yo, v_motivo,
          jsonb_build_object('revision_manual_al_cerrar', v_rev,
                             'pendientes_vivas_al_cerrar', v_pend))
  returning id into v_liq;

  -- Las líneas salen de ventas_rrpp_base(), el MISMO cuerpo que usan
  -- mis_ventas() y ventas_por_rrpp() (0026). Recalcular la comisión acá
  -- sería un segundo lugar donde vive la misma cuenta, y es cómo el
  -- relacionador y el admin terminan viendo números distintos.
  insert into liquidacion_linea (organizador_id, liquidacion_id, perfil_id, nombre, slug,
                                 entradas, recaudado, comision_unitaria, comision)
  select v_org, v_liq, v.perfil_id, p.nombre, p.slug,
         v.entradas, v.recaudado, v.comision_unitaria, v.comision
    from ventas_rrpp_base(p_evento, null) v
    join perfiles p on p.id = v.perfil_id and p.organizador_id = v_org;

  select coalesce(sum(comision),0) into v_com
    from liquidacion_linea where liquidacion_id = v_liq;
  update liquidacion set comisiones = v_com, neto = v_bruto - v_com where id = v_liq;

  update eventos set estado = 'cerrado' where id = p_evento;

  insert into admin_bitacora (organizador_id, evento_id, accion, motivo, actor_id, detalle)
  values (v_org, p_evento, 'evento_cerrado', v_motivo, v_yo,
          jsonb_build_object('liquidacion', v_liq, 'version', v_ver,
                             'bruto', v_bruto, 'fee', v_fee, 'comisiones', v_com));

  return jsonb_build_object('ok', true, 'liquidacion', v_liq, 'version', v_ver,
    'bruto', v_bruto, 'fee', v_fee, 'comisiones', v_com, 'neto', v_bruto - v_com,
    'entradas', v_ent, 'ordenes', v_ord,
    'sin_resolver', jsonb_build_object('revision_manual', v_rev, 'pendientes_vivas', v_pend),
    'motivo', format('Evento cerrado. Quedan %s Bs para el organizador y %s Bs en comisiones.',
                     v_bruto - v_com, v_com));
end $function$;
revoke execute on function cerrar_evento(uuid, text) from anon, public;
grant execute on function cerrar_evento(uuid, text) to authenticated;

-- ── reabrir ──────────────────────────────────────────────────
-- Un cierre apurado pasa. Reabrir devuelve el evento a 'publicado' y deja
-- la foto donde está: no se borra ni se corrige. El próximo cierre escribe
-- una versión nueva y esta queda como el registro de con qué números se
-- cerró aquella vez — que es lo que hay que poder mostrar si alguien ya
-- cobró contra ella.
drop function if exists reabrir_evento(uuid, text);
create function reabrir_evento(p_evento uuid, p_motivo text) returns jsonb
  language plpgsql volatile security definer set search_path = public as $function$
declare
  v_org uuid := mi_organizador();
  v_motivo text := btrim(coalesce(p_motivo, ''));
  e eventos; v_pagadas int;
begin
  if not puede_editar() then raise exception 'Sin permiso'; end if;
  if v_motivo = '' then raise exception 'MOTIVO_REQUERIDO: sin motivo no se reabre.'; end if;

  select * into e from eventos where id = p_evento and organizador_id = v_org for update;
  if not found then raise exception 'EVENTO_INEXISTENTE: %', p_evento; end if;
  if e.estado <> 'cerrado' then
    raise exception 'NO_ESTA_CERRADO: este evento no está cerrado.';
  end if;

  -- Aviso, no impedimento: si ya se pagaron comisiones contra la foto
  -- vigente, reabrir y volver a cerrar puede dar otros números y alguien
  -- ya cobró los viejos.
  select count(*) into v_pagadas from liquidacion_linea l
    join liquidacion q on q.id = l.liquidacion_id
   where q.evento_id = p_evento and q.vigente and l.pagada_at is not null;

  update eventos set estado = 'publicado' where id = p_evento;

  insert into admin_bitacora (organizador_id, evento_id, accion, motivo, actor_id, detalle)
  values (v_org, p_evento, 'evento_reabierto', v_motivo, auth.uid(),
          jsonb_build_object('comisiones_ya_pagadas', v_pagadas));

  return jsonb_build_object('ok', true, 'evento', p_evento,
    'comisiones_ya_pagadas', v_pagadas,
    'motivo', case when v_pagadas > 0
      then format('Evento reabierto. Ojo: %s comisiones ya se pagaron con la liquidación anterior.', v_pagadas)
      else 'Evento reabierto. La liquidación anterior queda guardada.' end);
end $function$;
revoke execute on function reabrir_evento(uuid, text) from anon, public;
grant execute on function reabrir_evento(uuid, text) to authenticated;

-- ── marcar una comisión como pagada ──────────────────────────
-- La condición viaja DENTRO del update. Preguntar "¿ya está pagada?" y
-- después escribir es una carrera, y acá la carrera se paga con plata:
-- dos del equipo mirando la misma pantalla desde teléfonos distintos, los
-- dos tocan Pagar, y el relacionador cobra dos veces. Si el update no
-- devuelve fila, este no fue el que la pagó — y recién ahí se averigua
-- por qué, para contestar distinto.
drop function if exists pagar_comision(uuid, numeric, text);
create function pagar_comision(p_linea uuid, p_monto numeric default null,
                               p_nota text default null) returns jsonb
  language plpgsql volatile security definer set search_path = public as $function$
declare
  v_org uuid := mi_organizador();
  v_yo  uuid := auth.uid();
  l liquidacion_linea; v_prev record;
begin
  if not puede_editar() then raise exception 'Sin permiso'; end if;

  update liquidacion_linea
     set pagada_at    = clock_timestamp(),
         pagada_por   = v_yo,
         pagado_monto = coalesce(p_monto, comision),
         pagado_nota  = nullif(btrim(coalesce(p_nota, '')), '')
   where id = p_linea
     and organizador_id = v_org
     and pagada_at is null          -- ← el candado, adentro
  returning * into l;

  if found then
    insert into admin_bitacora (organizador_id, evento_id, accion, motivo, actor_id, detalle)
    select v_org, q.evento_id, 'comision_pagada',
           coalesce(nullif(btrim(coalesce(p_nota,'')),''),
                    format('Comisión de %s pagada', l.nombre)),
           v_yo,
           jsonb_build_object('linea', l.id, 'perfil', l.perfil_id, 'nombre', l.nombre,
                              'entradas', l.entradas, 'monto', l.pagado_monto)
      from liquidacion q where q.id = l.liquidacion_id;

    return jsonb_build_object('ok', true, 'linea', l.id, 'monto', l.pagado_monto,
      'motivo', format('Pagado: %s Bs a %s.', l.pagado_monto, l.nombre));
  end if;

  -- No devolvió fila. Recién acá se averigua por qué.
  select ll.pagada_at, ll.pagado_monto, ll.nombre, p.nombre as quien
    into v_prev
    from liquidacion_linea ll
    left join perfiles p on p.id = ll.pagada_por
   where ll.id = p_linea and ll.organizador_id = v_org;

  if not found then raise exception 'LINEA_INEXISTENTE: esa línea no es de tu liquidación.'; end if;

  return jsonb_build_object('ok', false, 'ya_pagada', true,
    'pagada_at', v_prev.pagada_at, 'monto', v_prev.pagado_monto,
    'motivo', format('La comisión de %s ya se pagó%s: %s Bs.',
                     v_prev.nombre,
                     case when v_prev.quien is not null then ', la marcó ' || v_prev.quien else '' end,
                     v_prev.pagado_monto));
end $function$;
revoke execute on function pagar_comision(uuid, numeric, text) from anon, public;
grant execute on function pagar_comision(uuid, numeric, text) to authenticated;

-- ── leerla ───────────────────────────────────────────────────
-- Devuelve la foto Y lo que dicen los datos hoy. Las dos cosas juntas y a
-- propósito: si se anuló algo después de cerrar, la diferencia es lo
-- primero que hay que ver. Mostrar solo la foto esconde que cambió;
-- mostrar solo lo de hoy contradice el comprobante de lo que ya se pagó.
drop function if exists liquidacion_evento(uuid);
create function liquidacion_evento(p_evento uuid) returns jsonb
  language plpgsql stable security definer set search_path = public as $function$
declare
  v_org uuid := mi_organizador();
  q liquidacion; e eventos;
  v_bruto numeric(12,2); v_fee numeric(12,2); v_ent int; v_ord int; v_com numeric(12,2);
begin
  if not puede_editar() then raise exception 'Sin permiso'; end if;
  select * into e from eventos where id = p_evento and organizador_id = v_org;
  if not found then return '{}'::jsonb; end if;

  -- lo que dicen los datos AHORA
  select coalesce(sum(subtotal),0), coalesce(sum(fee),0), count(*)
    into v_bruto, v_fee, v_ord
    from ordenes where evento_id = p_evento and estado = 'pagada';
  select count(*) into v_ent
    from entradas where evento_id = p_evento and estado <> 'anulada';
  select coalesce(sum(comision),0) into v_com from ventas_rrpp_base(p_evento, null);

  select * into q from liquidacion where evento_id = p_evento and vigente;

  return jsonb_build_object(
    'evento', jsonb_build_object('id', e.id, 'nombre', e.nombre, 'fecha', e.fecha,
                                 'estado', e.estado, 'cerrado', e.estado = 'cerrado'),
    'hoy', jsonb_build_object('bruto', v_bruto, 'fee', v_fee, 'cobrado', v_bruto + v_fee,
                              'comisiones', v_com, 'neto', v_bruto - v_com,
                              'entradas', v_ent, 'ordenes', v_ord),
    'sin_resolver', jsonb_build_object(
      'revision_manual', (select count(*) from ordenes
         where evento_id = p_evento and estado = 'revision_manual'),
      'pendientes_vivas', (select count(*) from ordenes
         where evento_id = p_evento and estado = 'pendiente' and expira_at > now())),
    'foto', case when q.id is null then null else jsonb_build_object(
      'id', q.id, 'version', q.version, 'cerrada_at', q.cerrada_at, 'motivo', q.motivo,
      'cerrada_por', (select nombre from perfiles where id = q.cerrada_por),
      'bruto', q.bruto, 'fee', q.fee, 'cobrado', q.cobrado,
      'comisiones', q.comisiones, 'neto', q.neto,
      'entradas', q.entradas, 'ordenes', q.ordenes, 'detalle', q.detalle,
      -- La diferencia, ya restada. Que cada pantalla la calcule por su
      -- cuenta es cómo dos pantallas muestran dos diferencias distintas.
      'difiere', (q.bruto <> v_bruto or q.comisiones <> v_com or q.entradas <> v_ent),
      'diferencia', jsonb_build_object('bruto', v_bruto - q.bruto,
                                       'comisiones', v_com - q.comisiones,
                                       'entradas', v_ent - q.entradas),
      'lineas', coalesce((
        select jsonb_agg(jsonb_build_object(
                 'id', l.id, 'perfil_id', l.perfil_id, 'nombre', l.nombre, 'slug', l.slug,
                 'entradas', l.entradas, 'recaudado', l.recaudado,
                 'comision_unitaria', l.comision_unitaria, 'comision', l.comision,
                 'pagada', l.pagada_at is not null, 'pagada_at', l.pagada_at,
                 'pagado_monto', l.pagado_monto, 'pagado_nota', l.pagado_nota,
                 'pagada_por', (select nombre from perfiles where id = l.pagada_por))
               order by l.comision desc, l.nombre)
          from liquidacion_linea l where l.liquidacion_id = q.id), '[]'::jsonb)) end);
end $function$;
revoke execute on function liquidacion_evento(uuid) from anon, public;
grant execute on function liquidacion_evento(uuid) to authenticated;
