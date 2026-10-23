-- ============================================================
-- 0111 — la parte de cada socio sale de partes iguales, y la caja manda
--
-- La tarjeta Socios de 0106 le decía a cada uno «te quedan ≈599 Bs» con la
-- caja de ganancia en −287. Las dos cuentas no cerraban entre sí y el panel
-- encima completaba solo «Retiré 598,99 para José»: si los tres retiraban
-- su parte, salían ~1.800 Bs que eran de clientes (LÜMEN, Distrito) que
-- todavía no habían recibido su giro.
--
-- Por qué fallaba: la base de 0106 era el corte del 17/10 (`socio_corte`,
-- 7.212,92 repartidos), y ese corte no contaba el reparto del 02/10. Ese
-- día salió un giro de 2.005,56 a Francisco que era 78 Bs de una devolución
-- más 642,52 para CADA socio; como quedó anotado en una sola fila sin
-- socio, para 0106 era plata de nadie.
--
-- La decisión del 23/10 (José): entre los socios nadie cobró de más.
-- Contando el 02/10, los tres retiraron lo mismo:
--   José        561 + 1.843 + 642,52 = 3.046,52
--   Francisco   2.404,31   + 642,52 = 3.046,83
--   Juan Pablo  2.404,30   + 642,52 = 3.046,82
-- Los giros tempranos a la Ganadero de José (622,29, 573,89 y 142,71) y la
-- devolución de 78 no son de ningún socio: son de los tres por igual.
--
-- ── el modelo ──
--   común     = todo lo retirado − lo cobrado por los socios de hoy
--               (= los retiros sin socio; escrito así, un retiro de un ex
--               socio cae en lo común y la cuenta de abajo no se rompe)
--   le toca   = (ganancia − común) / socios, repartido en CENTAVOS
--   cobró     = suma de sus retiros
--   le queda  = le toca − cobró   (negativo = cobró por adelantado)
--   se puede retirar hoy = max(0, min(le queda, caja))
--
-- Con eso la suma de los «le queda» es ganancia − común − Σcobró =
-- ganancia − retirado, que es EXACTAMENTE el disponible del cuadre de
-- panel_plataforma. Por eso se usan los números de ese cuadre y no
-- ganancia_al(): la ganancia de panel_plataforma redondea por cliente y
-- con otra fuente la igualdad se correría por centavos. Y por eso el
-- reparto va en centavos (el resto, de a un centavo, en orden de nombre):
-- round(x/3, 2) × 3 no siempre da x.
--
-- `socio_corte` queda como historia (no se borra, sigue saliendo en
-- `corte`), pero nada depende de él.
--
-- ── el retiro ──
-- 0106 comparaba el retiro de un socio sólo contra SU parte, con un peso de
-- margen: la base aceptaba los 598,99 con la caja en negativo. Ahora todo
-- retiro se compara contra la caja (ganancia − retirado), y el de un socio
-- además contra lo que le queda. Tolerancia de un centavo: con la caja en
-- el filo, un peso de margen ya es plata de clientes.
--
-- Consecuencia que hay que saber: un giro que ya salió por BeePay y pasa la
-- caja NO se puede anotar desde el panel. Se anota con una migración
-- (regla 3) y la caja queda en negativo a la vista, que es lo que pasó.
-- ============================================================

-- ── la cuenta ──────────────────────────────────────────────
create or replace function socios_plataforma() returns jsonb
  language plpgsql stable security definer set search_path = public as $function$
declare
  v_tot jsonb; v_n int;
  v_ganancia numeric(12,2); v_retirado numeric(12,2); v_disp numeric(12,2);
  v_cobrado numeric(12,2); v_comun numeric(12,2); v_reparto numeric(12,2);
  v_cent bigint; v_base bigint; v_resto int;
  v_ult socio_corte; v_nueva numeric(12,2); v_socios jsonb;
begin
  if not es_plataforma() then raise exception 'Sin permiso'; end if;

  -- Los mismos tres números del cuadre de arriba del panel.
  v_tot      := panel_plataforma()->'total';
  v_ganancia := (v_tot->>'margen')::numeric;
  v_retirado := (v_tot->>'retirado')::numeric;
  v_disp     := (v_tot->>'disponible')::numeric;

  select count(*) into v_n
    from plataforma_operador po join perfiles p on p.id = po.perfil_id and p.activo;

  select coalesce(sum(r.monto), 0) into v_cobrado
    from retiro_plataforma r
   where r.socio_id in (select po.perfil_id from plataforma_operador po
                          join perfiles p on p.id = po.perfil_id and p.activo);
  v_comun   := v_retirado - v_cobrado;
  v_reparto := v_ganancia - v_comun;

  -- En centavos: floor() para todos y el resto, de a uno, a los primeros
  -- por nombre. floor y no trunc: con un reparto negativo trunc deja un
  -- resto negativo y la suma se corre.
  v_cent  := round(v_reparto * 100)::bigint;
  v_base  := floor(v_cent::numeric / greatest(v_n, 1))::bigint;
  v_resto := (v_cent - v_base * greatest(v_n, 1))::int;

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', s.id, 'nombre', s.nombre,
           'le_toca', s.le_toca, 'cobro', s.cobro,
           'queda', s.le_toca - s.cobro,
           'se_puede_hoy', greatest(0, least(s.le_toca - s.cobro, v_disp)))
           order by s.nombre, s.id), '[]'::jsonb)
    into v_socios
    from (select p.id, p.nombre,
                 ((v_base + case when row_number() over (order by p.nombre, p.id) <= v_resto
                                 then 1 else 0 end) / 100.0)::numeric(12,2) as le_toca,
                 (select coalesce(sum(r.monto), 0) from retiro_plataforma r
                   where r.socio_id = p.id)::numeric(12,2) as cobro
            from plataforma_operador po join perfiles p on p.id = po.perfil_id and p.activo) s;

  -- Historia: el último corte y lo ganado desde él, como en 0106.
  select * into v_ult from socio_corte order by al desc limit 1;
  v_nueva := case when v_ult.id is null then v_ganancia else v_ganancia - v_ult.ganancia_al end;

  return jsonb_build_object('ok', true, 'socios', v_socios, 'cantidad', v_n,
    'ganancia', v_ganancia, 'retirado', v_retirado, 'disponible', v_disp,
    'comun', v_comun, 'reparto', v_reparto,
    'ganancia_nueva', v_nueva,
    'corte', case when v_ult.id is null then null else jsonb_build_object(
      'al', v_ult.al, 'repartido', v_ult.repartido, 'ganancia_al', v_ult.ganancia_al,
      'nota', v_ult.nota) end);
end $function$;
revoke execute on function socios_plataforma() from anon, public;
grant execute on function socios_plataforma() to authenticated;

-- ── anotar un retiro: contra la caja siempre, y contra su parte ──
create or replace function registrar_retiro_plataforma(p_monto numeric, p_nota text default null,
                                                       p_referencia text default null, p_socio uuid default null)
  returns jsonb language plpgsql volatile security definer set search_path = public as $function$
declare
  v_id uuid; v_monto numeric(12,2) := round(p_monto, 2);
  s jsonb; v_disp numeric(12,2); v_queda numeric(12,2); v_nombre text;
begin
  if not es_plataforma() then raise exception 'Sin permiso'; end if;
  if v_monto is null or v_monto <= 0 then
    return jsonb_build_object('ok', false, 'motivo', 'El monto tiene que ser mayor a cero.');
  end if;

  -- Dos socios anotando a la vez leerían la misma caja y pasarían los dos.
  perform pg_advisory_xact_lock(hashtext('retiro_plataforma'));

  s := socios_plataforma();
  v_disp := (s->>'disponible')::numeric;

  if v_monto > v_disp + 0.01 then
    return jsonb_build_object('ok', false, 'disponible', v_disp, 'motivo',
      case when v_disp <= 0
        then format('La caja de ganancia está en cero%s: hoy no se puede anotar ningún retiro. Lo que hay en el monedero es plata de clientes.',
                    case when v_disp < 0 then format(' (ya se retiraron %s Bs de más)', -v_disp) else '' end)
        else format('En la caja hay %s Bs de ganancia. No se puede anotar un retiro de %s: lo que hay en el monedero por encima de eso es plata de clientes.',
                    v_disp, v_monto) end);
  end if;

  if p_socio is not null then
    select p.nombre into v_nombre from plataforma_operador po join perfiles p on p.id = po.perfil_id
     where po.perfil_id = p_socio;
    if v_nombre is null then
      return jsonb_build_object('ok', false, 'motivo', 'Ese socio no existe.');
    end if;
    select (x->>'queda')::numeric into v_queda
      from jsonb_array_elements(s->'socios') x where (x->>'id')::uuid = p_socio;
    v_queda := coalesce(v_queda, 0);
    if v_monto > v_queda + 0.01 then
      return jsonb_build_object('ok', false, 'queda', v_queda, 'motivo',
        case when v_queda < 0
          then format('%s ya cobró %s Bs por adelantado: no le queda nada para retirar.', v_nombre, -v_queda)
          when v_queda = 0
          then format('A %s no le queda nada para retirar.', v_nombre)
          else format('A %s le quedan %s Bs; no se puede anotar un retiro de %s.', v_nombre, v_queda, v_monto) end);
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

-- ── el reparto del 02/10, partido en filas ─────────────────
-- Una fila de 2.005,56 sin socio pasa a ser cuatro: 78 de la devolución
-- (de nadie, o sea de los tres) y 642,52 con el socio_id de cada uno. La
-- suma de retiro_plataforma no se mueve: 78 + 3 × 642,52 = 2.005,56. Mismo
-- hecho_at y hecho_por que la original, para que la lista siga contando
-- el día en que salió la plata y no el día en que se ordenó.
-- Idempotente: si ya hay filas de esa referencia con socio, no hace nada.
do $datos$
declare
  v_jose uuid; v_fran uuid; v_juan uuid; o retiro_plataforma;
  v_antes numeric(12,2); v_despues numeric(12,2);
  v_ref constant text := 'SCRUM-PORTAL-20261002-2';
  v_cola constant text := ' Salió en el giro de 2.005,56 a Francisco del 02/10; partido en filas el 23/10 para que la cuenta de cada socio lo cuente.';
begin
  select p.id into v_jose from plataforma_operador po join perfiles p on p.id = po.perfil_id where p.nombre = 'Jose Menacho';
  select p.id into v_fran from plataforma_operador po join perfiles p on p.id = po.perfil_id where p.nombre = 'Francisco Aguilera';
  select p.id into v_juan from plataforma_operador po join perfiles p on p.id = po.perfil_id where p.nombre = 'Juan Pablo Messmer';
  if v_jose is null or v_fran is null or v_juan is null then
    raise exception '0111: no encontré a los tres socios en plataforma_operador';
  end if;

  select coalesce(sum(monto), 0) into v_antes from retiro_plataforma;

  if not exists (select 1 from retiro_plataforma where referencia = v_ref and socio_id is not null) then
    select * into o from retiro_plataforma
     where referencia = v_ref and socio_id is null and monto = 2005.56
     for update;
    if found then
      update retiro_plataforma
         set monto = 78,
             nota = 'Devolución de 78 Bs del reparto del 02/10. No es de ningún socio: es de los tres por igual.'
                    || v_cola || ' Nota original: ' || coalesce(o.nota, '—')
       where id = o.id;
      insert into retiro_plataforma (monto, referencia, nota, hecho_por, hecho_at, socio_id) values
        (642.52, v_ref, 'Reparto del 02/10: parte de José.' || v_cola,       o.hecho_por, o.hecho_at, v_jose),
        (642.52, v_ref, 'Reparto del 02/10: parte de Francisco.' || v_cola,  o.hecho_por, o.hecho_at, v_fran),
        (642.52, v_ref, 'Reparto del 02/10: parte de Juan Pablo.' || v_cola, o.hecho_por, o.hecho_at, v_juan);
    else
      raise notice '0111: no está la fila de 2.005,56 del 02/10 (base nueva o ya tocada a mano); no se parte nada';
    end if;
  end if;

  select coalesce(sum(monto), 0) into v_despues from retiro_plataforma;
  if v_despues <> v_antes then
    raise exception '0111: partir el 02/10 cambió lo retirado (% → %)', v_antes, v_despues;
  end if;
end $datos$;

-- ── control ─────────────────────────────────────────────────
select * from chequeo_funciones_sin_guardia();
