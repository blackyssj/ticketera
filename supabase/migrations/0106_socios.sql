-- ============================================================
-- 0106 — la cuenta de los socios: cuánto le toca a cada uno y cuánto le queda
--
-- La ganancia de TICKETAZO es de tres socios (los tres operadores:
-- José, Francisco y Juan Pablo) en partes iguales. Hasta hoy el panel
-- decía cuánto había en total y cuánto "nos retiramos", pero no de quién
-- era cada retiro: el 17/10 se hizo un cierre con la calculadora del
-- teléfono y el 18/10 nadie sabía cuánto le faltaba cobrar a quién.
-- Revisando el liquidador apareció que a una misma cuenta habían salido
-- cinco giros, no uno.
--
-- ── el modelo ──
--   · socio_corte: un reparto ya acordado. Guarda cuánto se repartió en
--     partes iguales (`repartido`) y cuánta ganancia acumulada había en el
--     sistema a esa hora (`ganancia_al`). Lo que se gane después de ese
--     corte se suma solo y también se divide entre todos.
--   · retiro_plataforma.socio_id: a quién le fue la plata. Un retiro sin
--     socio (los viejos, o uno que no es de nadie) mueve el monedero pero
--     no la cuenta de ningún socio.
--   · le toca = sum(repartido / socios) de cada corte
--             + (ganancia de hoy − ganancia_al del último corte) / socios
--     cobró   = sum(retiros con su socio_id)
--     le queda = le toca − cobró
--
-- `repartido` y `ganancia_al` van separados a propósito: el 17/10 el sistema
-- tenía 8.490 de ganancia acumulada y se repartieron 7.212,92. La diferencia
-- es lo que ya había salido antes por otros giros, que los socios decidieron
-- no contarle a nadie. Si se guardara una sola cifra, o el reparto o la
-- ganancia nueva saldrían mal.
--
-- Anotar el retiro de un socio ya no se compara con el disponible del
-- monedero sino con lo que le queda a ESE socio: la caja la cuida el
-- cuadre de arriba del panel, y un socio no puede anotarse más de lo suyo.
-- ============================================================

alter table retiro_plataforma add column if not exists socio_id uuid references perfiles(id);

comment on column retiro_plataforma.socio_id is
  'El socio que cobró este retiro (0106). Null: movió el monedero pero no cuenta para la parte de ningún socio.';

create table if not exists socio_corte (
  id          uuid primary key default gen_random_uuid(),
  al          timestamptz not null,
  ganancia_al numeric(12,2) not null,
  repartido   numeric(12,2) not null check (repartido >= 0),
  nota        text,
  hecho_por   uuid references perfiles(id),
  hecho_at    timestamptz not null default clock_timestamp()
);
alter table socio_corte enable row level security;
revoke all on socio_corte from anon, authenticated;

comment on table socio_corte is
  'Un reparto de la ganancia entre los socios (0106): `repartido` se divide en partes iguales y lo ganado después de `ganancia_al` se suma solo. Sin policies: se lee por socios_plataforma(), que exige es_plataforma().';

-- La ganancia acumulada (comisión menos lo que se lleva la pasarela) de las
-- órdenes pagadas antes de un momento. Es la cuenta de panel_plataforma
-- sin el redondeo por cliente, que mueve centavos y no más.
create or replace function ganancia_al(p_al timestamptz) returns numeric
  language sql stable security definer set search_path = public as $$
  select round(coalesce(sum(o.fee), 0) - coalesce(sum(o.total), 0) * costo_pasarela_pct(), 2)
    from ordenes o
   where o.estado = 'pagada'
     and coalesce(o.pago_ref, '') not like 'SIM-%'
     and coalesce(o.pagada_at, o.created_at) < p_al
$$;
revoke execute on function ganancia_al(timestamptz) from anon, public, authenticated;

-- ── la cuenta ──────────────────────────────────────────────
create or replace function socios_plataforma() returns jsonb
  language plpgsql stable security definer set search_path = public as $function$
declare
  v_n int; v_ganancia numeric(12,2); v_ult socio_corte; v_nueva numeric(12,2);
  v_base numeric(12,2); v_socios jsonb;
begin
  if not es_plataforma() then raise exception 'Sin permiso'; end if;

  select count(*) into v_n from plataforma_operador po join perfiles p on p.id = po.perfil_id and p.activo;
  v_ganancia := (panel_plataforma()->'total'->>'margen')::numeric;
  select * into v_ult from socio_corte order by al desc limit 1;
  v_nueva := case when v_ult.id is null then v_ganancia else v_ganancia - v_ult.ganancia_al end;
  select coalesce(sum(repartido), 0) into v_base from socio_corte;

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', s.id, 'nombre', s.nombre,
           'le_toca', s.le_toca, 'cobro', s.cobro,
           'queda', round(s.le_toca - s.cobro, 2)) order by s.nombre), '[]'::jsonb)
    into v_socios
    from (select p.id, p.nombre,
                 round((v_base + v_nueva) / greatest(v_n, 1), 2) as le_toca,
                 (select coalesce(sum(r.monto), 0) from retiro_plataforma r where r.socio_id = p.id) as cobro
            from plataforma_operador po join perfiles p on p.id = po.perfil_id and p.activo) s;

  return jsonb_build_object('ok', true, 'socios', v_socios, 'cantidad', v_n,
    'ganancia_nueva', v_nueva,
    'corte', case when v_ult.id is null then null else jsonb_build_object(
      'al', v_ult.al, 'repartido', v_ult.repartido, 'ganancia_al', v_ult.ganancia_al,
      'nota', v_ult.nota) end);
end $function$;
revoke execute on function socios_plataforma() from anon, public;
grant execute on function socios_plataforma() to authenticated;

-- ── anotar un retiro, ahora con su socio ───────────────────
drop function if exists registrar_retiro_plataforma(numeric, text, text);
create function registrar_retiro_plataforma(p_monto numeric, p_nota text default null,
                                            p_referencia text default null, p_socio uuid default null)
  returns jsonb language plpgsql volatile security definer set search_path = public as $function$
declare v_disp numeric(12,2); v_id uuid; v_monto numeric(12,2) := round(p_monto, 2); v_queda numeric(12,2);
        v_nombre text;
begin
  if not es_plataforma() then raise exception 'Sin permiso'; end if;
  if v_monto is null or v_monto <= 0 then
    return jsonb_build_object('ok', false, 'motivo', 'El monto tiene que ser mayor a cero.');
  end if;
  if p_socio is not null then
    select p.nombre into v_nombre from plataforma_operador po join perfiles p on p.id = po.perfil_id
     where po.perfil_id = p_socio;
    if v_nombre is null then
      return jsonb_build_object('ok', false, 'motivo', 'Ese socio no existe.');
    end if;
    select (s->>'queda')::numeric into v_queda
      from jsonb_array_elements(socios_plataforma()->'socios') s where (s->>'id')::uuid = p_socio;
    if v_monto > coalesce(v_queda, 0) + 1 then
      return jsonb_build_object('ok', false,
        'motivo', format('A %s le quedan %s; no se puede anotar un retiro de %s.', v_nombre, coalesce(v_queda, 0), v_monto));
    end if;
  else
    select (panel_plataforma()->'total'->>'disponible')::numeric into v_disp;
    if v_monto > v_disp + 1 then
      return jsonb_build_object('ok', false,
        'motivo', format('Hay %s disponibles; no se puede anotar un retiro de %s.', v_disp, v_monto));
    end if;
  end if;
  insert into retiro_plataforma (monto, referencia, nota, hecho_por, socio_id)
  values (v_monto, nullif(btrim(coalesce(p_referencia,'')),''),
          nullif(btrim(coalesce(p_nota,'')),''), auth.uid(), p_socio)
  returning id into v_id;
  return jsonb_build_object('ok', true, 'id', v_id, 'monto', v_monto,
    'motivo', case when v_nombre is null then format('Anotado el retiro de Bs %s.', v_monto)
                   else format('Anotado: Bs %s para %s.', v_monto, v_nombre) end);
end $function$;
revoke execute on function registrar_retiro_plataforma(numeric, text, text, uuid) from anon, public;
grant execute on function registrar_retiro_plataforma(numeric, text, text, uuid) to authenticated;

-- ── la lista, con el socio ─────────────────────────────────
create or replace function retiros_plataforma(p_limite int default 25) returns jsonb
  language plpgsql stable security definer set search_path = public as $function$
begin
  if not es_plataforma() then raise exception 'Sin permiso'; end if;
  return (select coalesce(jsonb_agg(jsonb_build_object(
            'id', r.id, 'monto', r.monto, 'referencia', r.referencia, 'nota', r.nota,
            'quien', p.nombre, 'socio', s.nombre, 'cuando', r.hecho_at) order by r.hecho_at desc), '[]'::jsonb)
    from (select * from retiro_plataforma order by hecho_at desc
           limit greatest(coalesce(p_limite, 25), 1)) r
    left join perfiles p on p.id = r.hecho_por
    left join perfiles s on s.id = r.socio_id);
end $function$;

-- ── lo que pasó hasta hoy, anotado ─────────────────────────
-- Verificado contra h2h_on_demand_payout del liquidador el 18/10/2026.
do $datos$
declare v_jose uuid; v_fran uuid; v_juan uuid;
begin
  select p.id into v_jose from plataforma_operador po join perfiles p on p.id = po.perfil_id where p.nombre = 'Jose Menacho';
  select p.id into v_fran from plataforma_operador po join perfiles p on p.id = po.perfil_id where p.nombre = 'Francisco Aguilera';
  select p.id into v_juan from plataforma_operador po join perfiles p on p.id = po.perfil_id where p.nombre = 'Juan Pablo Messmer';
  if v_jose is null or v_fran is null or v_juan is null then
    raise exception '0106: no encontré a los tres socios en plataforma_operador';
  end if;

  -- El cierre del 17/10: 7.212,92 entre los tres, 2.404,31 cada uno.
  if not exists (select 1 from socio_corte) then
    insert into socio_corte (al, ganancia_al, repartido, nota, hecho_por)
    values ('2026-10-17 23:23:36-04', ganancia_al('2026-10-17 23:23:36-04'), 7212.92,
            'Cierre del 17/10 entre José, Francisco y Juan Pablo: 7.212,92 / 3 = 2.404,31 cada uno.',
            v_jose);
  end if;

  -- De José se descuenta sólo su tercio de LÜMEN (decisión del 18/10).
  update retiro_plataforma set socio_id = v_jose
   where referencia = 'ticketazo-1521-1791065103541' and socio_id is null;

  -- El giro del 17/10 23:23 a la BCP de Francisco: la parte de él y la de
  -- Juan Pablo juntas (4.808,61). Dos filas para que cada uno quede en cero.
  if not exists (select 1 from retiro_plataforma where referencia = 'ticketazo-1521-1792279413822') then
    insert into retiro_plataforma (monto, referencia, nota, hecho_por, hecho_at, socio_id) values
      (2404.31, 'ticketazo-1521-1792279413822',
       'Cierre del 17/10: parte de Francisco. Salió en un solo giro de 4.808,61 a su BCP junto con la de Juan Pablo.',
       v_jose, '2026-10-17 23:23:36-04', v_fran),
      (2404.30, 'ticketazo-1521-1792279413822',
       'Cierre del 17/10: parte de Juan Pablo. Salió en un solo giro de 4.808,61 a la BCP de Francisco.',
       v_jose, '2026-10-17 23:23:36-04', v_juan);
  end if;

  -- Un giro que estaba en el liquidador y no acá. Mueve el monedero, no la
  -- cuenta de nadie: los socios decidieron no descontarlo.
  if not exists (select 1 from retiro_plataforma where referencia = 'ticketazo-1521-1790954420288') then
    insert into retiro_plataforma (monto, referencia, nota, hecho_por, hecho_at, socio_id) values
      (142.71, 'ticketazo-1521-1790954420288',
       'Giro a la Ganadero de José del 02/10, junto con el reparto de ese día. No estaba anotado; apareció en el liquidador el 18/10. No se descuenta de la parte de nadie (decisión del 18/10).',
       v_jose, '2026-10-02 15:20:23-04', null);
  end if;
end $datos$;

-- ── control ─────────────────────────────────────────────────
select * from chequeo_funciones_sin_guardia();
