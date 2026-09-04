-- ============================================================
-- 0052 — pagarle al organizador
--
-- 0039 dejó la cuenta hecha: cuánto se vendió, cuánto es de TICKETAZO,
-- cuánto de los relacionadores y cuánto del organizador. Lo que nunca
-- existió fue el pago. Hasta hoy alguien miraba esa pantalla y hacía una
-- transferencia a mano desde el banco, sin que quede registrado acá que
-- se hizo, por cuánto ni a qué cuenta.
--
-- La plata está en la cuenta de la pasarela y sale por el liquidador de
-- BeePay, que ya paga a cualquier banco boliviano. Esto es la mitad que
-- faltaba de nuestro lado: a qué cuenta, cuánto se puede sacar hoy, y el
-- registro de cada intento.
--
-- ── por qué la cuenta bancaria es una tabla y no columnas ────
--
-- Los datos bancarios cambian: el organizador cierra una cuenta, cambia
-- de banco, corrige el nombre del titular porque el banco lo rebotó. Si
-- fueran columnas de `organizadores`, el pago del mes pasado quedaría
-- diciendo que fue a la cuenta de hoy, que es mentira. Cada cuenta es una
-- fila, sólo una está vigente, y cada pago guarda copiado a dónde fue.
--
-- ── por qué se puede sacar menos de lo que dice el neto ──────
--
-- Si el evento se cae después de que le pagamos todo, los reembolsos los
-- ponemos nosotros. Por eso hay un tope: hasta que el evento no pasa, el
-- organizador puede retirar `anticipo_pct` de lo suyo, no el 100%. Ese
-- número es por organizador porque es una decisión de confianza, no una
-- regla del sistema: a un cliente conocido se le puede poner 1.00.
--
-- ── por qué el disponible se calcula con un candado ──────────
--
-- Dos personas del equipo tocando "Pagar" al mismo tiempo leen el mismo
-- disponible y crean dos pagos que juntos se pasan del tope. Es el mismo
-- viernes a la noche de 0039, pero acá la carrera cuesta el doble de lo
-- que había. `pg_advisory_xact_lock` por evento serializa esa pregunta.
--
-- Idempotente: `create table if not exists`, `drop policy if exists` y
-- `drop function if exists` con la firma completa delante de cada una.
-- ============================================================

-- ── cuánto se le puede adelantar a este organizador ──────────
alter table organizadores
  add column if not exists anticipo_pct numeric(5,4) not null default 0.7000
    check (anticipo_pct >= 0 and anticipo_pct <= 1);

comment on column organizadores.anticipo_pct is
  'Qué parte de lo suyo puede retirar ANTES de que el evento pase. Cerrado el evento se puede retirar todo. 1.00 = sin retención, para un cliente de confianza.';

-- ── la cuenta a la que se le deposita ────────────────────────
-- Los nombres de los campos son los que pide la API del liquidador, para
-- que nadie tenga que traducir en el medio y equivocarse justo acá.
create table if not exists cuenta_bancaria (
  id             uuid primary key default gen_random_uuid(),
  organizador_id uuid not null references organizadores on delete restrict,
  -- El código sale del catálogo del liquidador (bcp_bank_catalog). El
  -- nombre se copia para el comprobante: si mañana el catálogo lo
  -- renombra, el pago viejo tiene que seguir diciendo a qué banco fue.
  banco_codigo   text not null check (btrim(banco_codigo) <> ''),
  banco_nombre   text not null check (btrim(banco_nombre) <> ''),
  cuenta         text not null check (btrim(cuenta) <> ''),
  -- El banco compara el nombre con el suyo y rebota si no coincide. Va
  -- separado en nombres y apellido porque así lo pide la API.
  titular_nombres  text not null check (btrim(titular_nombres) <> ''),
  titular_apellido text not null check (btrim(titular_apellido) <> ''),
  documento_tipo   text not null check (documento_tipo in ('CI','NIT','PAS')),
  documento_numero text not null check (btrim(documento_numero) <> ''),
  -- Sólo para cuentas del BCP con CI: el banco pide la extensión.
  documento_extension text,
  -- Obligatorio cuando el envío va por ACH (todo lo que no es BCP).
  ciudad_codigo  text not null default '701',
  vigente        boolean not null default true,
  creada_at      timestamptz not null default clock_timestamp(),
  creada_por     uuid references perfiles(id),
  nota           text
);
-- Una sola cuenta vigente por organizador: "¿a cuál le pago?" no puede
-- tener dos respuestas.
create unique index if not exists cuenta_bancaria_vigente_uq
  on cuenta_bancaria (organizador_id) where vigente;
create index if not exists cuenta_bancaria_org_idx
  on cuenta_bancaria (organizador_id, creada_at desc);

comment on table cuenta_bancaria is
  'A dónde se le deposita al organizador. Historial: las viejas quedan con vigente=false para poder explicar a qué cuenta fue cada pago.';

-- ── cada pago ────────────────────────────────────────────────
create table if not exists pago_organizador (
  -- El id es también el clientRequestId que viaja al liquidador: es su
  -- clave de idempotencia, así que un reintento nuestro nunca paga dos
  -- veces del lado de allá.
  id             uuid primary key default gen_random_uuid(),
  organizador_id uuid not null references organizadores on delete restrict,
  evento_id      uuid not null references eventos on delete restrict,
  cuenta_id      uuid not null references cuenta_bancaria on delete restrict,
  monto          numeric(12,2) not null check (monto >= 0.01),
  -- pedido            se creó acá y todavía no salió
  -- enviado           el liquidador lo aceptó y está en camino
  -- aprobacion_manual pasó el umbral y espera que alguien lo apruebe
  -- pagado            confirmado por el banco
  -- rechazado         no salió; no reserva saldo
  estado         text not null default 'pedido'
    check (estado in ('pedido','enviado','aprobacion_manual','pagado','rechazado')),
  -- Copiado al momento del pago, por lo mismo que en liquidacion_linea:
  -- el comprobante no puede cambiar si mañana cambian los datos.
  banco_nombre   text not null,
  cuenta         text not null,
  titular        text not null,
  referencia     text,                -- el id que devuelve el liquidador
  respuesta      jsonb not null default '{}'::jsonb,
  motivo         text,                -- por qué se rechazó, si se rechazó
  pedido_por     uuid not null references perfiles(id),
  pedido_at      timestamptz not null default clock_timestamp(),
  actualizado_at timestamptz not null default clock_timestamp()
);
create index if not exists pago_organizador_evento_idx
  on pago_organizador (evento_id, pedido_at desc);

comment on table pago_organizador is
  'Un intento de pago al organizador. El id es el clientRequestId del liquidador: reintentar con el mismo id no paga dos veces.';

-- ── RLS ──────────────────────────────────────────────────────
-- Se lee dentro del organizador y sólo quien puede editar; se escribe
-- únicamente por las funciones de abajo. El `revoke all` va antes del
-- grant porque Supabase otorga permisos por defecto en cada tabla nueva.
alter table cuenta_bancaria   enable row level security;
alter table pago_organizador  enable row level security;

drop policy if exists "cuenta bancaria: la de mi organizador" on cuenta_bancaria;
create policy "cuenta bancaria: la de mi organizador" on cuenta_bancaria for select to authenticated
  using (organizador_id = mi_organizador() and puede_editar());

drop policy if exists "pago organizador: el de mi organizador" on pago_organizador;
create policy "pago organizador: el de mi organizador" on pago_organizador for select to authenticated
  using (organizador_id = mi_organizador() and puede_editar());

revoke all on cuenta_bancaria, pago_organizador from anon, authenticated;
grant select on cuenta_bancaria, pago_organizador to authenticated;

-- La bitácora suma una acción más. El check se recrea entero: agregar un
-- valor a un check es drop + create, no alter.
alter table admin_bitacora drop constraint if exists admin_bitacora_accion_check;
alter table admin_bitacora add constraint admin_bitacora_accion_check
  check (accion in ('orden_anulada','entrada_anulada','cortesias_emitidas',
                    'revision_confirmada','evento_cerrado','evento_reabierto',
                    'comision_pagada','cuenta_bancaria_cambiada','organizador_pagado'));

-- ── guardar la cuenta ────────────────────────────────────────
-- Cambiar la cuenta no pisa la anterior: la baja y crea una nueva. El
-- historial es lo que permite contestar "¿a dónde fue el pago de julio?".
drop function if exists guardar_cuenta_bancaria(jsonb);
create function guardar_cuenta_bancaria(p_datos jsonb) returns jsonb
  language plpgsql volatile security definer set search_path = public as $function$
declare
  v_org uuid := mi_organizador();
  v_yo  uuid := auth.uid();
  c cuenta_bancaria;
begin
  if not puede_editar() then raise exception 'Sin permiso'; end if;

  update cuenta_bancaria set vigente = false
   where organizador_id = v_org and vigente;

  insert into cuenta_bancaria (organizador_id, banco_codigo, banco_nombre, cuenta,
                               titular_nombres, titular_apellido, documento_tipo,
                               documento_numero, documento_extension, ciudad_codigo,
                               creada_por, nota)
  values (v_org,
          btrim(p_datos->>'banco_codigo'), btrim(p_datos->>'banco_nombre'),
          btrim(p_datos->>'cuenta'),
          btrim(p_datos->>'titular_nombres'), btrim(p_datos->>'titular_apellido'),
          coalesce(nullif(btrim(p_datos->>'documento_tipo'),''), 'CI'),
          btrim(p_datos->>'documento_numero'),
          nullif(btrim(coalesce(p_datos->>'documento_extension','')), ''),
          coalesce(nullif(btrim(coalesce(p_datos->>'ciudad_codigo','')),''), '701'),
          v_yo, nullif(btrim(coalesce(p_datos->>'nota','')), ''))
  returning * into c;

  insert into admin_bitacora (organizador_id, evento_id, accion, motivo, actor_id, detalle)
  values (v_org, null, 'cuenta_bancaria_cambiada',
          format('Cuenta de cobro: %s, %s', c.banco_nombre, c.cuenta), v_yo,
          jsonb_build_object('cuenta', c.id, 'banco', c.banco_nombre,
                             'titular', c.titular_nombres || ' ' || c.titular_apellido));

  return jsonb_build_object('ok', true, 'cuenta', c.id,
    'motivo', format('Guardada la cuenta %s de %s.', c.cuenta, c.banco_nombre));
end $function$;
revoke execute on function guardar_cuenta_bancaria(jsonb) from anon, public;
grant execute on function guardar_cuenta_bancaria(jsonb) to authenticated;

-- ── cuánto se puede sacar hoy ────────────────────────────────
-- La cuenta viva, no la foto: esto se mira ANTES de cerrar, mientras se
-- vende. Las comisiones salen de ventas_rrpp_base(), el mismo cuerpo que
-- usan mis_ventas(), ventas_por_rrpp() y cerrar_evento(); recalcularlas
-- acá sería el segundo lugar donde vive la misma cuenta.
--
-- Lo ya pedido reserva aunque todavía no esté pagado: un pago en camino
-- es plata que ya no está. Sólo lo rechazado vuelve al disponible.
drop function if exists disponible_organizador(uuid);
create function disponible_organizador(p_evento uuid) returns jsonb
  language plpgsql stable security definer set search_path = public as $function$
declare
  v_org uuid := mi_organizador();
  e eventos; o organizadores;
  v_bruto numeric(12,2); v_fee numeric(12,2); v_com numeric(12,2);
  v_pagado numeric(12,2); v_tope numeric(12,2); v_pasado boolean;
begin
  if not puede_editar() then raise exception 'Sin permiso'; end if;

  select * into e from eventos where id = p_evento and organizador_id = v_org;
  if not found then raise exception 'EVENTO_INEXISTENTE: ese evento no es tuyo.'; end if;
  select * into o from organizadores where id = v_org;

  select coalesce(sum(subtotal),0), coalesce(sum(fee),0)
    into v_bruto, v_fee
    from ordenes where evento_id = p_evento and estado = 'pagada';

  select coalesce(sum(comision),0) into v_com
    from ventas_rrpp_base(p_evento, null);

  select coalesce(sum(monto),0) into v_pagado
    from pago_organizador
   where evento_id = p_evento and estado <> 'rechazado';

  -- Pasado el evento (o cerrado a mano) no hay nada que retener: lo que
  -- la retención cubre es el reembolso de un evento que no ocurrió.
  v_pasado := e.estado = 'cerrado' or e.fecha < (now() at time zone 'America/La_Paz')::date;
  v_tope := round((v_bruto - v_com) * (case when v_pasado then 1 else o.anticipo_pct end), 2);

  return jsonb_build_object(
    'ok', true, 'evento', p_evento,
    'bruto', v_bruto, 'fee', v_fee, 'comisiones', v_com,
    'neto', v_bruto - v_com,
    'anticipo_pct', case when v_pasado then 1 else o.anticipo_pct end,
    'evento_pasado', v_pasado,
    'tope', v_tope, 'pagado', v_pagado,
    'disponible', greatest(v_tope - v_pagado, 0),
    'cuenta', (select jsonb_build_object('id', c.id, 'banco', c.banco_nombre,
                                         'cuenta', c.cuenta,
                                         'titular', c.titular_nombres || ' ' || c.titular_apellido)
                 from cuenta_bancaria c
                where c.organizador_id = v_org and c.vigente));
end $function$;
revoke execute on function disponible_organizador(uuid) from anon, public;
grant execute on function disponible_organizador(uuid) to authenticated;

-- ── pedir el pago ────────────────────────────────────────────
-- Crea la fila y nada más: mandarla al liquidador es trabajo de la Edge
-- Function, que corre afuera y puede tardar. Separarlo es lo que permite
-- que un timeout con el banco no deje la transacción abierta, y que el
-- reintento use el MISMO id (que es el clientRequestId de allá).
drop function if exists pedir_pago_organizador(uuid, numeric);
create function pedir_pago_organizador(p_evento uuid, p_monto numeric default null)
  returns jsonb
  language plpgsql volatile security definer set search_path = public as $function$
declare
  v_org uuid := mi_organizador();
  v_yo  uuid := auth.uid();
  d jsonb; c cuenta_bancaria; v_monto numeric(12,2); p pago_organizador;
begin
  if not puede_editar() then raise exception 'Sin permiso'; end if;

  -- El candado: mientras esta transacción decide cuánto hay disponible,
  -- ninguna otra puede estar decidiendo lo mismo para el mismo evento.
  perform pg_advisory_xact_lock(hashtext('pago_organizador:' || p_evento::text));

  d := disponible_organizador(p_evento);

  select * into c from cuenta_bancaria
   where organizador_id = v_org and vigente;
  if not found then
    return jsonb_build_object('ok', false, 'falta', 'cuenta',
      'motivo', 'Todavía no cargaste la cuenta bancaria del organizador.');
  end if;

  v_monto := round(coalesce(p_monto, (d->>'disponible')::numeric), 2);

  if v_monto < 0.01 then
    return jsonb_build_object('ok', false, 'falta', 'saldo', 'disponible', d->>'disponible',
      'motivo', 'No hay nada para retirar todavía.');
  end if;
  if v_monto > (d->>'disponible')::numeric then
    return jsonb_build_object('ok', false, 'falta', 'saldo', 'disponible', d->>'disponible',
      'motivo', format('Sólo hay %s Bs disponibles.', d->>'disponible'));
  end if;

  insert into pago_organizador (organizador_id, evento_id, cuenta_id, monto,
                                banco_nombre, cuenta, titular, pedido_por)
  values (v_org, p_evento, c.id, v_monto, c.banco_nombre, c.cuenta,
          c.titular_nombres || ' ' || c.titular_apellido, v_yo)
  returning * into p;

  insert into admin_bitacora (organizador_id, evento_id, accion, motivo, actor_id, detalle)
  values (v_org, p_evento, 'organizador_pagado',
          format('Pago de %s Bs a %s, cuenta %s', p.monto, p.titular, p.cuenta), v_yo,
          jsonb_build_object('pago', p.id, 'monto', p.monto, 'banco', p.banco_nombre));

  -- El detalle del beneficiario viaja de vuelta porque la Edge Function
  -- lo necesita para armar el pedido al liquidador y no tiene otra forma
  -- de leerlo: la tabla no es suya.
  return jsonb_build_object('ok', true, 'pago', p.id, 'monto', p.monto,
    'beneficiario', jsonb_build_object(
      'banco_codigo', c.banco_codigo, 'cuenta', c.cuenta,
      'nombres', c.titular_nombres, 'apellido', c.titular_apellido,
      'documento_tipo', c.documento_tipo, 'documento_numero', c.documento_numero,
      'documento_extension', c.documento_extension, 'ciudad_codigo', c.ciudad_codigo),
    'motivo', format('Pedido el pago de %s Bs a %s.', p.monto, p.titular));
end $function$;
revoke execute on function pedir_pago_organizador(uuid, numeric) from anon, public;
grant execute on function pedir_pago_organizador(uuid, numeric) to authenticated;

-- ── anotar cómo salió ────────────────────────────────────────
-- La llama la Edge Function con service_role después de hablar con el
-- liquidador. No la puede llamar nadie logueado: marcar un pago como
-- 'pagado' sin que el banco lo diga es exactamente lo que no queremos que
-- se pueda hacer desde una pantalla.
drop function if exists confirmar_pago_organizador(uuid, text, text, jsonb, text);
create function confirmar_pago_organizador(p_pago uuid, p_estado text,
                                           p_referencia text default null,
                                           p_respuesta jsonb default '{}'::jsonb,
                                           p_motivo text default null) returns jsonb
  language plpgsql volatile security definer set search_path = public as $function$
declare p pago_organizador;
begin
  update pago_organizador
     set estado = p_estado,
         referencia = coalesce(p_referencia, referencia),
         respuesta = p_respuesta,
         motivo = nullif(btrim(coalesce(p_motivo, '')), ''),
         actualizado_at = clock_timestamp()
   where id = p_pago
  returning * into p;

  if not found then
    return jsonb_build_object('ok', false, 'motivo', 'Ese pago no existe.');
  end if;
  return jsonb_build_object('ok', true, 'pago', p.id, 'estado', p.estado);
end $function$;
revoke execute on function confirmar_pago_organizador(uuid, text, text, jsonb, text)
  from anon, public, authenticated;
grant execute on function confirmar_pago_organizador(uuid, text, text, jsonb, text)
  to service_role;

-- ── el historial, para la pantalla ───────────────────────────
drop function if exists pagos_organizador(uuid);
create function pagos_organizador(p_evento uuid) returns jsonb
  language plpgsql stable security definer set search_path = public as $function$
declare v_org uuid := mi_organizador();
begin
  if not puede_editar() then raise exception 'Sin permiso'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', p.id, 'monto', p.monto, 'estado', p.estado,
             'banco', p.banco_nombre, 'cuenta', p.cuenta, 'titular', p.titular,
             'referencia', p.referencia, 'motivo', p.motivo,
             'pedido_at', p.pedido_at, 'pedido_por', q.nombre)
           order by p.pedido_at desc)
      from pago_organizador p
      left join perfiles q on q.id = p.pedido_por
     where p.evento_id = p_evento and p.organizador_id = v_org), '[]'::jsonb);
end $function$;
revoke execute on function pagos_organizador(uuid) from anon, public;
grant execute on function pagos_organizador(uuid) to authenticated;
