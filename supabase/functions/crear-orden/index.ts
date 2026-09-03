/* crear-orden — el único camino de escritura del público.
   Corre con service_role, así que valida TODO antes de tocar la base: el
   evento se resuelve por slug y jamás se acepta un evento_id del cliente.
   La idempotencia la pone crear_orden(), por client_key. */
const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, GET, OPTIONS",
};
const json = (b: unknown, s = 200) =>
  new Response(JSON.stringify(b), { status: s, headers: { ...CORS, "Content-Type": "application/json" } });

// service_role: estas funciones SON el guardián. La anon key no escribe nunca.
const SB  = Deno.env.get("SUPABASE_URL")!;
const KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const H = { apikey: KEY, Authorization: `Bearer ${KEY}`, "Content-Type": "application/json" };
/* La anon key la inyecta el runtime igual que las otras dos. Sirve para
   reconocer cuándo el Authorization trae la anon key (un comprador sin
   cuenta) y cuándo trae el JWT de un comprador logueado. */
const ANON = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

async function rest(ruta: string, init: RequestInit = {}) {
  const r = await fetch(`${SB}/rest/v1/${ruta}`, { ...init, headers: { ...H, ...(init.headers ?? {}) } });
  const t = await r.text();
  const j = t ? JSON.parse(t) : null;
  if (!r.ok) throw new Error(j?.message ?? j?.hint ?? t);
  return j;
}
const uno = async (ruta: string) => (await rest(ruta))?.[0] ?? null;
const rpc = (fn: string, args: Record<string, unknown>) =>
  rest(`rpc/${fn}`, { method: "POST", body: JSON.stringify(args) });

const q = (s: string) => encodeURIComponent(s);

/* El hash de la IP, no la IP: alcanza para frenar abuso y no guardamos de
   quién es. Va a `ordenes.ip_hash`. */
async function hashIp(req: Request) {
  const ip = (req.headers.get("x-forwarded-for") ?? "").split(",")[0].trim() || "sin-ip";
  const b = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(ip + "|ticketera"));
  return Array.from(new Uint8Array(b)).slice(0, 12).map((x) => x.toString(16).padStart(2, "0")).join("");
}

/* ── el comprador logueado ──
   Si el comprador ya tiene cuenta (0049), el navegador manda su JWT en el
   Authorization en vez de la anon key, y la orden nace con dueño: aparece
   en "mis compras" sin que tenga que guardarla a mano después.

   El token se verifica contra /auth/v1/user y no se decodifica — un atob()
   lee lo que el token DICE sin comprobar quién lo firmó. Y si no vale
   (venció, es basura, es la anon key), la respuesta es null y la compra
   sigue EXACTAMENTE igual que sin cuenta: nunca se rechaza una venta por
   un problema de sesión. Por eso tampoco tira: cualquier error acá es
   "no hay comprador logueado". */
async function compradorLogueado(req: Request): Promise<string | null> {
  const cab = req.headers.get("Authorization") ?? "";
  const token = /^Bearer\s+(.+)$/i.exec(cab)?.[1]?.trim();
  if (!token || token === ANON) return null;
  try {
    const r = await fetch(`${SB}/auth/v1/user`, {
      headers: { apikey: KEY, Authorization: `Bearer ${token}` },
    });
    if (!r.ok) return null;
    const u = await r.json().catch(() => null);
    return typeof u?.id === "string" && UUID_RE.test(u.id) ? u.id : null;
  } catch {
    return null;
  }
}

/* Los errores de la base salen con prefijo (SIN_CUPO:, MESA_TOMADA:, …).
   El comprador no tiene por qué leer eso. */
function traducir(m: string) {
  if (m.includes("SIN_CUPO")) return "Se acabaron las entradas de ese tipo mientras elegías.";
  if (m.includes("MESA_TOMADA")) return "Alguien tomó esa mesa hace un momento. Elegí otra.";
  if (m.includes("TOPE:")) return "Pasaste el máximo de entradas por compra.";
  if (m.includes("DEMASIADAS_ORDENES")) return "Tenés varias compras sin terminar. Cerrá alguna y volvé a intentar.";
  if (m.includes("EVENTO_NO_PUBLICADO")) return "El evento todavía no está a la venta.";
  if (m.includes("SIN_FASE")) return "No hay ninguna fase de venta abierta.";
  if (m.includes("TIPO_NO_VENDIBLE")) return "Ese tipo de entrada no se vende en esta fase.";
  return "No se pudo reservar. Probá de nuevo.";
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ ok: false, motivo: "Usá POST." }, 405);
  try {
    const b = await req.json();
    const { organizador, evento, items, comprador, client_key } = b ?? {};
    if (!organizador || !evento) return json({ ok: false, motivo: "Falta organizador o evento." }, 400);
    if (!Array.isArray(items) || items.length === 0)
      return json({ ok: false, motivo: "No elegiste nada." }, 400);
    if (items.length > 30) return json({ ok: false, motivo: "Demasiados ítems en una compra." }, 400);

    const nombre = String(comprador?.nombre ?? "").trim().slice(0, 80);
    const email  = String(comprador?.email  ?? "").trim().slice(0, 120);
    if (nombre.length < 3) return json({ ok: false, motivo: "Falta el nombre del comprador." }, 400);
    if (!/^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/.test(email))
      return json({ ok: false, motivo: "El correo no es válido." }, 400);
    /* Los términos se aceptan por orden, no por comprador: lo que vale es la
       versión vigente cuando se compró. El front manda la versión que mostró;
       si no viene, la compra no sigue —una orden sin aceptación registrada no
       sirve el día que haya que probarla. La versión se guarda tal cual llega
       (texto corto) para que un cambio de términos no reescriba la historia. */
    const tc = String(b?.tc ?? "").trim().slice(0, 40);
    if (!tc) return json({ ok: false, motivo: "Tenés que aceptar los términos para seguir." }, 400);

    const o = await uno(`organizadores?slug=eq.${q(organizador)}&activo=is.true&select=id`);
    if (!o) return json({ ok: false, motivo: "Ese organizador no existe." }, 404);
    const e = await uno(`eventos?organizador_id=eq.${o.id}&slug=eq.${q(evento)}&select=id`);
    if (!e) return json({ ok: false, motivo: "Ese evento no existe." }, 404);

    // La atribución la resuelve el servidor. El navegador manda un slug, no
    // un id: si mandara el id, cualquiera con la consola abierta se
    // acreditaría las ventas de otro. Y se busca dentro del organizador del
    // evento, porque el mismo slug puede existir en otro tenant.
    let rrpp_id: string | null = null;
    const r = String(b.r ?? "").trim().toLowerCase();
    if (r && /^[a-z0-9-]{2,30}$/.test(r)) {
      const p = await uno(
        `perfiles?organizador_id=eq.${o.id}&slug=eq.${q(r)}&activo=is.true&select=id`);
      rrpp_id = p?.id ?? null;   // un slug que no existe no rompe la venta
    }

    const limpios = items.map((it) => it.mesa_id
      ? { mesa_id: String(it.mesa_id) }
      : { tipo_id: String(it.tipo_id), cantidad: Math.max(1, Math.min(50, Number(it.cantidad) || 1)) });

    let data;
    try {
      data = await rpc("crear_orden", {
        p_evento: e.id, p_items: limpios,
        p_comprador: { nombre, email, telefono: String(comprador?.telefono ?? "").slice(0, 30) },
        p_client_key: client_key ?? null, p_ip_hash: await hashIp(req), p_rrpp: rrpp_id,
      });
    } catch (err) {
      return json({ ok: false, motivo: traducir(String((err as Error).message)) }, 409);
    }

    /* El vínculo con la cuenta, si la hay. Va acá y no después del camino
       gratis para que una entrada de Bs 0 también quede guardada. Sólo si
       la orden todavía no tiene dueño: crear_orden es idempotente por
       client_key y puede devolver una orden que ya existía. Si el PATCH
       falla, la compra sigue: el comprador la puede guardar después con
       `vincular`, y una venta no se pierde por un vínculo. */
    if (data?.ok && data.orden) {
      /* La aceptación va en un PATCH aparte y no dentro de crear_orden para no
         tocar la firma de la RPC (0046). Sólo se escribe si la orden es nueva
         (tc_version aún nulo): crear_orden es idempotente por client_key. */
      try {
        await rest(`ordenes?id=eq.${data.orden}&tc_version=is.null`, {
          method: "PATCH", headers: { Prefer: "return=minimal" },
          body: JSON.stringify({ tc_version: tc, tc_aceptado_at: new Date().toISOString() }),
        });
      } catch (err) {
        console.error(`no se pudo registrar la aceptación en la orden ${data.orden}: ${err}`);
      }
      const uid = await compradorLogueado(req);
      if (uid) {
        try {
          await rest(`ordenes?id=eq.${data.orden}&comprador_user_id=is.null`, {
            method: "PATCH", headers: { Prefer: "return=minimal" },
            body: JSON.stringify({ comprador_user_id: uid }),
          });
        } catch (err) {
          console.error(`no se pudo vincular la orden ${data.orden} al comprador ${uid}: ${err}`);
        }
      }
    }

    /* Evento gratis. Si no hay nada que cobrar no hay pasarela que abrir: se
       emite acá mismo y el comprador salta del formulario a su entrada.
       Mandar una orden de Bs 0 a la pasarela devuelve un error del banco y
       deja al comprador mirando una pantalla de cobro por cero.

       Va acá y no en el navegador porque emitir es escribir, y el público no
       escribe: esta función corre con service_role del lado del servidor.

       emitir_orden es idempotente —si la orden ya estaba pagada devuelve las
       que hay— así que un doble envío del formulario no duplica entradas. */
    if (data?.ok && Number(data.total) === 0) {
      try {
        await rpc("emitir_orden", {
          p_orden: data.orden, p_monto_cobrado: 0, p_pago_ref: "GRATIS",
        });
        return json({ ...data, gratis: true });
      } catch (err) {
        console.error(`no se pudo emitir la orden gratis ${data.orden}: ${err}`);
        return json({ ok: false, motivo: "No se pudo confirmar tu lugar. Probá de nuevo." }, 500);
      }
    }

    return json(data);
  } catch (err) {
    return json({ ok: false, motivo: String((err as Error).message ?? err) }, 500);
  }
});
