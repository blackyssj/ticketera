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

Deno.serve(async (req) => {
  const u = new URL(req.url);
  const org = (u.searchParams.get("org") ?? "").trim().toLowerCase();
  const ev  = (u.searchParams.get("ev")  ?? "").trim().toLowerCase();
  const url = `${SITIO}/${encodeURIComponent(org)}/${encodeURIComponent(ev)}`;

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

  if (!org || !ev) return generico("faltan parámetros");

  try {
    const r = await fetch(
      `${SB}/rest/v1/eventos?select=nombre,lugar,fecha,hora_inicio,descripcion,` +
      `flyer_url,arte_url,estado,organizadores!inner(slug,nombre,activo)` +
      `&slug=eq.${encodeURIComponent(ev)}&organizadores.slug=eq.${encodeURIComponent(org)}` +
      `&limit=1`,
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
    const titulo = `${e.nombre} — ${cuando}`;
    /* La bajada del organizador si la escribió; si no, el dato que igual
       hace falta para decidir: dónde y cuándo. Una descripción vacía deja
       la tarjeta con el título flotando. */
    const desc = String(e.descripcion ?? "").trim() ||
      `${e.lugar ? e.lugar + ". " : ""}Entradas con QR: elegís, pagás y te llega al toque.`;
    /* El FLYER primero: es el afiche que la gente reconoce. El arte de la
       entrada es el último recurso —tiene el hueco del QR en el medio— y
       aun así es mejor que una tarjeta sin imagen. */
    const img = e.flyer_url || e.arte_url || "";

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
<meta property="og:image:alt" content="Afiche de ${esc(e.nombre)}">` : ""}
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
