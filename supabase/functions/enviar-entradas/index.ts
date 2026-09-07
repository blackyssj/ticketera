/* enviar-entradas — el correo con el link a las entradas.
   Manda un LINK, no adjuntos: el ticket se dibuja en canvas del lado del
   cliente, así que adjuntarlo obligaría a renderizarlo en el servidor o a
   que el navegador suba nueve PNG. El link además sigue sirviendo cuando el
   comprador borra el correo o cambia de teléfono.
   Si no hay RESEND_API_KEY no falla: registra y sigue. Que no se pueda mandar
   un correo no puede tumbar una venta ya cobrada.

   El diseño va en tablas y estilos en línea, con la paleta de TICKETAZO. Es
   el hermano del correo de recuperar contraseña, que vive en
   supabase/plantillas-correo/ porque ese lo manda Supabase y se carga a
   mano en el panel. Si se cambia el aspecto de uno, se cambia el del otro:
   un comprador recibe los dos y tienen que parecer del mismo lado. */
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

    /* ── el correo, con la marca de TICKETAZO ──
       Violeta y fluor, los mismos valores que portada.css y que la
       plantilla de recuperar contraseña (supabase/plantillas-correo/).
       Antes iba en negro, rojo y dorado cerveza: la paleta de Amstel, que
       quedó de cuando la ticketera vestía un solo evento. Un comprador
       recibe estos dos correos y tienen que parecer del mismo lado.

       Tablas y estilos en línea, no divs con flex: Outlook renderiza con
       el motor de Word y descarta casi todo el CSS moderno. Feo de
       escribir, igual en todos lados.

       Hexadecimales sólidos y ninguna rgba: los clientes viejos la ignoran
       y dejarían el texto en negro sobre violeta, o sea invisible. */
    const filas = (ent ?? []).map((x) =>
      `<tr>
        <td style="padding:7px 12px 7px 0;font-family:Helvetica,Arial,sans-serif;font-size:13px;color:#A79EC0">${esc(x.tipo_entrada?.nombre
          ?? ((x.mesas?.categoria === "lounge" ? "Lounge " : "Mesa ") + (x.mesas?.etiqueta ?? "")))}</td>
        <td style="padding:7px 0;font-family:Courier,monospace;font-size:13px;color:#F3EFE2">#${esc(x.code)}</td>
      </tr>`).join("");

    const html = `<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="background:#180E3A;margin:0;padding:0">
 <tr><td align="center" style="padding:32px 16px">
  <table role="presentation" width="520" cellpadding="0" cellspacing="0" border="0" style="width:520px;max-width:100%">
   <tr><td style="padding:0 0 26px"><img src="${SITIO}/logo-correo.png" alt="TICKETAZO" width="180" style="display:block;border:0;outline:none;text-decoration:none;width:180px;height:auto;color:#F3EFE2;font-family:Helvetica,Arial,sans-serif;font-size:22px;font-weight:bold"></td></tr>
   <tr><td style="background:#231550;border-radius:10px;padding:32px 28px">
    <p style="margin:0 0 6px;font-family:Helvetica,Arial,sans-serif;font-size:11px;letter-spacing:2px;text-transform:uppercase;color:#FFE24B">${esc(e.lugar)}</p>
    <h1 style="margin:0 0 4px;font-family:Helvetica,Arial,sans-serif;font-size:26px;line-height:1.15;text-transform:uppercase;color:#F3EFE2">${esc(e.nombre)}</h1>
    <p style="margin:0 0 22px;font-family:Helvetica,Arial,sans-serif;font-size:14px;color:#A79EC0">${esc(e.fecha)} · ${esc(String(e.hora_inicio).slice(0,5))}</p>
    <p style="margin:0 0 24px;font-family:Helvetica,Arial,sans-serif;font-size:15px;line-height:1.55;color:#F3EFE2">Hola ${esc(o.comprador_nombre)}, tu compra está confirmada. ${n === 1 ? "Tenés 1 entrada" : `Tenés ${n} entradas`}.</p>
    <table role="presentation" cellpadding="0" cellspacing="0" border="0"><tr>
     <td align="center" bgcolor="#FFE24B" style="border-radius:8px">
      <a href="${link}" style="display:inline-block;padding:14px 26px;font-family:Helvetica,Arial,sans-serif;font-size:15px;font-weight:bold;color:#180E3A;text-decoration:none">Ver mis entradas</a>
     </td>
    </tr></table>
    <p style="margin:22px 0 0;font-family:Helvetica,Arial,sans-serif;font-size:13px;line-height:1.5;color:#A79EC0">Abrí ese link en la puerta: ahí están los QR. Guardalo, sirve siempre.</p>
    <table role="presentation" cellpadding="0" cellspacing="0" border="0" style="margin-top:18px;border-collapse:collapse">${filas}</table>
    <p style="margin:22px 0 0;font-family:Helvetica,Arial,sans-serif;font-size:12px;color:#6E6392">Cada QR vale para un solo ingreso.</p>
   </td></tr>
   <tr><td style="padding:22px 4px 0;font-family:Helvetica,Arial,sans-serif;font-size:12px;line-height:1.5;color:#6E6392">TICKETAZO · Entradas y control de puerta · Santa Cruz de la Sierra</td></tr>
  </table>
 </td></tr>
</table>`;

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
