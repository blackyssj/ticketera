/* enviar-entradas — el correo con el link a las entradas.
   Manda un LINK, no adjuntos: el ticket se dibuja en canvas del lado del
   cliente, así que adjuntarlo obligaría a renderizarlo en el servidor o a
   que el navegador suba nueve PNG. El link además sigue sirviendo cuando el
   comprador borra el correo o cambia de teléfono.
   Si no hay RESEND_API_KEY no falla: registra y sigue. Que no se pueda mandar
   un correo no puede tumbar una venta ya cobrada. */
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

const RESEND = Deno.env.get("RESEND_API_KEY");
const DESDE  = Deno.env.get("CORREO_DESDE") ?? "Entradas <onboarding@resend.dev>";
const SITIO  = Deno.env.get("SITIO_URL") ?? "https://ticketera-coral.vercel.app";

const esc = (s: unknown) => String(s ?? "").replace(/[&<>"]/g, (c) =>
  ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]!));

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ ok: false, motivo: "Usá POST." }, 405);
  try {
    const { orden } = await req.json();
    if (!orden) return json({ ok: false, motivo: "Falta la orden." }, 400);

    const o = await uno(`ordenes?id=eq.${orden}&select=id,estado,total,comprador_nombre,comprador_email,evento_id`);
    if (!o) return json({ ok: false, motivo: "Esa orden no existe." }, 404);
    if (o.estado !== "pagada") return json({ ok: false, motivo: "La orden no está pagada." }, 409);
    if (!o.comprador_email) return json({ ok: true, enviado: false, motivo: "La compra no dejó correo." });

    const e = await uno(`eventos?id=eq.${o.evento_id}&select=nombre,lugar,fecha,hora_inicio`);
    const ent = await rest(`entradas?orden_id=eq.${orden}&select=code,tipo_entrada(nombre),mesas(etiqueta,categoria)&order=created_at`);
    const n = (ent ?? []).length;
    const link = `${SITIO}/orden/?id=${o.id}`;

    if (!RESEND) {
      console.log(`sin RESEND_API_KEY: no se envió nada. orden=${o.id} a=${o.comprador_email} link=${link}`);
      return json({ ok: true, enviado: false, motivo: "El envío de correos no está configurado.", link });
    }

    const filas = (ent ?? []).map((x) =>
      `<tr><td style="padding:6px 12px 6px 0">${esc(x.tipo_entrada?.nombre
        ?? ((x.mesas?.categoria === "lounge" ? "Lounge " : "Mesa ") + (x.mesas?.etiqueta ?? "")))}</td>
        <td style="padding:6px 0;font-family:ui-monospace,monospace">#${esc(x.code)}</td></tr>`).join("");

    const html = `<div style="font-family:system-ui,-apple-system,sans-serif;max-width:520px;margin:0 auto;color:#171310">
  <p style="font-size:12px;letter-spacing:.14em;text-transform:uppercase;color:#A9741B;margin:0 0 6px">${esc(e.lugar)}</p>
  <h1 style="font-size:30px;margin:0 0 4px;text-transform:uppercase">${esc(e.nombre)}</h1>
  <p style="color:#6b6259;margin:0 0 22px">${esc(e.fecha)} · ${esc(String(e.hora_inicio).slice(0,5))}</p>
  <p>Hola ${esc(o.comprador_nombre)}, tu compra está confirmada.
     ${n === 1 ? "Tenés 1 entrada" : `Tenés ${n} entradas`}.</p>
  <p style="margin:22px 0">
    <a href="${link}" style="background:#DC0A2D;color:#fff;text-decoration:none;padding:14px 22px;border-radius:3px;display:inline-block;font-weight:600">Ver mis entradas</a>
  </p>
  <p style="font-size:13px;color:#6b6259">Abrí ese link en la puerta: ahí están los QR.
     Guardalo, sirve siempre.</p>
  <table style="font-size:13px;color:#6b6259;border-collapse:collapse;margin-top:18px">${filas}</table>
  <p style="font-size:12px;color:#9a9188;margin-top:24px">Cada QR vale para un solo ingreso.</p>
</div>`;

    const r = await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: { Authorization: `Bearer ${RESEND}`, "Content-Type": "application/json" },
      body: JSON.stringify({
        from: DESDE, to: [o.comprador_email],
        subject: `Tus entradas — ${e.nombre}`,
        html,
      }),
    });
    const j = await r.json().catch(() => ({}));
    if (!r.ok) {
      // Un correo que no sale no puede tumbar una venta ya cobrada.
      console.error(`resend falló para ${o.id}: ${JSON.stringify(j).slice(0, 300)}`);
      return json({ ok: true, enviado: false, motivo: "No se pudo enviar el correo.", link });
    }
    return json({ ok: true, enviado: true, id: j.id, link });
  } catch (err) {
    return json({ ok: false, motivo: String((err as Error).message ?? err) }, 500);
  }
});
