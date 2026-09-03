/* cuenta — la cuenta del comprador: crearla y guardarle compras.
 *
 * Hace dos cosas, y sólo dos:
 *   crear    — correo + contraseña → usuario en auth.users + sesión abierta.
 *   vincular — "esta compra (uuid) es mía" → ordenes.comprador_user_id.
 *
 * Entrar, refrescar y salir NO pasan por acá: el navegador habla directo
 * con /auth/v1/token y /auth/v1/logout con la anon key, que para eso sí
 * alcanza. Esta función existe porque crear una cuenta necesita la admin
 * API (disable_signup=true: el registro público está cerrado y sigue
 * cerrado — ver 0049) y escribir en ordenes necesita service_role.
 *
 * Un comprador es un usuario SIN fila en `perfiles`. Esa ausencia es la
 * seguridad entera: mi_organizador() y mi_rol() le devuelven null y
 * ninguna policy de staff se le abre. Acá no se crea ningún perfil,
 * nunca. La user_metadata lleva origen:"comprador" para distinguirlo del
 * staff a simple vista en el panel de Supabase, no para autorizar nada.
 *
 * Sin verificación por correo (no hay SMTP) y sin recuperación: si olvidan
 * la contraseña, soporte por WhatsApp la resetea.
 *
 * El JWT no se decodifica —un atob() lee lo que el token DICE sin comprobar
 * quién lo firmó—: se le pregunta a /auth/v1/user, como hace `equipo`.
 *
 * Sin imports remotos: desplegada por la API de gestión no se bundlea, y
 * un `jsr:` o un `esm.sh` la deja en BOOT_ERROR. PostgREST y GoTrue con
 * `fetch` pelado, como las demás.
 *   python3 scripts/desplegar-funciones.py cuenta
 */
const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (b: unknown, s = 200) =>
  new Response(JSON.stringify(b), { status: s, headers: { ...CORS, "Content-Type": "application/json" } });
const mal = (motivo: string, s = 400) => json({ ok: false, motivo }, s);

// service_role: esta función ES el guardián. La anon key no escribe nunca.
const SB   = Deno.env.get("SUPABASE_URL")!;
const KEY  = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
/* La anon key la inyecta el runtime igual que las otras dos. Hace falta
   para dos cosas: abrir la sesión recién creada la cuenta (el token que
   sale de ahí es el del comprador, no uno de service_role) y reconocer
   cuando el Authorization trae la anon key y no un usuario. */
const ANON = Deno.env.get("SUPABASE_ANON_KEY")!;
const H = { apikey: KEY, Authorization: `Bearer ${KEY}`, "Content-Type": "application/json" };

async function rest(ruta: string, init: RequestInit = {}) {
  const r = await fetch(`${SB}/rest/v1/${ruta}`, { ...init, headers: { ...H, ...(init.headers ?? {}) } });
  const t = await r.text();
  const j = t ? JSON.parse(t) : null;
  if (!r.ok) throw new Error(j?.message ?? j?.hint ?? t);
  return j;
}
const uno = async (ruta: string) => (await rest(ruta))?.[0] ?? null;

/* GoTrue tiene su propia API: /auth/v1/admin/... es lo único que puede
   crear una cuenta. Devuelve (código, cuerpo) sin tirar excepción porque
   los errores de acá se traducen uno por uno. */
async function gotrue(ruta: string, metodo = "GET", cuerpo?: unknown) {
  const r = await fetch(`${SB}/auth/v1/${ruta}`, {
    method: metodo, headers: H,
    body: cuerpo === undefined ? undefined : JSON.stringify(cuerpo),
  });
  const t = await r.text();
  let j: any = null;
  try { j = t ? JSON.parse(t) : null; } catch { j = { raw: t }; }
  return { ok: r.ok, code: r.status, cuerpo: j };
}

/* El hash de la IP, no la IP: alcanza para frenar abuso y no guardamos de
   quién es. El mismo de contacto y crear-orden. */
async function hashIp(req: Request) {
  const ip = (req.headers.get("x-forwarded-for") ?? "").split(",")[0].trim() || "sin-ip";
  const b = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(ip + "|ticketera"));
  return Array.from(new Uint8Array(b)).slice(0, 12).map((x) => x.toString(16).padStart(2, "0")).join("");
}

const texto = (v: unknown, max: number) => String(v ?? "").trim().slice(0, max);
/* La misma expresión que valida el correo del comprador en crear-orden:
   con forma de correo alcanza, no hay SMTP para comprobar más. */
const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/;
const UUID_RE  = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/* ── quién llama ──
   El usuario del JWT, o null. La anon key también es un Bearer válido
   para el gateway, pero no es nadie: se descarta antes de preguntar. */
async function usuarioDe(req: Request): Promise<{ id: string; email: string | null } | null> {
  const cab = req.headers.get("Authorization") ?? "";
  const token = /^Bearer\s+(.+)$/i.exec(cab)?.[1]?.trim();
  if (!token || token === ANON) return null;
  const r = await fetch(`${SB}/auth/v1/user`, {
    headers: { apikey: KEY, Authorization: `Bearer ${token}` },
  });
  if (!r.ok) return null;
  const u = await r.json().catch(() => null);
  if (typeof u?.id !== "string" || !UUID_RE.test(u.id)) return null;
  return { id: u.id, email: u.email ?? null };
}

/* ── vincular ──
   El uuid de la orden ES la credencial (la misma regla que la función
   `orden`): impredecible y sólo lo tiene quien compró. Por eso "no
   existe" y "no está pagada" contestan lo mismo — un 404 que no dice cuál
   de las dos — y una pendiente no se puede reclamar hasta que se pague.

   El PATCH lleva `comprador_user_id=is.null` en el filtro: si entre el
   select y el update otra cuenta se la quedó, no pisa nada y devuelve
   cero filas, que acá es un 409. La base es la que decide, no la lectura
   de un momento antes. */
type Vinculo = { status: number; cuerpo: Record<string, unknown> };
const NO_HAY: Vinculo = { status: 404, cuerpo: { ok: false, motivo: "No encontramos esa compra." } };
const DE_OTRO: Vinculo = { status: 409, cuerpo: { ok: false, motivo: "Esa compra ya está guardada en otra cuenta." } };
async function vincular(orden_id: unknown, uid: string): Promise<Vinculo> {
  if (typeof orden_id !== "string" || !UUID_RE.test(orden_id)) return NO_HAY;
  const o = await uno(`ordenes?id=eq.${orden_id}&select=id,estado,comprador_user_id`);
  if (!o || o.estado !== "pagada") return NO_HAY;
  if (o.comprador_user_id === uid) return { status: 200, cuerpo: { ok: true, vinculada: true } };
  if (o.comprador_user_id) return DE_OTRO;
  const filas = await rest(`ordenes?id=eq.${orden_id}&comprador_user_id=is.null&select=id`, {
    method: "PATCH", headers: { Prefer: "return=representation" },
    body: JSON.stringify({ comprador_user_id: uid }),
  });
  if (!filas?.length) return DE_OTRO;
  return { status: 200, cuerpo: { ok: true, vinculada: true } };
}

/* ── abrir la sesión ──
   Con la anon key, como lo haría el navegador: lo que sale es un token
   del comprador y nada más. expires_at viene en segundos de epoch; si
   alguna versión de GoTrue no lo mandara, se arma con expires_in. */
async function iniciarSesion(email: string, password: string) {
  const r = await fetch(`${SB}/auth/v1/token?grant_type=password`, {
    method: "POST",
    headers: { apikey: ANON, "Content-Type": "application/json" },
    body: JSON.stringify({ email, password }),
  });
  const j = await r.json().catch(() => null);
  if (!r.ok || !j?.access_token) return null;
  return {
    access_token:  j.access_token,
    refresh_token: j.refresh_token,
    expires_at:    Number(j.expires_at) || Math.floor(Date.now() / 1000) + (Number(j.expires_in) || 3600),
    user: { id: j.user?.id ?? null, email: j.user?.email ?? email },
  };
}

/* ── crear ──
   El orden importa:
     1. validar: lo que no tiene forma no cuenta como intento;
     2. el tope por IP y el registro del intento, ANTES de tocar auth: así
        el 409 de "ya tiene cuenta" también gasta un intento, y nadie usa
        este endpoint como oráculo para averiguar qué correos tienen
        cuenta probando de a miles;
     3. crear el usuario con la admin API — disable_signup sigue en true,
        esta es la única puerta;
     4. abrir la sesión y, si vino una orden, guardársela.
   Si la orden no se pudo guardar, la cuenta igual queda creada y con
   sesión: `vinculada:false` se lo dice al front, que puede reintentar. */
async function crear(b: any, req: Request) {
  const email    = texto(b.email, 120).toLowerCase();
  const password = String(b.password ?? "");
  const nombre   = texto(b.nombre, 80) || null;

  if (!EMAIL_RE.test(email)) return mal("Escribí un correo válido.");
  if (password.length < 8) return mal("La contraseña tiene que tener al menos 8 caracteres.");
  /* bcrypt no mira más allá de 72 bytes, y las versiones nuevas de GoTrue
     directamente lo rechazan. Mejor decirlo acá, en voseo. */
  if (new TextEncoder().encode(password).length > 72)
    return mal("La contraseña es demasiado larga: hasta 72 caracteres.");

  /* Cinco por hora desde la misma IP. Una persona crea una cuenta; una
     familia, tres; cinco es alguien probando, y de ahí para arriba es un
     script. Se frena sin decir por qué. */
  const ip_hash = await hashIp(req);
  const desde = new Date(Date.now() - 3600_000).toISOString();
  const recientes = await rest(
    `cuenta_intentos?ip_hash=eq.${ip_hash}&creado_at=gte.${encodeURIComponent(desde)}&select=id`,
  );
  if ((recientes ?? []).length >= 5) return mal("Probá de nuevo en un rato.", 429);
  await rest("cuenta_intentos", {
    method: "POST", headers: { Prefer: "return=minimal" },
    body: JSON.stringify({ ip_hash }),
  });

  const alta = await gotrue("admin/users", "POST", {
    email, password, email_confirm: true,
    user_metadata: { origen: "comprador", nombre },
  });
  if (!alta.ok || !alta.cuerpo?.id) {
    const txt = JSON.stringify(alta.cuerpo ?? "");
    /* GoTrue contesta 422 tanto para "ya existe" como para "ese correo no
       me gusta": se distinguen por error_code, no por el status. */
    if (alta.cuerpo?.error_code === "email_exists" || /already been registered/i.test(txt))
      return mal("Ese correo ya tiene cuenta. Entrá con tu contraseña.", 409);
    if (alta.code === 422 || alta.code === 400)
      return mal("Ese correo no sirve para crear una cuenta. Probá con otro.");
    console.error(`cuenta: el alta falló ${alta.code} ${txt.slice(0, 300)}`);
    return mal("No pudimos crear la cuenta. Probá de nuevo.", 502);
  }
  const uid: string = alta.cuerpo.id;

  const sesion = await iniciarSesion(email, password);
  if (!sesion) {
    console.error(`cuenta: ${uid} creado pero no pude abrir la sesión`);
    return mal("La cuenta se creó pero no pudimos abrir la sesión. Entrá con tu correo y contraseña.", 502);
  }

  let vinculada = false;
  if (b.orden_id != null && String(b.orden_id) !== "") {
    try { vinculada = (await vincular(b.orden_id, uid)).status === 200; }
    catch (err) { console.error(`cuenta: no pude vincular ${b.orden_id} a ${uid}: ${err}`); }
  }
  return json({ ok: true, sesion, vinculada });
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return mal("Usá POST.", 405);
  try {
    const b = await req.json().catch(() => ({} as any));
    const accion = String(b?.accion ?? "");

    if (accion === "crear") return await crear(b, req);

    if (accion === "vincular") {
      const u = await usuarioDe(req);
      if (!u) return mal("Entrá a tu cuenta para guardar la compra.", 401);
      const v = await vincular(b.orden_id, u.id);
      return json(v.cuerpo, v.status);
    }

    return mal("No sé qué querés que haga.");
  } catch (err) {
    console.error(`cuenta falló: ${err}`);
    return mal("No se pudo completar. Probá de nuevo.", 500);
  }
});
