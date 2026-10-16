-- ============================================================
-- 0105 — un operador de TICKETAZO da de alta un cliente desde el panel
--
-- Desde 0090 un operador entra como cualquier cliente y le arma todo:
-- eventos, precios, equipo. Lo único que seguía pidiendo una terminal era
-- el primer paso, el cliente mismo: un insert a mano en `organizadores` y
-- después `crear-usuario.py`. UEB (13/10), Tenis SCZ (14/10) y Dark Garden
-- (15/10) se dieron de alta así, uno por día, y cada uno esperó a que
-- hubiera alguien con el repo abierto. El 15/10 se pidió que los tres
-- operadores puedan hacerlo solos.
--
-- `plataforma_crear_cliente` crea el organizador y deja al operador
-- operando como él, en la misma transacción: el paso siguiente —crear su
-- cuenta de administrador— lo hace la función `equipo`, que ya sabe crear
-- cuentas dentro del cliente efectivo. Si el alta dejara al operador
-- afuera, el panel tendría que llamar a plataforma_operar aparte, y un
-- corte entre las dos dejaría un cliente sin nadie adentro.
--
-- Por qué así y no de otra forma:
--   · la guardia es es_plataforma(), la misma de toda la pestaña: sólo los
--     perfiles de `plataforma_operador` (sin policies, nadie se da de alta
--     solo). Un admin de un cliente que la llame recibe "Sin permiso".
--   · el slug es también el usuario del panel (<slug>@ticketera.local), por
--     eso su regla es la intersección de las dos: [a-z0-9-] de 3 a 30. Si
--     esa cuenta de auth ya existe se rechaza ANTES de crear nada: el
--     cliente quedaría creado y su usuario no, que es justo el estado a
--     medias que este alta viene a evitar.
--   · los slugs que ya son rutas del sitio (/admin, /orden…) se rechazan:
--     ticketazo.com.bo/<slug> es la cartelera del cliente y Vercel resuelve
--     primero la ruta fija, así que su link nunca abriría su página.
--   · la configuración es la de los últimos clientes (UEB, Tenis SCZ, Dark
--     Garden): comisión sumada al precio, sin piso ni fijo, anticipo 100%,
--     cupo oculto, giro automático apagado y sin cuenta. Los defaults de la
--     tabla son de los primeros clientes (piso 5, fijo 3, anticipo 70%) y
--     ya no se le ofrecen a nadie.
--   · `creado_por` queda en la fila: es el único rastro de quién dio de alta
--     a un cliente, que mañana es la primera pregunta si aparece uno raro.
-- ============================================================

alter table organizadores add column if not exists creado_por uuid references perfiles(id);

comment on column organizadores.creado_por is
  'El operador de TICKETAZO que dio de alta al cliente desde Plataforma (0105). Null en los creados a mano.';

create or replace function plataforma_crear_cliente(p_nombre text, p_slug text, p_fee_pct numeric)
returns jsonb
  language plpgsql volatile security definer set search_path = public as $$
declare
  v_nombre  text := btrim(coalesce(p_nombre, ''));
  v_slug    text := lower(btrim(coalesce(p_slug, '')));
  v_id      uuid;
  v_comercio organizadores.comercio_id%type;
begin
  if not es_plataforma() then raise exception 'Sin permiso'; end if;

  if v_nombre = '' or length(v_nombre) > 80 then
    return jsonb_build_object('ok', false, 'motivo', 'Falta el nombre del cliente (hasta 80 letras).');
  end if;
  if v_slug !~ '^[a-z0-9-]{3,30}$' then
    return jsonb_build_object('ok', false, 'motivo',
      'El usuario va en minúsculas, entre 3 y 30 caracteres, sólo letras, números y "-".');
  end if;
  if v_slug in ('admin', 'api', 'cuenta', 'demo', 'evento', 'eventos', 'mis-entradas', 'og',
                'orden', 'organizadores', 'plataforma', 'presentacion', 'privacidad',
                'puerta', 'terminos', 'ticketazo', 'www') then
    return jsonb_build_object('ok', false, 'motivo',
      'Ese usuario es una dirección del sitio. Elegí otro.');
  end if;
  if p_fee_pct is null or p_fee_pct < 0 or p_fee_pct > 20 then
    return jsonb_build_object('ok', false, 'motivo', 'La comisión va en %, entre 0 y 20.');
  end if;
  if exists (select 1 from organizadores where slug = v_slug) then
    return jsonb_build_object('ok', false, 'motivo', 'Ya hay un cliente con ese usuario.');
  end if;
  if exists (select 1 from auth.users where email = v_slug || '@ticketera.local') then
    return jsonb_build_object('ok', false, 'motivo',
      'Ya hay una cuenta del panel con ese usuario. Elegí otro.');
  end if;

  -- El comercio de la pasarela es el mismo para todos desde Distrito
  -- Ferial; se toma del cliente más reciente que lo tenga para no escribir
  -- el número acá.
  select comercio_id into v_comercio from organizadores
   where comercio_id is not null order by created_at desc limit 1;

  insert into organizadores (slug, nombre, activo, fee_pct, fee_piso, fee_fijo_transaccion,
                             comercio_id, anticipo_pct, muestra_cupo, titulo_marca,
                             comision_modo, rrpp_ve_ventas, pago_automatico, pago_auto_minimo,
                             creado_por)
  values (v_slug, v_nombre, true, round(p_fee_pct / 100, 4), 0, 0,
          v_comercio, 1, false, false,
          'sobre', true, false, 0.01,
          auth.uid())
  on conflict (slug) do nothing
  returning id into v_id;
  -- Dos operadores con el mismo slug a la vez: el unique decide y el
  -- segundo recibe lo mismo que si hubiera llegado después.
  if v_id is null then
    return jsonb_build_object('ok', false, 'motivo', 'Ya hay un cliente con ese usuario.');
  end if;

  return plataforma_operar(v_slug) || jsonb_build_object('creado', true, 'id', v_id);
end $$;
revoke execute on function plataforma_crear_cliente(text, text, numeric) from anon, public;
grant execute on function plataforma_crear_cliente(text, text, numeric) to authenticated;

comment on function plataforma_crear_cliente(text, text, numeric) is
  'Alta de un cliente por un operador (es_plataforma). Crea el organizador con la config estándar y deja al operador operando como él; la cuenta de admin la crea después la función equipo.';

-- ── control ─────────────────────────────────────────────────
select * from chequeo_funciones_sin_guardia();
