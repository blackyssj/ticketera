-- ============================================================
-- 0098 — relacionador por defecto del evento
--
-- La compra que entra sin link de relacionador (desde la cartelera, o con
-- el link del evento pelado) queda "público": nadie cobra comisión por
-- ella. Nocturne pidió el 03/10 que esas ventas vayan a un relacionador
-- fijo de SU evento (José Menacho), en vez de quedar sin dueño.
--
-- `eventos.rrpp_por_defecto` guarda ese relacionador. Un trigger antes de
-- insertar la orden lo pone si la orden llega sin `rrpp_id`. Va al crear
-- la orden y no al pagarla porque `emitir` copia el rrpp de la orden a las
-- entradas ANTES de marcarla pagada: a esa altura ya sería tarde.
--
-- Sólo se usa si el relacionador es del mismo organizador y está activo;
-- si lo dan de baja, las ventas vuelven a quedar "público" sin romper nada.
-- Las que traen link siguen siendo de quien trae el link.
-- ============================================================

alter table eventos
  add column if not exists rrpp_por_defecto uuid references perfiles(id) on delete set null;

-- Sin security definer: la única que inserta órdenes es crear_orden, que ya
-- corre como dueña de las tablas.
create or replace function orden_rrpp_por_defecto() returns trigger
  language plpgsql set search_path = public as $function$
begin
  if new.rrpp_id is null then
    select p.id into new.rrpp_id
      from eventos e
      join perfiles p on p.id = e.rrpp_por_defecto
     where e.id = new.evento_id
       and p.organizador_id = new.organizador_id
       and p.activo;
  end if;
  return new;
end $function$;

-- Es de trigger: nadie la llama a mano. chequeo_funciones_sin_guardia()
-- exige que anon y authenticated no puedan ejecutarla.
revoke all on function orden_rrpp_por_defecto() from public, anon, authenticated;

drop trigger if exists orden_rrpp_por_defecto on ordenes;
create trigger orden_rrpp_por_defecto
  before insert on ordenes
  for each row execute function orden_rrpp_por_defecto();

-- Nocturne Halloween Party → José Menacho.
update eventos e set rrpp_por_defecto = p.id
  from perfiles p, organizadores g
 where g.slug = 'nocturne' and e.organizador_id = g.id and e.slug = 'halloween-party'
   and p.organizador_id = g.id and p.slug = 'jose-menacho' and p.rol = 'rrpp';
