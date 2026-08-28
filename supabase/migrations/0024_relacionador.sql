-- ============================================================
-- 0024 — el relacionador: su link y su comisión
--
-- El slug va en la URL pública (?r=<slug>), así que es único POR
-- ORGANIZADOR y no global: dos clientes distintos pueden tener cada uno
-- su "nico".
--
-- La comisión es un MONTO FIJO por entrada. En Plataforma Puerta estaba
-- atada al precio y durante siete eventos nadie lo notó, porque con la
-- manilla a 60 y el reparto 50/50 daba justo 15. Cuando la manilla subió a
-- 70 la comisión se fue sola a 17,50 sin que nadie lo decidiera. Por eso
-- comision_de() no toca fase_precio ni ninguna otra tabla de precios: solo
-- lee el acuerdo de la persona y, si no hay, el default del evento.
-- ============================================================

alter table perfiles add column if not exists slug text;
alter table perfiles add column if not exists comision_entrada numeric(12,2);

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'perfiles_slug_uk') then
    alter table perfiles add constraint perfiles_slug_uk unique (organizador_id, slug);
  end if;
  if not exists (select 1 from pg_constraint where conname = 'perfiles_slug_ck') then
    alter table perfiles add constraint perfiles_slug_ck
      check (slug is null or slug ~ '^[a-z0-9-]{2,30}$');
  end if;
end $$;

comment on column perfiles.slug is
  'Lo que va en ?r= del link de venta. Único por organizador, no global.';
comment on column perfiles.comision_entrada is
  'Acuerdo particular de esta persona, en Bs por entrada. Null = usa el del evento.';

alter table eventos add column if not exists comision_entrada numeric(12,2) not null default 15;
comment on column eventos.comision_entrada is
  'Lo que cobra un relacionador por entrada vendida con su link, en Bs.
   Monto fijo: si sube el precio de la entrada, la comisión no se mueve.';

create or replace function comision_de(p_perfil uuid, p_evento uuid) returns numeric
  language sql stable security definer set search_path = public as $$
  select coalesce(
    (select p.comision_entrada from perfiles p where p.id = p_perfil),
    (select e.comision_entrada from eventos e where e.id = p_evento),
    0)
$$;
revoke execute on function comision_de(uuid, uuid) from anon, public;
grant execute on function comision_de(uuid, uuid) to authenticated;
