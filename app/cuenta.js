/* ══════════════════════════════════════════════════════════════════
   CUENTA — la cuenta del comprador, del lado del navegador.

   `window.Cuenta` es lo único que exporta. Lo cargan evento.html (pantalla
   "listo"), /orden (guardar la compra) y /mis-entradas (entrar, crear,
   listar). Sin dependencias: config.js antes, y nada más.

   Qué es una cuenta acá: correo + contraseña, y punto. SIN verificación por
   correo, porque no hay SMTP configurado en el proyecto y prometer un mail
   que no sale sería dejar a la gente esperando un link que nunca llega. Por
   lo mismo no hay "olvidé mi contraseña": la resetea soporte por WhatsApp.
   El día que haya correo, las dos cosas se agregan acá y en la función.

   Qué hace cada cosa y por dónde va:
     crear / vincular  → Edge Function `cuenta` (necesitan service_role:
                         crear un usuario con el registro público cerrado y
                         escribir en `ordenes`; ninguna de las dos la puede
                         hacer el navegador con la anon key).
     entrar / refresh / salir → DIRECTO contra /auth/v1 con la anon key. Para
                         eso la anon key alcanza y meter una función en el
                         medio sería un salto más para nada.
     misCompras        → RPC mis_compras() con el JWT del comprador: la base
                         devuelve SUS órdenes pagadas y ni una fila más.

   La sesión vive en localStorage bajo `ticketazo.sesion`, SEPARADA de la
   clave que usa supabase-js en el panel (/admin). A propósito: son dos
   personas distintas —el organizador que administra y el que compró una
   entrada— y si compartieran la clave, entrar al panel pisaría la sesión
   del comprador o al revés, y un comprador podría encontrarse con el JWT
   de un staff en su navegador. Cada uno con la suya.

   Errores: siempre un `Error` con mensaje en voseo listo para mostrar (el
   `motivo` del servidor si vino), y `err.status` con el código HTTP para
   que quien llama distinga un 409 ("ya tiene cuenta") de un 401.
   ══════════════════════════════════════════════════════════════════ */
(() => {
"use strict";

const CFG  = window.CONFIG || {};
const SB   = CFG.SUPABASE_URL || "";
const ANON = CFG.SUPABASE_ANON_KEY || "";
const KEY  = "ticketazo.sesion";

/* A cuántos segundos del vencimiento se refresca. El JWT dura una hora; si
   se lo usara hasta el último segundo, el pedido que sale a los 59:59 llega
   al servidor vencido y falla por un segundo de reloj. Sesenta segundos es
   más que cualquier reloj corrido entre este aparato y Supabase, y menos
   que lo que dura una compra. */
const MARGEN_S = 60;
const SIN_RED  = "Sin conexión. Revisá tu internet y volvé a intentar.";

const ahora = () => Math.floor(Date.now() / 1000);
const fallo = (msg, status) => { const e = new Error(msg); e.status = status || 0; return e; };

/* ── la sesión guardada ──
   Se lee sin confiar: la clave la puede haber escrito una versión vieja,
   otra pestaña, o nadie. Cualquier cosa que no tenga la forma exacta vale
   como "no hay sesión", nunca como una excepción que tumbe la página. */
function sesion() {
  try {
    const s = JSON.parse(localStorage.getItem(KEY) || "null");
    if (!s || typeof s !== "object") return null;
    if (typeof s.access_token !== "string" || !s.access_token) return null;
    if (typeof s.refresh_token !== "string" || !s.refresh_token) return null;
    if (!Number.isFinite(Number(s.expires_at))) return null;
    const u = s.user && typeof s.user === "object" ? s.user : {};
    return {
      access_token:  s.access_token,
      refresh_token: s.refresh_token,
      expires_at:    Number(s.expires_at),
      user: { id: u.id ?? null, email: u.email ?? null },
    };
  } catch { return null; }
}
function guardar(s) {
  try { localStorage.setItem(KEY, JSON.stringify(s)); } catch { /* storage bloqueado: la sesión dura la página */ }
}
function borrar() {
  try { localStorage.removeItem(KEY); } catch { /* ídem */ }
}

/* Lo que devuelve GoTrue (login o refresh) a la forma del contrato.
   `expires_at` viene en segundos de epoch; si alguna versión no lo mandara,
   se arma con `expires_in`, que sí viene siempre. */
function normalizar(j, emailRespaldo) {
  return {
    access_token:  j.access_token,
    refresh_token: j.refresh_token,
    expires_at:    Number(j.expires_at) || (ahora() + (Number(j.expires_in) || 3600)),
    user: { id: j.user?.id ?? null, email: j.user?.email ?? emailRespaldo ?? null },
  };
}

/* ── hablar con /auth/v1 ──
   Devuelve (ok, status, cuerpo) sin tirar por el status: los errores de
   GoTrue se traducen uno por uno donde se llama. Sólo tira si no hubo
   respuesta —sin red, DNS caído, CORS—, y eso es otra cosa. */
async function auth(ruta, cuerpo, token) {
  let r;
  try {
    r = await fetch(`${SB}/auth/v1/${ruta}`, {
      method: "POST",
      headers: { apikey: ANON, "Content-Type": "application/json",
                 ...(token ? { Authorization: `Bearer ${token}` } : {}) },
      body: JSON.stringify(cuerpo || {}),
    });
  } catch { throw fallo(SIN_RED, 0); }
  const t = await r.text();
  let j = null;
  try { j = t ? JSON.parse(t) : null; } catch { /* la reja del gateway no contesta JSON */ }
  return { ok: r.ok, status: r.status, cuerpo: j };
}
/* GoTrue tiene dos formatos de error según la versión: {msg} y
   {error_description}. Se leen los dos. */
const motivoAuth = j => j?.msg || j?.error_description || j?.error || "";

/* ── el token vigente ──
   Lo que usan las llamadas con sesión. Si queda menos de MARGEN_S, se
   refresca ANTES de usarlo y se guarda el nuevo par. Un solo refresh a la
   vez (`refrescando`): el refresh_token es de un solo uso y dos pedidos
   simultáneos —mis-compras y un vincular, digamos— gastarían el mismo
   token dos veces y el segundo perdería la sesión sin motivo.

   Si GoTrue rechaza el refresh (venció de verdad, lo revocaron, es basura)
   la sesión se borra y se devuelve null: ya no hay a quién representar.
   Si en cambio no hubo RESPUESTA, la sesión no está muerta, la red sí: se
   deja como está y se tira SIN_RED, para no desloguear a alguien por pasar
   por un túnel. */
let refrescando = null;
async function token() {
  const s = sesion();
  if (!s) return null;
  if (s.expires_at - ahora() > MARGEN_S) return s.access_token;
  if (!refrescando) refrescando = refrescar(s).finally(() => { refrescando = null; });
  return refrescando;
}
async function refrescar(s) {
  const r = await auth("token?grant_type=refresh_token", { refresh_token: s.refresh_token });
  if (!r.ok || !r.cuerpo?.access_token) { borrar(); return null; }
  /* Si mientras el refresh viajaba alguien apretó Salir (acá o en otra
     pestaña), el par nuevo no se guarda: sería revivir una sesión que la
     persona acaba de cerrar, y con un JWT que dura una hora más. */
  if (!sesion()) return null;
  const nueva = normalizar(r.cuerpo, s.user.email);
  guardar(nueva);
  return nueva.access_token;
}

/* ── la Edge Function `cuenta` ──
   Con el JWT del comprador cuando hay (vincular lo exige); con la anon key
   cuando no (crear). El `motivo` del cuerpo es el mensaje aunque el status
   no sea 2xx: para eso lo escribe la función en voseo. */
async function fn(cuerpo, tok) {
  let r;
  try {
    r = await fetch(`${SB}/functions/v1/cuenta`, {
      method: "POST",
      headers: { apikey: ANON, "Content-Type": "application/json",
                 Authorization: `Bearer ${tok || ANON}` },
      body: JSON.stringify(cuerpo || {}),
    });
  } catch { throw fallo(SIN_RED, 0); }
  const t = await r.text();
  let j = null;
  try { j = t ? JSON.parse(t) : null; } catch { /* no JSON */ }
  if (!j) throw fallo(`No se pudo completar (${r.status}).`, r.status);
  if (j.ok === false || !r.ok) throw fallo(j.motivo || "No se pudo completar. Probá de nuevo.", r.status);
  return j;
}

/* ── entrar ──
   Directo contra GoTrue. Un 400 acá es "credenciales inválidas" y se dice
   así, sin distinguir si falló el correo o la clave: decirlo sería regalar
   qué correos tienen cuenta. */
async function entrar(email, password) {
  const r = await auth("token?grant_type=password",
                       { email: String(email || "").trim().toLowerCase(), password: String(password || "") });
  if (!r.ok || !r.cuerpo?.access_token) {
    if (r.status === 400 || r.status === 401) throw fallo("Correo o contraseña incorrectos.", r.status);
    if (r.status === 429) throw fallo("Demasiados intentos. Probá de nuevo en un rato.", 429);
    throw fallo(motivoAuth(r.cuerpo) || "No pudimos abrir la sesión. Probá de nuevo.", r.status);
  }
  guardar(normalizar(r.cuerpo, email));
  return sesion();
}

/* ── crear ──
   La función crea el usuario, abre la sesión y —si vino orden_id— guarda
   esa compra en la cuenta nueva. Devuelve la sesión ya guardada y si la
   compra quedó vinculada; un 409 (ese correo ya tiene cuenta) llega como
   Error con status 409 para que la pantalla cambie a "Entrar". */
async function crear({ email, password, nombre, orden_id } = {}) {
  const j = await fn({ accion: "crear",
                       email: String(email || "").trim().toLowerCase(),
                       password: String(password || ""),
                       nombre: nombre || undefined,
                       orden_id: orden_id || undefined });
  if (!j.sesion?.access_token) throw fallo("La cuenta se creó pero no pudimos abrir la sesión. Entrá con tu correo y contraseña.", 502);
  guardar(normalizar(j.sesion, email));
  return { sesion: sesion(), vinculada: j.vinculada === true };
}

/* ── vincular ──
   "Esta compra es mía." Idempotente: si ya era mía, la función contesta
   ok igual. Sin sesión no se intenta: 401 con el mismo texto que daría el
   servidor, sin gastar el viaje. */
async function vincular(orden_id) {
  const t = await token();
  if (!t) throw fallo("Entrá a tu cuenta para guardar la compra.", 401);
  const j = await fn({ accion: "vincular", orden_id }, t);
  return j.vinculada === true;
}

/* ── salir ──
   Primero se borra lo local, después se avisa al servidor. En ese orden y
   sin esperar la respuesta: salir tiene que funcionar aunque no haya red,
   y el logout remoto es cortesía (revoca el refresh_token), no requisito. */
async function salir() {
  const s = sesion();
  borrar();
  if (s) auth("logout", {}, s.access_token).catch(() => {});
}

/* ── mis compras ──
   La única ventana del comprador a la base: mis_compras() (0049) corre
   como security definer y filtra por auth.uid(). Devuelve el array tal
   cual lo arma la función; acá sólo se garantiza que sea un array. Un 401
   con un token que acabamos de dar por vigente es una sesión que el
   servidor ya no reconoce (usuario borrado, token revocado): se cierra
   acá también, para que la pantalla vuelva al formulario en vez de
   quedarse en un error que se repite. */
async function misCompras() {
  const t = await token();
  if (!t) throw fallo("Entrá a tu cuenta para ver tus compras.", 401);
  let r;
  try {
    r = await fetch(`${SB}/rest/v1/rpc/mis_compras`, {
      method: "POST",
      headers: { apikey: ANON, Authorization: `Bearer ${t}`, "Content-Type": "application/json" },
      body: "{}",
    });
  } catch { throw fallo(SIN_RED, 0); }
  if (r.status === 401) { borrar(); throw fallo("Tu sesión venció. Entrá de nuevo.", 401); }
  if (!r.ok) throw fallo(`No pudimos traer tus compras (${r.status}).`, r.status);
  const j = await r.json().catch(() => null);
  return Array.isArray(j) ? j : [];
}

window.Cuenta = { sesion, token, entrar, crear, vincular, salir, misCompras };
})();
