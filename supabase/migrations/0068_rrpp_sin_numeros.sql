-- ============================================================
-- 0068 — hay clientes que no quieren que el relacionador vea sus números
--
-- Hoy el relacionador entra al panel y ve cuántas entradas vendió, cuánto
-- se recaudó por su link y cuánto le toca de comisión. Para el
-- organizador que trabaja con gente de confianza está bien: el
-- relacionador se motiva viendo su número.
--
-- Un cliente pidió lo contrario, y su razón es suya: no quiere que quien
-- reparte links sepa cuánto movió ni cuánto va a cobrar. Es una decisión
-- comercial del organizador sobre su propia gente, no una regla del
-- sistema — por eso es una bandera por organizador y no un cambio para
-- todos.
--
-- ── por qué también se le tapa la lista de compradores ──────
--
-- La tentación es sacar sólo los totales de la pantalla. No sirve: la
-- lista de compradores del relacionador ES el conteo de sus ventas, una
-- fila por compra, y le alcanza con contarlas. Taparle el número de
-- arriba y dejarle la lista abajo es teatro.
--
-- Y taparlo sólo en la pantalla es peor que teatro: las dos funciones se
-- llaman desde el navegador, así que el dato viaja igual y está a un
-- devtools de distancia. El corte va en la base o no va.
--
-- ── lo que el relacionador NUNCA pierde ─────────────────────
--
-- Su link. Es lo único que necesita para trabajar y sigue estando en su
-- pantalla, con su código y listo para copiar. Sin eso no hay a qué
-- entrar.
--
-- Arranca en true: es lo que ven hoy Amstel y sus relacionadores, y
-- cambiarle la pantalla a la gente de otro cliente porque uno pidió algo
-- distinto sería exactamente el error que esta bandera evita.
-- ============================================================

alter table organizadores
  add column if not exists rrpp_ve_ventas boolean not null default true;

comment on column organizadores.rrpp_ve_ventas is
  'Si el relacionador ve sus propios numeros: entradas vendidas, recaudado y comision. En false solo ve su link. Decision comercial de cada organizador sobre su gente.';

-- ── sus ventas ──────────────────────────────────────────────
create or replace function mis_ventas(p_evento uuid default null) returns jsonb
  language plpgsql stable security definer set search_path = public as $function$
declare v_yo uuid := auth.uid();
begin
  if v_yo is null then return '[]'::jsonb; end if;

  -- El corte mira el ROL y no `puede_editar()`: un admin que además vende
  -- por su propio link tiene que seguir viendo lo suyo. Lo que la bandera
  -- apaga es la pantalla del relacionador, no la contabilidad.
  if mi_rol() = 'rrpp'
     and not coalesce((select rrpp_ve_ventas from organizadores
                        where id = mi_organizador()), true) then
    return '[]'::jsonb;
  end if;

  return (
    select coalesce(jsonb_agg(jsonb_build_object(
             'evento_id',         v.evento_id,
             'evento_nombre',     v.evento_nombre,
             'evento_fecha',      v.evento_fecha,
             'entradas',          v.entradas,
             'recaudado',         v.recaudado,
             'comision_unitaria', v.comision_unitaria,
             'comision',          v.comision)
           order by v.comision desc, v.evento_fecha desc), '[]'::jsonb)
      from ventas_rrpp_base(p_evento, v_yo) v);
end $function$;
revoke execute on function mis_ventas(uuid) from anon, public;
grant execute on function mis_ventas(uuid) to authenticated;

comment on function mis_ventas(uuid) is
  'Las ventas del usuario de la sesion, por evento. Vacio para un rrpp cuyo organizador tiene rrpp_ve_ventas en false. No recibe el id de la persona: sale de auth.uid().';

-- ── quien pregunta si el relacionador puede ver lo suyo ─────
-- La pantalla necesita saberlo para decir "tu organizador no muestra
-- estos numeros" en vez de "todavia no vendiste nada", que seria mentira.
drop function if exists mi_organizador_config();
create function mi_organizador_config() returns jsonb
  language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
           'slug',           o.slug,
           'nombre',         o.nombre,
           'rrpp_ve_ventas', o.rrpp_ve_ventas,
           'comision_modo',  o.comision_modo)
    from organizadores o
   where o.id = mi_organizador() and auth.uid() is not null
$$;
revoke execute on function mi_organizador_config() from anon, public;
grant execute on function mi_organizador_config() to authenticated;

comment on function mi_organizador_config() is
  'Lo que la pantalla necesita saber del organizador de quien pregunta. Acotado a mi_organizador(): nadie lee la config de otro.';

-- ── el interruptor, solo admin ──────────────────────────────
drop function if exists guardar_rrpp_ve_ventas(boolean);
create function guardar_rrpp_ve_ventas(p_ve boolean) returns jsonb
  language plpgsql volatile security definer set search_path = public as $function$
declare o organizadores;
begin
  if mi_rol() <> 'admin' then raise exception 'Sin permiso'; end if;
  update organizadores set rrpp_ve_ventas = coalesce(p_ve, true)
   where id = mi_organizador() returning * into o;
  return jsonb_build_object('ok', true, 've', o.rrpp_ve_ventas, 'motivo',
    case when o.rrpp_ve_ventas
      then 'Tus relacionadores vuelven a ver sus entradas y su comisión.'
      else 'Tus relacionadores solo ven su link. No ven ni entradas ni comisión.' end);
end $function$;
revoke execute on function guardar_rrpp_ve_ventas(boolean) from anon, public;
grant execute on function guardar_rrpp_ve_ventas(boolean) to authenticated;
