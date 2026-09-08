/* og — la tarjeta que se ve cuando alguien pega el link en WhatsApp.

   El problema: `evento.html` es una página estática que pide sus datos por
   JavaScript. Los rastreadores de WhatsApp, Facebook, Telegram o Twitter NO
   ejecutan JavaScript: leen el HTML crudo y se van. Por eso hoy el link de
   un evento se comparte sin imagen, sin nombre y sin fecha — se ve como un
   link roto justo en el momento en que alguien lo está recomendando.

   Esta función devuelve un HTML mínimo con las etiquetas Open Graph del
   evento. No es la página: es lo que el rastreador necesita y nada más.

   ── por qué una función aparte y no meterlo en evento.html ──
   Las etiquetas dependen del evento y el HTML es un archivo fijo. La
   alternativa es que TODA visita pase por un servidor que las inyecte, y
   eso le suma medio segundo a cada comprador para resolver algo que sólo
   le importa a un robot. Vercel manda acá únicamente al que se declara
   rastreador; la persona sigue recibiendo el archivo estático de siempre.

   ── por qué igual lleva un link visible ──
   Si un humano cae acá —porque copió el user-agent de un bot, o porque
   algún cliente de mensajería abre la vista previa en el navegador— tiene
   que poder llegar al evento. Un HTML sin nada es una pantalla en blanco.  */
const SB  = Deno.env.get("SUPABASE_URL")!;
const KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const SITIO = (Deno.env.get("SITIO_URL") ?? "https://ticketazo.com.bo").replace(/\/+$/, "");

const esc = (s: unknown) =>
  String(s ?? "").replace(/&/g, "&amp;").replace(/</g, "&lt;")
    .replace(/>/g, "&gt;").replace(/"/g, "&quot;");

const DIA = ["domingo","lunes","martes","miércoles","jueves","viernes","sábado"];
const MES = ["enero","febrero","marzo","abril","mayo","junio","julio",
             "agosto","septiembre","octubre","noviembre","diciembre"];

function html(cuerpo: string, s = 200) {
  return new Response(cuerpo, {
    status: s,
    headers: {
      "Content-Type": "text/html; charset=utf-8",
      /* Los rastreadores vuelven a pedir la misma URL muchas veces cuando
         un link circula. Cinco minutos alcanzan para que un reenvío en
         cadena no dispare una consulta por mensaje, y son pocos como para
         que un cambio de flyer se vea casi enseguida. */
      "Cache-Control": "public, max-age=300, s-maxage=300",
    },
  });
}

/* Las medidas desde la cabecera del archivo. Tres formatos y nada mas:
   son los tres que el panel acepta subir (png, jpg, webp). Cualquier otra
   cosa devuelve null y las etiquetas de medida no salen — la tarjeta se
   arma igual, apenas con menos ayuda. */
function medidas(b: Uint8Array): { w: number; h: number } | null {
  const u16 = (i: number) => (b[i] << 8) | b[i + 1];
  try {
    // PNG: ancho y alto en el IHDR, siempre en la misma posicion.
    if (b[0] === 0x89 && b[1] === 0x50) {
      const u32 = (i: number) => (b[i] << 24 | b[i+1] << 16 | b[i+2] << 8 | b[i+3]) >>> 0;
      return { w: u32(16), h: u32(20) };
    }
    // JPEG: hay que recorrer los segmentos hasta el SOF.
    if (b[0] === 0xFF && b[1] === 0xD8) {
      let i = 2;
      while (i + 9 < b.length) {
        if (b[i] !== 0xFF) { i++; continue; }
        const m = b[i + 1];
        if (m >= 0xC0 && m <= 0xC3) return { h: u16(i + 5), w: u16(i + 7) };
        if (m === 0xD8 || m === 0xD9 || (m >= 0xD0 && m <= 0xD7)) { i += 2; continue; }
        i += 2 + u16(i + 2);
      }
      return null;
    }
    // WebP en su variante simple (VP8X trae las medidas en otro lado y no
    // vale la pena: sin medidas la tarjeta igual sale).
    if (b[8] === 0x57 && b[9] === 0x45 && b[12] === 0x56 && b[15] === 0x20) {
      return { w: ((b[26] | b[27] << 8) & 0x3FFF), h: ((b[28] | b[29] << 8) & 0x3FFF) };
    }
  } catch { /* un archivo raro no puede tumbar la vista previa */ }
  return null;
}

Deno.serve(async (req) => {
  const u = new URL(req.url);
  const org = (u.searchParams.get("org") ?? "").trim().toLowerCase();
  let   ev  = (u.searchParams.get("ev")  ?? "").trim().toLowerCase();
  /* Sin `ev` es la vidriera del organizador —el link único que el
     relacionador reparte— y la tarjeta muestra su fecha más próxima. La URL
     de la tarjeta es la de la vidriera, no la del evento: el que toca tiene
     que caer donde puede elegir fecha, que es el punto del link único. */
  const vidriera = !ev;
  const url = vidriera
    ? `${SITIO}/${encodeURIComponent(org)}`
    : `${SITIO}/${encodeURIComponent(org)}/${encodeURIComponent(ev)}`;

  /* Lo que se muestra cuando no se pudo averiguar nada: la marca y el
     link. Nunca un error — una vista previa rota es peor que una genérica,
     porque el que comparte cree que el link no anda. */
  const generico = (motivo: string) => html(`<!doctype html><html lang="es-BO"><head>
<meta charset="utf-8">
<title>TICKETAZO</title>
<meta property="og:site_name" content="TICKETAZO">
<meta property="og:title" content="TICKETAZO">
<meta property="og:description" content="Entradas con QR. Elegís, pagás y te llega al toque.">
<meta property="og:url" content="${esc(url)}">
<meta property="og:type" content="website">
<meta name="twitter:card" content="summary">
<link rel="canonical" href="${esc(url)}">
</head><body><p><a href="${esc(url)}">Ver el evento</a></p><!-- ${esc(motivo)} --></body></html>`);

  if (!org) return generico("faltan parámetros");

  /* ── la imagen, servida por nosotros ─────────────────────────
     Storage manda cada objeto público con `x-robots-tag: none`, y el
     rastreador de Facebook y WhatsApp lo respeta: levanta el título y la
     descripción, y DESCARTA la imagen. Esa cabecera es de Supabase y no
     se puede apagar desde la consola.

     Así que la vista previa apunta acá y esto la reemite sin esa
     cabecera. Es un hop más, pero sólo lo paga el rastreador — la página
     que ve el comprador sigue usando la URL directa de Storage.

     La ruta NO viene por parámetro: se resuelve del evento contra la
     base. Aceptar una URL de afuera convertiría esto en un proxy abierto
     con el que cualquiera se descarga lo que quiera desde nuestro
     dominio. */
  const quiereImagen = u.searchParams.get("img") === "1";

  try {
    /* Con `ev`: ese evento. Sin `ev`: el publicado más próximo del
       organizador que todavía no pasó — hoy en La Paz, no medianoche UTC. */
    const hoy = new Date(Date.now() - 4 * 3600 * 1000).toISOString().slice(0, 10);
    const filtro = vidriera
      ? `&estado=eq.publicado&fecha=gte.${hoy}&order=fecha.asc,hora_inicio.asc`
      : `&slug=eq.${encodeURIComponent(ev)}`;
    const r = await fetch(
      `${SB}/rest/v1/eventos?select=slug,nombre,lugar,fecha,hora_inicio,descripcion,` +
      `flyer_url,arte_url,estado,organizadores!inner(slug,nombre,activo)` +
      `&organizadores.slug=eq.${encodeURIComponent(org)}${filtro}&limit=1`,
      { headers: { apikey: KEY, Authorization: `Bearer ${KEY}` } });
    const filas = await r.json().catch(() => []);
    const e = Array.isArray(filas) ? filas[0] : null;
    if (!e || e.estado !== "publicado" || !e.organizadores?.activo) {
      return generico("evento no publicado");
    }

    const f = new Date(String(e.fecha) + "T12:00:00-04:00");
    const hora = String(e.hora_inicio ?? "").slice(0, 5);
    const cuando = `${DIA[f.getDay()]} ${f.getDate()} de ${MES[f.getMonth()]}` +
                   (hora ? ` · ${hora}` : "");
    if (vidriera) ev = String(e.slug ?? "");
    const titulo = vidriera
      ? `${e.organizadores.nombre} — próxima fecha: ${cuando}`
      : `${e.nombre} — ${cuando}`;
    /* La bajada del organizador si la escribió; si no, el dato que igual
       hace falta para decidir: dónde y cuándo. Una descripción vacía deja
       la tarjeta con el título flotando. */
    const desc = String(e.descripcion ?? "").trim() ||
      `${e.lugar ? e.lugar + ". " : ""}Entradas con QR: elegís, pagás y te llega al toque.`;
    /* El FLYER primero: es el afiche que la gente reconoce. El arte de la
       entrada es el último recurso —tiene el hueco del QR en el medio— y
       aun así es mejor que una tarjeta sin imagen. */
    const directa = e.flyer_url || e.arte_url || "";

    if (quiereImagen) {
      if (!directa) return new Response("Sin imagen", { status: 404 });
      const r3 = await fetch(directa);
      if (!r3.ok) return new Response("Sin imagen", { status: 404 });
      return new Response(r3.body, {
        headers: {
          "Content-Type": r3.headers.get("content-type") ?? "image/jpeg",
          /* Un dia: el afiche de un evento no cambia todos los dias, y si
             cambia se refresca antes con un `?v=` en la etiqueta que con
             una espera corta acá. */
          "Cache-Control": "public, max-age=86400, s-maxage=86400",
          /* Lo contrario de lo que manda Storage, que es todo el punto. */
          "X-Robots-Tag": "all",
        },
      });
    }

    // La que viaja en la etiqueta pasa por acá; la página usa la directa.
    const img = directa
      ? `${SB}/functions/v1/og?org=${encodeURIComponent(org)}&ev=${encodeURIComponent(ev)}&img=1`
      : "";

    /* Las medidas de la imagen. WhatsApp y Facebook deciden entre la
       tarjeta grande y el thumbnail chico con esto: sin las medidas
       tienen que bajar la imagen para averiguarlas, y si tardan o el
       pedido falla se quedan con la version chica. Se leen del nombre del
       archivo? No: se piden con un HEAD... tampoco, eso es otro viaje.
       Se sacan de los primeros bytes del JPEG/PNG/WebP, que es lo unico
       que hace falta y no cuesta una descarga entera. */
    let med: { w: number; h: number } | null = null;
    if (directa) {
      try {
        const r2 = await fetch(directa, { headers: { Range: "bytes=0-2047" } });
        med = medidas(new Uint8Array(await r2.arrayBuffer()));
      } catch { med = null; }
    }

    return html(`<!doctype html><html lang="es-BO"><head>
<meta charset="utf-8">
<title>${esc(titulo)}</title>
<meta name="description" content="${esc(desc)}">
<meta property="og:site_name" content="TICKETAZO">
<meta property="og:type" content="website">
<meta property="og:title" content="${esc(titulo)}">
<meta property="og:description" content="${esc(desc)}">
<meta property="og:url" content="${esc(url)}">
${img ? `<meta property="og:image" content="${esc(img)}">
<meta property="og:image:secure_url" content="${esc(img)}">
<meta property="og:image:alt" content="Afiche de ${esc(e.nombre)}">
${med ? `<meta property="og:image:width" content="${med.w}">
<meta property="og:image:height" content="${med.h}">` : ""}` : ""}
<meta name="twitter:card" content="${img ? "summary_large_image" : "summary"}">
<meta name="twitter:title" content="${esc(titulo)}">
<meta name="twitter:description" content="${esc(desc)}">
${img ? `<meta name="twitter:image" content="${esc(img)}">` : ""}
<link rel="canonical" href="${esc(url)}">
</head><body>
<h1>${esc(e.nombre)}</h1>
<p>${esc(cuando)}${e.lugar ? " · " + esc(e.lugar) : ""}</p>
<p><a href="${esc(url)}">Ver entradas</a></p>
</body></html>`);
  } catch (err) {
    console.error(`og: ${org}/${ev} — ${String((err as Error).message ?? err)}`);
    return generico("error");
  }
});
