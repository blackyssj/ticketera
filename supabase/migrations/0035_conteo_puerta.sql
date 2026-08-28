-- ============================================================
-- 0035 — el conteo de la puerta
--
-- A mitad de la noche la pregunta no es cuánto se vendió: es cuánta
-- gente falta entrar. Eso ya lo contesta el bloque `puerta` de
-- resumen_evento() (0033), pero resumen_evento() exige puede_editar() en
-- su primera línea y el portero no lo cumple — es exactamente el punto
-- del rol: no ve recaudación, ni precios, ni el correo del comprador.
-- Darle esa función sería regalarle la caja entera para que pueda leer
-- dos números. Por eso ésta aparte, con lo mínimo y con la guardia
-- ajustada a quien la va a llamar.
--
-- ── se cuenta desde `entradas`, nunca desde `ordenes` ──
-- Un combo de mesa se vende UNA vez y emite una fila de `entradas` por
-- manilla (0016). En la puerta lo que pasa por el molinete son personas,
-- así que contar órdenes diría 1 donde entran 20 y el portero cerraría
-- la noche creyendo que falta medio salón. Misma vara que usa el bloque
-- `puerta` de 0033 y que usa validar_entrada() para consumir: las tres
-- cuentan manillas.
--
-- ── los nombres son los de 0033, a propósito ──
-- `emitidas`, `usadas`, `faltan` y `porcentaje` se llaman igual y se
-- calculan con el mismo filtro que en resumen_evento(). Dos funciones
-- que cuentan lo mismo con nombres distintos es como empiezan a
-- discrepar: alguien toca una, la otra queda vieja, y el tablero del
-- administrador y la pantalla del portero muestran números que no
-- cierran justo la noche en que hay que discutirlos. Si un día cambia el
-- criterio de `emitidas`, que el grep encuentre las dos.
--
-- `anulada` no cuenta como emitida en ninguna de las dos: es una entrada
-- que alguien dio de baja y esperar a esa persona sería esperar a nadie.
--
-- ── el corte de tenant va escrito adentro ──
-- `security definer` significa que las policies NO corren. p_evento
-- llega del navegador y puede ser el uuid de otro cliente, así que sin
-- el chequeo contra mi_organizador() el portero de un boliche lee la
-- puerta de otro. Devuelve vacío —el mismo vacío para "no existe" que
-- para "no es tuyo"— así no sirve de oráculo de qué uuids existen.
--
-- Idempotente: drop con la firma completa antes del create (invariante
-- 4 — dos firmas vivas dejan a PostgREST sin poder elegir y la función
-- queda muerta sin que nada avise).
-- ============================================================

drop function if exists conteo_puerta(uuid);

create or replace function conteo_puerta(p_evento uuid) returns jsonb
  language plpgsql stable security definer set search_path = public as $function$
declare v_org uuid := mi_organizador();
begin
  -- La misma guardia que las tres de 0032. El `if` de la pantalla es
  -- comodidad de interfaz; el que manda es éste.
  if not (es_portero() or puede_editar()) then raise exception 'Sin permiso'; end if;

  if not exists (select 1 from eventos
                  where id = p_evento and organizador_id = v_org) then
    return '{}'::jsonb;
  end if;

  return jsonb_build_object(
    'evento',      p_evento,
    'generado_at', now())
  || (
    select jsonb_build_object(
      'emitidas',   coalesce(count(*) filter (where e.estado <> 'anulada'), 0)::int,
      'usadas',     coalesce(count(*) filter (where e.estado = 'usada'), 0)::int,
      'faltan',     coalesce(count(*) filter (where e.estado = 'valida'), 0)::int,
      'anuladas',   coalesce(count(*) filter (where e.estado = 'anulada'), 0)::int,
      'porcentaje', case when count(*) filter (where e.estado <> 'anulada') = 0
                         then 0::numeric(5,2)
                         else (100.0 * count(*) filter (where e.estado = 'usada')
                               / count(*) filter (where e.estado <> 'anulada'))::numeric(5,2) end,
      -- El ritmo: sirve para saber si la fila todavía está entrando o si
      -- ya entró todo el que iba a entrar. Un número, no una serie: en
      -- la puerta esto se mira de reojo entre dos escaneos.
      'ultima_media_hora',
        coalesce(count(*) filter (where e.estado = 'usada'
                                    and e.used_at > now() - interval '30 minutes'), 0)::int)
      from entradas e
     where e.evento_id = p_evento and e.organizador_id = v_org)
  || jsonb_build_object(
    -- El desglose contesta la otra pregunta de la noche: si lo que falta
    -- entrar son generales sueltas o una mesa de veinte que todavía está
    -- cenando. Sale de `entradas` y no de `tipo_entrada`: un tipo que no
    -- vendió nada no tiene a nadie en la puerta y ocupa una línea de una
    -- pantalla que se mira de reojo.
    'tipos', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'tipo_id',  x.tipo_id,
               'nombre',   x.nombre,
               'emitidas', x.emitidas,
               'usadas',   x.usadas,
               'faltan',   x.faltan)
             order by x.orden, x.nombre), '[]'::jsonb)
        from (
          select e.tipo_id,
                 -- Una entrada sin tipo_id pero con mesa_id es una mesa
                 -- del plano viejo (0005). Se la nombra igual que
                 -- puerta_entrada() en 0032, que ya la muestra como
                 -- "Mesa": dos nombres para la misma fila en dos
                 -- pantallas de la misma puerta no ayuda a nadie.
                 coalesce(t.nombre,
                          case when bool_or(e.mesa_id is not null)
                               then 'Mesa' else 'Sin tipo' end) as nombre,
                 -- Sin `orden` van al final, no primero: el orden del
                 -- catálogo es el que el organizador eligió y una fila
                 -- huérfana no se le puede poner adelante.
                 coalesce(min(t.orden), 2147483647) as orden,
                 count(*) filter (where e.estado <> 'anulada')::int as emitidas,
                 count(*) filter (where e.estado = 'usada')::int    as usadas,
                 count(*) filter (where e.estado = 'valida')::int   as faltan
            from entradas e
            left join tipo_entrada t on t.id = e.tipo_id
           where e.evento_id = p_evento and e.organizador_id = v_org
           group by e.tipo_id, t.nombre
          having count(*) filter (where e.estado <> 'anulada') > 0
        ) x));
end $function$;

revoke execute on function conteo_puerta(uuid) from anon, public;
grant execute on function conteo_puerta(uuid) to authenticated;

comment on function conteo_puerta(uuid) is
  'Cuantas entradas se emitieron y cuantas ingresaron, con el desglose por tipo. Contado desde entradas y no desde ordenes: un combo de mesa emite una fila por manilla y en la puerta lo que importa son personas. Existe aparte de resumen_evento() porque esa exige puede_editar() y el portero no lo cumple; los nombres de los campos que se superponen son los mismos a proposito.';
