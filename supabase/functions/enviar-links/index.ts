/* enviar-links — el boton que le manda a cada relacionador su link.

   Repartir los links era copiar y pegar del panel a WhatsApp, uno por uno.
   Con 108 relacionadores y dos eventos son 216 pegadas, y el que se
   equivoca manda el link de otro: no falla, VENDE, y le atribuye la venta
   a la persona equivocada.

   Dos acciones:
     estado  — a cuantos les falta, a cuantos ya se les mando, quien no
               tiene correo. Lo pide la pantalla antes de dibujar el boton.
     enviar  — manda. Por defecto SOLO a los que nunca recibieron el link
               de ese evento; con forzar:true, a todos de nuevo.

   El correo va en tablas y estilos en linea con la paleta de TICKETAZO,
   igual que enviar-entradas y que la plantilla de recuperar contrasena.
   Si se cambia el aspecto de uno, se cambian los tres: un relacionador
   que ademas compro una entrada recibe dos y tienen que parecer del
   mismo lado. */
const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (b: unknown, s = 200) =>
  new Response(JSON.stringify(b), { status: s, headers: { ...CORS, "Content-Type": "application/json" } });
const mal = (motivo: string, s = 400) => json({ ok: false, motivo }, s);

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

const RESEND = Deno.env.get("RESEND_API_KEY");
const DESDE  = Deno.env.get("CORREO_DESDE") ?? "Entradas <onboarding@resend.dev>";
const SITIO  = Deno.env.get("SITIO_URL") ?? "https://ticketazo.com.bo";

const esc = (s: unknown) => String(s ?? "").replace(/[&<>"]/g, (c) =>
  ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]!));

/* Resend acepta hasta 100 por llamada en /emails/batch. Con 108 personas
   eso son dos llamadas en vez de 108: mandarlos de a uno tarda casi un
   minuto por el limite de dos pedidos por segundo, y una Edge Function no
   vive tanto. */
const LOTE = 100;

// ── quien llama ──────────────────────────────────────────────
// El rol y el organizador salen de la base, nunca del token: el JWT no los
// lleva, y si algun dia los llevara seguirian siendo lo que el token dice
// y no lo que la base sabe.
async function quienLlama(req: Request) {
  const token = /^Bearer\s+(.+)$/i.exec(req.headers.get("Authorization") ?? "")?.[1]?.trim();
  if (!token) return { motivo: "Entra de nuevo: no llego tu sesion.", status: 401 };
  const r = await fetch(`${SB}/auth/v1/user`, { headers: { apikey: KEY, Authorization: `Bearer ${token}` } });
  if (!r.ok) return { motivo: "Tu sesion vencio. Entra de nuevo.", status: 401 };
  const u = await r.json().catch(() => null);
  if (!u?.id) return { motivo: "Tu sesion vencio. Entra de nuevo.", status: 401 };

  const yo = await uno(`perfiles?id=eq.${u.id}&select=id,nombre,rol,activo,organizador_id`);
  if (!yo || !yo.activo) return { motivo: "Tu cuenta no esta habilitada.", status: 403 };
  /* admin y staff, el mismo corte que puede_editar() (0012): el que arma
     el evento es normalmente quien reparte los links. Un rrpp no puede —
     se mandaria el link a si mismo y a los 107 companeros. */
  if (yo.rol !== "admin" && yo.rol !== "staff") return {
    motivo: "Solo un administrador o el staff pueden repartir los links.", status: 403 };
  return { yo };
}

/* El evento tiene que ser del organizador de quien llama. Sin esto, un
   admin de Amstel manda los links de un evento de Distrito con solo
   cambiar el uuid en el pedido. */
async function eventoDe(id: unknown, yo: any) {
  if (typeof id !== "string" || !id) return { motivo: "Falta el evento.", status: 400 };
  const ev = await uno(`eventos?id=eq.${id}&select=id,nombre,slug,fecha,hora_inicio,lugar,organizador_id`);
  if (!ev || ev.organizador_id !== yo.organizador_id) return {
    motivo: "Ese evento no existe.", status: 404 };
  return { ev };
}

/* Los relacionadores que PUEDEN recibir, y los que no, separados y con el
   motivo. Los que no pueden importan tanto como los otros: son exactamente
   los que despues dicen "a mi no me llego". */
async function repartoDe(ev: any, yo: any) {
  const gente = await rest(
    `perfiles?organizador_id=eq.${yo.organizador_id}&rol=eq.rrpp&activo=is.true` +
    `&select=id,nombre,slug,email_contacto&order=nombre`);
  const previos = await rest(`envio_link?evento_id=eq.${ev.id}&select=perfil_id,enviado_at`);
  const cuando = new Map(previos.map((p: any) => [p.perfil_id, p.enviado_at]));

  const listos: any[] = [], sinCorreo: any[] = [], sinCodigo: any[] = [];
  for (const p of gente) {
    if (!p.slug) { sinCodigo.push(p.nombre); continue; }
    if (!p.email_contacto) { sinCorreo.push(p.nombre); continue; }
    listos.push({ ...p, recibio: cuando.get(p.id) ?? null });
  }
  return { listos, sinCorreo, sinCodigo };
}

/* UN link por persona, el de la vidriera del organizador, y no el del
   evento: es el mismo que el panel muestra en Equipo (linkDe), y sirve
   para todas las fechas del cliente, las de hoy y las que publique
   después. Mandar el del evento daba a cada relacionador un link por
   fecha, y la venta de la segunda se perdía cuando compartían el de la
   primera. El evento sigue siendo la ocasión del envío —"te mando tu
   link porque salió tal fecha"— y lo que se registra en envio_link. */
function correoDe(p: any, ev: any, org: any) {
  const link = `${SITIO}/${org.slug}?r=${encodeURIComponent(p.slug)}`;
  /* &middot; y no el caracter suelto, como en todo el resto de la plantilla:
     el correo sale en UTF-8 y Resend lo declara, pero alcanza un cliente que
     adivine la codificacion para que ese punto se vea "Â·". La entidad se ve
     igual en todos y no depende de que nadie adivine bien. */
  const cuando = ev.fecha
    ? `${ev.fecha}${ev.hora_inicio ? " &middot; " + String(ev.hora_inicio).slice(0, 5) : ""}`
    : "";
  const html = `<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="background:#180E3A;padding:28px 0">
 <tr><td align="center">
  <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="max-width:560px">
   <tr><td style="padding:0 4px 18px"><img src="${SITIO}/logo-correo.png" alt="TICKETAZO" width="180" style="display:block;border:0"></td></tr>
   <tr><td style="background:#231550;border-radius:12px;padding:28px 26px">
    <p style="margin:0 0 6px;font-family:Helvetica,Arial,sans-serif;font-size:13px;letter-spacing:1px;color:#FFE24B">TU LINK DE VENTA</p>
    <h1 style="margin:0 0 18px;font-family:Helvetica,Arial,sans-serif;font-size:23px;line-height:1.25;color:#F3EFE2">${esc(org.nombre)}</h1>
    <p style="margin:0 0 22px;font-family:Helvetica,Arial,sans-serif;font-size:15px;line-height:1.55;color:#F3EFE2">Hola ${esc(p.nombre)}, este es <b>tu</b> link para vender. Es uno solo y sirve para <b>todas las fechas</b> de ${esc(org.nombre)}: ${esc(ev.nombre)} y las que salgan despu&eacute;s. Todo lo que se compre por ac&aacute; queda a tu nombre y suma a tu comisi&oacute;n.</p>
    <table role="presentation" cellpadding="0" cellspacing="0" border="0"><tr>
     <td align="center" bgcolor="#FFE24B" style="border-radius:8px">
      <a href="${link}" style="display:inline-block;padding:14px 26px;font-family:Helvetica,Arial,sans-serif;font-size:15px;font-weight:bold;color:#180E3A;text-decoration:none">Abrir mi link</a>
     </td>
    </tr></table>
    <p style="margin:22px 0 6px;font-family:Helvetica,Arial,sans-serif;font-size:13px;color:#A79EC0">Para copiar y pegar:</p>
    <p style="margin:0;font-family:Courier,monospace;font-size:13px;line-height:1.5;color:#F3EFE2;word-break:break-all">${esc(link)}</p>
    ${cuando ? `<p style="margin:22px 0 0;font-family:Helvetica,Arial,sans-serif;font-size:13px;color:#A79EC0">${esc(cuando)}${ev.lugar ? " &middot; " + esc(ev.lugar) : ""}</p>` : ""}
    <p style="margin:18px 0 0;font-family:Helvetica,Arial,sans-serif;font-size:12px;line-height:1.5;color:#6E6392">Es tuyo y no cambia. Si mand&aacute;s el de otra persona, la venta se le cuenta a esa persona.</p>
   </td></tr>
   <tr><td style="padding:22px 4px 0;font-family:Helvetica,Arial,sans-serif;font-size:12px;line-height:1.5;color:#6E6392">TICKETAZO &middot; Entradas y control de puerta &middot; Santa Cruz de la Sierra</td></tr>
  </table>
 </td></tr>
</table>`;
  return { from: DESDE, to: [p.email_contacto], subject: `Tu link de venta — ${org.nombre}`, html };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return mal("Usa POST.", 405);
  try {
    const g = await quienLlama(req);
    if (!g.yo) return mal(g.motivo!, g.status!);
    const yo = g.yo;

    const b = await req.json().catch(() => ({} as any));
    const e = await eventoDe(b.evento, yo);
    if (!e.ev) return mal(e.motivo!, e.status!);
    const ev = e.ev;

    const org = await uno(`organizadores?id=eq.${yo.organizador_id}&select=slug,nombre`);
    const { listos, sinCorreo, sinCodigo } = await repartoDe(ev, yo);
    const faltan = listos.filter((p) => !p.recibio);
    const ultimo = listos.reduce((a: string | null, p: any) =>
      p.recibio && (!a || p.recibio > a) ? p.recibio : a, null);

    const resumen = {
      total: listos.length + sinCorreo.length + sinCodigo.length,
      con_link: listos.length,
      ya_recibieron: listos.length - faltan.length,
      faltan: faltan.length,
      sin_correo: sinCorreo,
      sin_codigo: sinCodigo,
      ultimo_envio: ultimo,
    };

    if (String(b.accion ?? "estado") === "estado") return json({ ok: true, ...resumen });

    if (!RESEND) return mal(
      "El envio de correos no esta configurado: falta RESEND_API_KEY.", 503);

    const forzar = b.forzar === true;
    const destino = forzar ? listos : faltan;
    if (!destino.length) return json({ ok: true, enviados: 0, ...resumen,
      motivo: forzar ? "No hay nadie con link y correo." : "Ya todos recibieron su link." });

    /* Se manda PRIMERO y se registra despues, y solo lo que Resend acepto.
       Al reves —marcar y despues mandar— un fallo de red deja a esa
       persona marcada como que ya recibio, y no vuelve a entrar nunca en
       la lista de los que faltan: el unico caso que este boton existe
       para arreglar. */
    let enviados = 0;
    const fallados: string[] = [];
    for (let i = 0; i < destino.length; i += LOTE) {
      const tanda = destino.slice(i, i + LOTE);
      const r = await fetch("https://api.resend.com/emails/batch", {
        method: "POST",
        headers: { Authorization: `Bearer ${RESEND}`, "Content-Type": "application/json" },
        body: JSON.stringify(tanda.map((p) => correoDe(p, ev, org))),
      });
      const j = await r.json().catch(() => ({}));
      if (!r.ok) {
        console.error(`resend batch fallo: ${JSON.stringify(j).slice(0, 300)}`);
        fallados.push(...tanda.map((p: any) => p.nombre));
        continue;
      }
      await rest("envio_link?on_conflict=evento_id,perfil_id", {
        method: "POST",
        headers: { Prefer: "resolution=merge-duplicates" },
        body: JSON.stringify(tanda.map((p: any) => ({
          organizador_id: yo.organizador_id, evento_id: ev.id, perfil_id: p.id,
          correo: p.email_contacto, enviado_at: new Date().toISOString(), actor_id: yo.id,
        }))),
      });
      enviados += tanda.length;
    }

    return json({ ok: true, enviados, fallados,
      sin_correo: sinCorreo, sin_codigo: sinCodigo,
      quedan: destino.length - enviados });
  } catch (err) {
    return mal(String((err as Error).message ?? err), 500);
  }
});
