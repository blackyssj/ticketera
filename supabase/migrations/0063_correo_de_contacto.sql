-- ============================================================
-- 0063 — el correo de verdad de la gente del equipo
--
-- Hoy un perfil YA tiene un correo, y es una trampa: el alta arma
-- <usuario>@ticketera.local para que GoTrue tenga un identificador con
-- forma de mail. Ese dominio no existe. No recibe nada, no rebota, no
-- avisa: un envío ahí se pierde en silencio.
--
-- Asi que para mandarle a un relacionador su link de venta hay que
-- copiarlo del panel y pegarlo en WhatsApp, uno por uno, cada vez que
-- sale un evento nuevo. Con veinte relacionadores y tres eventos eso es
-- sesenta copiar-y-pegar, y el que se equivoca manda el link de otro —
-- que no falla, vende, y le atribuye la venta a la persona equivocada.
--
-- Esta columna es el dato que falta para poder mandarlo solo.
--
-- ── por que una columna nueva y no reusar auth.users.email ──
-- Porque ese correo es la CREDENCIAL: cambiarlo cambia con que entra la
-- persona al panel. Un dia alguien corrige "el mail de Nico estaba mal"
-- desde una pantalla de contactos y le rompe el acceso sin enterarse.
-- Son dos cosas distintas que solo se parecen en el tipo de dato.
--
-- ── por que nullable ──
-- Porque la mitad del equipo de un cliente no usa correo, usa WhatsApp.
-- Obligarlo llenaria la columna de basura inventada para pasar el
-- formulario, que es peor que no tenerlo: un correo falso parece un
-- correo bueno hasta que el envio se pierde.
--
-- El telefono no entra aca a proposito. WhatsApp no se puede automatizar
-- sin la API de negocios: lo mas que se puede armar es un link wa.me que
-- alguien tiene que tocar igual. Cuando eso este decidido, es otra
-- migracion.
-- ============================================================

alter table perfiles add column if not exists email_contacto text;

-- Un chequeo flojo a proposito. Validar correos "bien" es un pozo sin
-- fondo y termina rechazando direcciones legitimas; lo que si atrapa un
-- check simple es el error real de esta pantalla —un nombre, un telefono
-- o un usuario escrito donde iba el correo— y eso alcanza.
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'perfiles_email_contacto_ck') then
    alter table perfiles add constraint perfiles_email_contacto_ck
      check (email_contacto is null
             or email_contacto ~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$');
  end if;
end $$;

comment on column perfiles.email_contacto is
  'El correo REAL de la persona, para mandarle su link de venta. Distinto de auth.users.email, que es sintetico (<usuario>@ticketera.local) y es con lo que entra al panel: tocar aquel le rompe el acceso. Nullable porque medio equipo usa solo WhatsApp.';

-- Sin indice unico: dos hermanos que comparten el correo de la casa es un
-- caso real, y no hay nada que se rompa si se repite. Un unique aca seria
-- una regla inventada que alguien va a tener que esquivar el dia del
-- evento.
