/* contacto — el pedido de "quiero vender con TICKETAZO".
   El único camino de escritura del público que no es una compra. Corre con
   service_role, así que valida todo antes de tocar la base: largo de cada
   campo, un tope por IP y un campo trampa para los bots.

   No manda correo (no hay correo configurado) y no avisa a nadie: el aviso
   lo da el navegador, que después de guardar abre WhatsApp con el mismo
   mensaje. Acá sólo queda el registro, para que el pedido exista aunque la
   conversación se pierda. */
const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (b: unknown, s = 200) =>
  new Response(JSON.stringify(b), { status: s, headers: { ...CORS, "Content-Type": "application/json" } });

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

async function hashIp(req: Request) {
  const ip = (req.headers.get("x-forwarded-for") ?? "").split(",")[0].trim() || "sin-ip";
  const b = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(ip + "|ticketera"));
  return Array.from(new Uint8Array(b)).slice(0, 12).map((x) => x.toString(16).padStart(2, "0")).join("");
}

const texto = (v: unknown, max: number) => String(v ?? "").trim().slice(0, max);

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ ok: false, motivo: "Usá POST." }, 405);
  try {
    const b = await req.json();

    /* El campo trampa: un humano no lo ve (está escondido por CSS) y no lo
       llena. Un bot llena todo. Se contesta OK para no darle la pista. */
    if (texto(b.sitio, 10)) return json({ ok: true, bot: true });

    const nombre   = texto(b.nombre, 120);
    const contacto = texto(b.contacto, 120);
    if (nombre.length < 2)   return json({ ok: false, motivo: "Falta tu nombre." }, 400);
    if (contacto.length < 5) return json({ ok: false, motivo: "Falta un WhatsApp o un correo para responderte." }, 400);

    const fecha = texto(b.fecha_evento, 10);
    const fechaOk = /^\d{4}-\d{2}-\d{2}$/.test(fecha) ? fecha : null;
    const publico = Number.parseInt(String(b.publico ?? ""), 10);
    const origen = ["organizadores", "presentacion"].includes(String(b.origen)) ? String(b.origen) : "otro";

    /* Cinco pedidos por hora desde la misma IP. Un organizador manda uno;
       cinco es alguien probando el formulario, y de ahí para arriba es un
       script. Se frena sin decir por qué. */
    const ip_hash = await hashIp(req);
    const desde = new Date(Date.now() - 3600_000).toISOString();
    const recientes = await rest(
      `contactos?ip_hash=eq.${ip_hash}&creado_at=gte.${encodeURIComponent(desde)}&select=id`,
    );
    if ((recientes ?? []).length >= 5) return json({ ok: false, motivo: "Probá de nuevo en un rato." }, 429);

    const fila = await rest("contactos", {
      method: "POST",
      headers: { Prefer: "return=representation" },
      body: JSON.stringify({
        nombre, contacto,
        evento: texto(b.evento, 160) || null,
        fecha_evento: fechaOk,
        lugar: texto(b.lugar, 160) || null,
        publico: Number.isFinite(publico) ? Math.max(0, Math.min(publico, 200000)) : null,
        mensaje: texto(b.mensaje, 1200) || null,
        origen, ip_hash,
      }),
    });
    return json({ ok: true, id: fila?.[0]?.id ?? null });
  } catch (err) {
    console.error(`contacto falló: ${err}`);
    return json({ ok: false, motivo: "No se pudo enviar. Escribinos por WhatsApp." }, 500);
  }
});
