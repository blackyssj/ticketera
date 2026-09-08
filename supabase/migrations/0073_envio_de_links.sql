-- ============================================================
-- 0073 — a quien ya se le mando su link, y de que evento
--
-- Repartir los links es hoy copiar y pegar del panel a WhatsApp, uno por
-- uno. Con 108 relacionadores y dos eventos son 216 pegadas, y el que se
-- equivoca manda el link de otro: no falla, VENDE, y le atribuye la venta
-- a la persona equivocada. El boton que reparte todo de una necesita
-- saber a quien ya le toco.
--
-- ── por que una fila por (evento, persona) y no una por envio ──
--
-- Porque la pregunta que hay que contestar el segundo dia es "¿a quien le
-- falta?", no "¿cuantas veces apretamos el boton?". Se agregan cinco
-- relacionadores el jueves, se aprieta el boton, y tienen que salir cinco
-- correos y no 113. Con un registro por corrida habria que reconstruir la
-- respuesta cruzando corridas, y esa cuenta se hace mal el dia que
-- alguien reenvia a mano a uno solo.
--
-- El unique (evento_id, perfil_id) ES la regla: una persona, un evento,
-- una fila. Un reenvio forzado pisa `enviado_at` en vez de agregar otra.
-- Lo que se pierde con eso es el historial de reenvios, y no lo
-- necesitamos: nadie audita cuantas veces se le mando un link a alguien.
--
-- ── por que se congela el correo ──
--
-- `correo` guarda la direccion a la que SE MANDO, no la que la persona
-- tiene hoy. Cuando alguien diga "no me llego", la pregunta util es a
-- donde se mando, y si el perfil ya se corrigio desde entonces, mirar
-- perfiles.email_contacto contesta otra pregunta distinta.
-- ============================================================

create table if not exists envio_link (
  id             uuid primary key default gen_random_uuid(),
  organizador_id uuid not null references organizadores on delete restrict,
  -- cascade: si el evento se borra, a quien se le mando su link deja de
  -- ser un dato de nada.
  evento_id      uuid not null references eventos  on delete cascade,
  perfil_id      uuid not null references perfiles(id) on delete cascade,
  correo         text not null,
  enviado_at     timestamptz not null default now(),
  -- Quien apreto el boton. Nullable porque el perfil se puede borrar y la
  -- fila sigue diciendo lo que importa: que a esa persona ya se le mando.
  actor_id       uuid references perfiles(id) on delete set null,
  unique (evento_id, perfil_id)
);

create index if not exists envio_link_evento_idx on envio_link (evento_id);

comment on table envio_link is
  'A que relacionador ya se le mando su link de venta, por evento. Una fila por (evento, persona): un reenvio pisa enviado_at, no agrega otra. La escribe SOLO la Edge Function enviar-links.';
comment on column envio_link.correo is
  'La direccion a la que se mando, congelada. Si despues se corrige el email_contacto del perfil, esta columna sigue contestando "a donde fue" — que es la pregunta cuando alguien dice que no le llego.';

-- ── RLS ──────────────────────────────────────────────────────
-- Leer: el staff de ese organizador, para que la pantalla pueda decir
-- "108 ya lo recibieron, faltan 5". Escribir: nadie desde el navegador.
-- Las filas las pone la Edge Function con service_role, DESPUES de que
-- Resend contesto que acepto el correo: una fila escrita desde el panel
-- diria "ya se le mando" sin que se haya mandado nada, y esa persona
-- nunca mas entraria en la lista de los que faltan.
alter table envio_link enable row level security;
revoke all on envio_link from anon, authenticated;
grant select on envio_link to authenticated;

drop policy if exists "envio_link: los de mi organizador" on envio_link;
create policy "envio_link: los de mi organizador" on envio_link
  for select to authenticated
  using (organizador_id = mi_organizador());
