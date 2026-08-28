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
    return json(data);
  } catch (err) {
    return json({ ok: false, motivo: String((err as Error).message ?? err) }, 500);
  }
});
