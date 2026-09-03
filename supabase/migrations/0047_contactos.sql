-- 0047 — los que quieren vender con nosotros
--
-- El panel no tiene auto-registro y no lo va a tener: una cuenta de
-- organizador se crea después de una negociación, a mano. Pero el que quiere
-- vender su evento con nosotros necesita cómo pedirlo, y hoy lo único que
-- hay es un botón de WhatsApp — que funciona, salvo que la conversación se
-- pierda entre otras cuarenta.
--
-- Esta tabla es el registro de esos pedidos. No tiene organizador_id porque
-- todavía no hay organizador: es exactamente lo que este pedido quiere
-- llegar a ser.
--
-- Quién lee: NADIE por RLS. Ni siquiera un admin de un organizador — el
-- admin de Amstel no tiene por qué ver que la competencia pidió una
-- cotización. Se leen con service_role, desde `scripts/contactos.py`. El día
-- que haya un panel de la plataforma (distinto del panel de cada cliente),
-- ahí se decide de nuevo.
create table contactos (
  id           uuid primary key default gen_random_uuid(),
  creado_at    timestamptz not null default now(),
  nombre       text not null check (length(trim(nombre)) between 2 and 120),
  contacto     text not null check (length(trim(contacto)) between 5 and 120),
  evento       text check (length(evento) <= 160),
  fecha_evento date,
  lugar        text check (length(lugar) <= 160),
  publico      int  check (publico is null or publico between 0 and 200000),
  mensaje      text check (length(mensaje) <= 1200),
  origen       text not null default 'organizadores'
                    check (origen in ('organizadores','presentacion','otro')),
  ip_hash      text,
  estado       text not null default 'nuevo'
                    check (estado in ('nuevo','contactado','cerrado','descartado')),
  notas        text
);

create index contactos_creado on contactos (creado_at desc);
create index contactos_ip on contactos (ip_hash, creado_at desc);

-- La regla de la casa: `anon` no tiene ni un permiso, y acá `authenticated`
-- tampoco. Escribe la Edge Function con service_role; leer es cosa de
-- service_role y nada más.
alter table contactos enable row level security;
revoke all on contactos from anon, authenticated;
