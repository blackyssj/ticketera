/* equipo — la única función del lado interno que crea cuentas.
 *
 * Escribir en `auth.users` necesita service_role, y service_role no puede
 * viajar al navegador: por eso el alta pasa por acá y no por PostgREST.
 *
 * Y justamente por eso esta es la función más peligrosa del sistema: corre
 * con service_role, o sea que la RLS NO la frena. Ella es el guardián.
 * Verifica por su cuenta, en cada llamada y antes de tocar nada:
 *
 *   1. que haya una sesión de verdad — el JWT del Authorization contra
 *      /auth/v1/user, no un id en el cuerpo;
 *   2. que quien llama sea `admin` (no `staff`: puede_editar() incluye a
 *      staff y esto es bastante más que editar un precio);
 *   3. que la persona sobre la que actúa sea de SU MISMO organizador.
 *
 * El `organizador_id` nunca sale del cuerpo del pedido: se resuelve del
 * perfil de quien llama. Si viniera del cliente, cualquier admin daría de
 * alta cuentas adentro del cliente de al lado.
 *
 * El JWT no se decodifica acá. Un atob() del payload lee lo que el token
 * DICE sin comprobar quién lo firmó, y cualquiera se escribe uno que diga
 * que es admin. Se le pregunta a /auth/v1/user, que es el único que tiene
 * la llave para verificar la firma.
 *
 * Sin imports remotos: desplegadas por la API de gestión las funciones no
 * se bundlean, así que un `jsr:` o un `esm.sh` las deja en BOOT_ERROR. Se
 * habla PostgREST y GoTrue con `fetch` pelado, como las otras siete.
 *   python3 scripts/desplegar-funciones.py equipo
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
const SB  = Deno.env.get("SUPABASE_URL")!;
const KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const H = { apikey: KEY, Authorization: `Bearer ${KEY}`, "Content-Type": "application/json" };

async function rest(ruta: string, init: RequestInit = {}) {
  const r = await fetch(`${SB}/rest/v1/${ruta}`, { ...init, headers: { ...H, ...(init.headers ?? {}) } });
  const t = await r.text();
  const j = t ? JSON.parse(t) : null;
  if (!r.ok) throw Object.assign(new Error(j?.message ?? j?.hint ?? t), { pg: j?.code });
  return j;
}
const uno = async (ruta: string) => (await rest(ruta))?.[0] ?? null;

/* GoTrue tiene su propia API: /auth/v1/admin/... es lo único que puede
   crear una cuenta o cambiarle la clave. Devuelve (código, cuerpo) sin
   tirar excepción porque los errores de acá se traducen uno por uno. */
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

const ROLES = ["admin", "staff", "rrpp", "portero"];
/* Las mismas dos expresiones que valida el resto del sistema:
   el usuario, la de scripts/crear-usuario.py; el slug, el check
   perfiles_slug_ck de la migración 0024. Repetirlas acá no es duplicar
   una regla: es no dejar que un caracter raro llegue hasta el mensaje
   crudo de Postgres, que el organizador no puede leer. */
const USUARIO_RE = /^[a-z0-9.-]{3,30}$/;
const SLUG_RE    = /^[a-z0-9-]{2,30}$/;
const UUID_RE    = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/* El correo es sintético, igual que en el script y en la pantalla de
   entrar: <usuario>@ticketera.local. Es un identificador de Supabase, no
   una casilla — no hay recuperación por correo, y eso fue una decisión.
   Por eso la clave se muestra UNA vez y lo único que queda después es
   resetearla. */
const correoDe = (u: string) => `${u}@ticketera.local`;
const usuarioDe = (correo: string) => String(correo || "").split("@")[0];

/* 14 caracteres de [A-Za-z0-9], como crear-usuario.py. El rechazo de los
   bytes >= 248 saca el sesgo del módulo: 256 no es múltiplo de 62 y sin
   esto las primeras ocho letras del alfabeto saldrían un 1,6 % más
   seguido. Es barato y evita tener que explicar por qué no se hizo. */
function claveNueva(largo = 14) {
  const A = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";
  let out = "";
  while (out.length < largo) {
    const b = new Uint8Array(largo * 2);
    crypto.getRandomValues(b);
    for (const x of b) {
      if (x >= 248) continue;
      out += A[x % 62];
      if (out.length === largo) break;
    }
  }
  return out;
}

/* ── la guardia ──
   Devuelve el perfil de quien llama o el motivo por el que no pasa. */
type Guardia = { yo?: any; motivo?: string; status?: number };
async function quienLlama(req: Request): Promise<Guardia> {
  const cab = req.headers.get("Authorization") ?? "";
  const token = /^Bearer\s+(.+)$/i.exec(cab)?.[1]?.trim();
  if (!token) return { motivo: "Entrá de nuevo: no llegó tu sesión.", status: 401 };

  const r = await fetch(`${SB}/auth/v1/user`, {
    headers: { apikey: KEY, Authorization: `Bearer ${token}` },
  });
  if (!r.ok) return { motivo: "Tu sesión venció. Entrá de nuevo.", status: 401 };
  const u = await r.json().catch(() => null);
  if (!u?.id) return { motivo: "Tu sesión venció. Entrá de nuevo.", status: 401 };

  /* El rol y el organizador salen de la base, nunca del token: el JWT no
     los lleva, y si algún día los llevara seguirían siendo lo que el token
     dice y no lo que la base sabe. */
  const yo = await uno(`perfiles?id=eq.${u.id}&select=id,nombre,rol,activo,organizador_id`);
  if (!yo || !yo.activo) return { motivo: "Tu cuenta no está habilitada.", status: 403 };
  if (yo.rol !== "admin") return {
    motivo: "Solo un administrador puede administrar el equipo.", status: 403 };
  return { yo };
}

/* La persona sobre la que se actúa tiene que ser del organizador de quien
   llama. "No existe" y "es de otro cliente" contestan LO MISMO a propósito:
   si contestaran distinto, esta función sería un oráculo para averiguar qué
   uuids hay en la base del vecino. */
type Objetivo = { objetivo?: any; motivo?: string; status?: number };
async function objetivoDe(id: unknown, yo: any): Promise<Objetivo> {
  if (typeof id !== "string" || !UUID_RE.test(id))
    return { motivo: "Esa persona no es de tu equipo.", status: 404 };
  const p = await uno(`perfiles?id=eq.${id}&select=id,nombre,rol,activo,slug,organizador_id`);
  if (!p || p.organizador_id !== yo.organizador_id)
    return { motivo: "Esa persona no es de tu equipo.", status: 404 };
  return { objetivo: p };
}

/* ── alta ──
   El orden es el de crear-usuario.py, con una diferencia: si el perfil no
   entra, la cuenta de auth se borra. El script deja el huérfano y lo
   avisa por pantalla, que está bien cuando hay una terminal del otro
   lado; acá no la hay, y un huérfano deja el usuario tomado para
   siempre — el segundo intento fallaría con "ya existe" sin que nadie
   pueda destrabarlo. Esta pantalla existe justamente para no depender de
   una terminal. */
async function crear(b: any, yo: any) {
  const usuario = String(b.usuario ?? "").trim().toLowerCase();
  const nombre  = String(b.nombre ?? "").trim();
  const rol     = String(b.rol ?? "").trim();
  const slug    = b.slug == null || String(b.slug).trim() === ""
    ? null : String(b.slug).trim().toLowerCase();

  if (!USUARIO_RE.test(usuario)) return mal(
    "El usuario va en minúsculas, entre 3 y 30 caracteres, y solo admite letras, números, '.' y '-'.");
  if (!nombre || nombre.length > 80) return mal("Falta el nombre (hasta 80 caracteres).");
  if (!ROLES.includes(rol)) return mal("Ese rol no existe.");
  if (slug !== null && !SLUG_RE.test(slug)) return mal(
    "El código del relacionador va en minúsculas, entre 2 y 30 caracteres, y solo admite letras, números y '-'.");

  const comision = normalizarComision(b.comision_entrada);
  if (comision === false) return mal(
    "La comisión es un monto en Bs por entrada: un número de 0 para arriba, o vacío.");

  /* El unique de 0024 es (organizador_id, slug), así que este chequeo
     mira SOLO adentro del organizador de quien llama: el mismo 'nico' en
     otro cliente tiene que poder existir. Es una cortesía, no la
     garantía — entre este select y el insert puede entrar otro. La
     garantía es el constraint, y su 23505 se traduce más abajo. */
  if (slug) {
    const choca = await uno(
      `perfiles?organizador_id=eq.${yo.organizador_id}&slug=eq.${encodeURIComponent(slug)}&select=id,nombre`);
    if (choca) return json({ ok: false,
      motivo: `Ya hay alguien con el código "${slug}" en tu equipo (${choca.nombre}). Elegí otro.` }, 409);
  }

  const clave = claveNueva();
  const alta = await gotrue("admin/users", "POST", {
    email: correoDe(usuario), password: clave, email_confirm: true,
  });
  if (!alta.ok || !alta.cuerpo?.id) {
    const txt = JSON.stringify(alta.cuerpo ?? "");
    if (alta.code === 422 || /already/i.test(txt)) return json({ ok: false,
      motivo: `El usuario "${usuario}" ya está tomado. Probá con otro.` }, 409);
    return mal("No pude crear la cuenta: " + (alta.cuerpo?.msg ?? alta.cuerpo?.message ?? txt.slice(0, 200)), 502);
  }
  const uid = alta.cuerpo.id;

  try {
    const fila = await rest("perfiles", {
      method: "POST",
      headers: { Prefer: "return=representation" },
      body: JSON.stringify({
        id: uid, organizador_id: yo.organizador_id, nombre, rol,
        slug, comision_entrada: comision,
      }),
    });
    return json({ ok: true, usuario, clave, perfil: fila?.[0] ?? null });
  } catch (err) {
    await gotrue(`admin/users/${uid}`, "DELETE");   // sin perfil no queda nadie a medias
    const e = err as any;
    if (e.pg === "23505") return json({ ok: false,
      motivo: `Ya hay alguien con el código "${slug}" en tu equipo. Elegí otro.` }, 409);
    return mal("No pude crear el perfil, así que deshice la cuenta: " + String(e.message).slice(0, 200), 500);
  }
}

/* Vacío es un dato: "usá el default del evento". Por eso null y 0 no son
   lo mismo — 0 es un acuerdo de no pagar comisión, y comision_de() lo
   respeta. Y siempre un MONTO en Bs, nunca un porcentaje (ver 0024). */
function normalizarComision(v: unknown): number | null | false {
  if (v == null || String(v).trim() === "") return null;
  const n = Number(v);
  if (!Number.isFinite(n) || n < 0 || n > 100000) return false;
  return Math.round(n * 100) / 100;
}

/* ── resetear la clave ──
   La nueva se devuelve una sola vez y no se guarda en ningún lado: no hay
   correo de recuperación, así que lo único que existe es esta respuesta. */
async function resetear(objetivo: any) {
  const clave = claveNueva();
  const r = await gotrue(`admin/users/${objetivo.id}`, "PUT", { password: clave });
  if (!r.ok) return mal("No pude cambiar la clave: " +
    (r.cuerpo?.msg ?? r.cuerpo?.message ?? "").slice(0, 200), 502);
  return json({ ok: true, usuario: usuarioDe(r.cuerpo?.email), clave });
}

/* ── desactivar y reactivar ──
   Desactivar, nunca borrar: una persona con ventas hechas no se puede
   borrar sin romper el historial de comisiones, y a la primera discusión
   con un relacionador te quedaste sin la prueba de cuánto vendió.
   No hace falta cerrarle la sesión: mi_rol() y mi_organizador() (0002)
   filtran por `activo`, así que su token deja de abrir puertas en el acto,
   y cargarPerfil() lo saca del panel apenas recarga. */
async function activo(b: any, objetivo: any, yo: any) {
  const v = b.activo === true || b.activo === "true";
  if (!v && objetivo.id === yo.id) return json({ ok: false,
    motivo: "No podés desactivarte a vos mismo: el organizador se quedaría sin ningún administrador y sin forma de recuperar la cuenta." }, 403);
  const fila = await rest(`perfiles?id=eq.${objetivo.id}`, {
    method: "PATCH", headers: { Prefer: "return=representation" },
    body: JSON.stringify({ activo: v }),
  });
  return json({ ok: true, perfil: fila?.[0] ?? null });
}

/* ── cambiar el rol ──
   Con estas dos guardias juntas —no te desactivás y no te cambiás el rol—
   un organizador no puede quedarse sin admin: el último que queda es
   siempre el que está llamando, y a sí mismo no se toca.
   El slug NO se borra al salir de rrpp: si mañana vuelve, su link es el
   mismo y las ventas viejas siguen diciendo de quién fueron. */
async function cambiarRol(b: any, objetivo: any, yo: any) {
  const rol = String(b.rol ?? "").trim();
  if (!ROLES.includes(rol)) return mal("Ese rol no existe.");
  if (objetivo.id === yo.id) return json({ ok: false,
    motivo: "No podés cambiarte el rol a vos mismo. Pedíselo a otro administrador." }, 403);
  const fila = await rest(`perfiles?id=eq.${objetivo.id}`, {
    method: "PATCH", headers: { Prefer: "return=representation" },
    body: JSON.stringify({ rol }),
  });
  return json({ ok: true, perfil: fila?.[0] ?? null });
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return mal("Método no permitido.", 405);
  try {
    const g = await quienLlama(req);
    if (!g.yo) return mal(g.motivo!, g.status!);
    const yo = g.yo;

    const b = await req.json().catch(() => ({} as any));
    /* Si vino un organizador_id en el cuerpo, se ignora sin decir nada:
       el único que vale es el del perfil de quien llama. */
    const accion = String(b.accion ?? "");

    if (accion === "crear") return await crear(b, yo);

    if (accion === "resetear" || accion === "activo" || accion === "rol") {
      const o = await objetivoDe(b.id, yo);
      if (!o.objetivo) return mal(o.motivo!, o.status!);
      if (accion === "resetear") return await resetear(o.objetivo);
      if (accion === "activo")   return await activo(b, o.objetivo, yo);
      return await cambiarRol(b, o.objetivo, yo);
    }

    return mal("No sé qué querés que haga.");
  } catch (err) {
    return mal(String((err as Error).message ?? err), 500);
  }
});
