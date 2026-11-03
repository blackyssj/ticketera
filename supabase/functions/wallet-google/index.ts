/* wallet-google — "Agregar a Google Wallet" para las entradas de una compra.

   Lo que el comprador guarda en Wallet NO es la imagen de su entrada: Google
   no muestra imágenes nuestras como pase. El pase es la plantilla de Google
   con nuestros datos adentro (nombre del evento, lugar, fecha, a nombre de
   quién, tipo de entrada, el color y el afiche del evento) y el MISMO QR
   `EVT:<evento>:<code>` que dibuja app/ticket.js, así que la puerta de
   TICKETAZO y la de Plataforma Puerta lo leen igual que la entrada de
   /orden. El arte de la entrada (`arte_url`) no sirve acá: tiene el hueco
   blanco del QR vacío. Y la entrada ya dibujada no se puede mandar como
   imagen: Wallet pide URLs públicas, y una URL pública con el QR adentro es
   una entrada que baja cualquiera.

   Cómo se arma:
     · una clase por evento   (id `<issuer>.<eventos.id>`)
     · un objeto por entrada  (id `<issuer>.<entradas.id>`)
   Las dos cosas se crean ANTES por la API REST, y el link lleva un JWT
   "flaco" con sólo `{id, classId}` de cada objeto. La otra forma —el JWT con
   la clase y los objetos enteros adentro, que Google crea al guardar— no
   entra en el link ni con una sola entrada: medido con un evento real da
   2.589 caracteres, y Google dice que pasados los 1.800 el navegador puede
   cortar el link y el guardado falla. Además el flaco deja el nombre del
   comprador fuera de la URL (no queda en el historial del navegador).

   Con ids `<issuer>.<uuid>` entran 6 entradas en 1.752 caracteres; la 7ª ya
   se pasa. Por eso un link lleva una TANDA de hasta 6 (`?parte=N`). El
   99,9% de las compras tiene 6 o menos; la página pone un botón por tanda.

   Por qué el uuid de la entrada y no `code`: `code` es único POR EVENTO
   (`unique (evento_id, code)`), y el id de un objeto tiene que ser único en
   todo el emisor y no cambiar nunca.

   Acceso: el uuid de la orden ES la credencial, igual que en `orden`. Quien
   lo tiene ya ve los QR en /orden; el pase no le da nada nuevo. No se acepta
   `pago_ref`: ese camino existe en `orden` sólo para la vuelta de la
   pasarela, y para cuando alguien toca este botón ya tiene el uuid.

   Responde de dos formas, y sólo una toca Google:
     GET  ?estado=1               → {configurado, modo}: la página decide
                                    si muestra el botón.
     POST ?orden=<uuid>[&parte=N] → {ok, url} o {ok:false, aviso, motivo}:
                                    el toque del botón. Recién acá se crean
                                    en Google la clase y los objetos, con el
                                    nombre del comprador adentro.
   Un GET con `orden` (un link copiado de algún lado) no arma nada: vuelve a
   /orden/?id=<uuid>#wallet, que es donde está el botón.

   Por qué el pase no se arma con un GET: los escáneres de links de los
   buzones (Outlook Safe Links, Defender, Proofpoint) abren cada link del
   correo de la compra antes que la persona, a veces en un navegador con JS.
   Si un GET armara el pase, Google recibiría el nombre del comprador sin que
   nadie tocara nada, y /privacidad dice que eso pasa "sólo si lo pedís". Por
   eso el botón del correo lleva a /orden/?id=<uuid>#wallet y no acá, y lo
   que arma el pase es un POST: un escáner no toca botones ni manda POST. Va
   sin cuerpo y sin cabeceras, así que el navegador no hace el OPTIONS previo.
   Nunca HTML: la pasarela de Supabase reescribe todo text/html a text/plain
   con un CSP sandbox (ver og/index.ts), y una página de error de acá
   saldría como texto crudo.

   APAGADA hasta que estén los secrets (los carga José con
   scripts/secretos.py, que toma un archivo):
     GOOGLE_WALLET_ISSUER_ID   el número de emisor de la consola de Wallet
     GOOGLE_WALLET_SA_B64      el JSON de la cuenta de servicio, en base64
                               en una línea (secretos.py parte por líneas)
     GOOGLE_WALLET_MODO        "on" cuando Google aprueba el acceso de
                               producción; si falta o es otra cosa, "demo"
   Sin los dos primeros, `estado` dice configurado:false (la página no
   muestra el botón) y cualquier otro pedido contesta "no configurado". En
   demo Google sólo deja guardar a las cuentas de prueba, así que la página
   esconde el botón salvo con `?wallet=probar`.

   Sin `import`: el runtime no bundlea cuando se despliega por la API de
   gestión (_compartido/comun.ts) y un import remoto da BOOT_ERROR. La firma
   RS256 y el token de Google salen de WebCrypto y fetch. */
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

// ── constantes ──────────────────────────────────────────────────────
const SITIO = "https://ticketazo.com.bo";
const WO = "https://walletobjects.googleapis.com/walletobjects/v1";
const TANDA = 6;
const IDIOMA = "es-419";
// El `--noche` de la marca: el fondo del pase cuando el evento no tiene color.
const FONDO = "#180E3A";
/* Un evento con todo (fecha, lugar, afiche) que terminó hace más de esto ya
   no se ofrece: Google lo manda igual a "Pases vencidos" a las 72-96 h, y
   guardar un pase que nace vencido no le sirve a nadie. */
const PASADO_MS = 12 * 3600e3;

/* Lo que la persona lee, en el toast de la página. app/wallet.js tiene una
   copia del de `error`, para cuando la función ni contesta: si cambia acá,
   cambiarlo allá. */
const MOTIVO = {
  off:       "Google Wallet todavía no está disponible.",
  nada:      "Esta compra no tiene entradas para agregar.",
  pasado:    "Este evento ya pasó.",
  pendiente: "Esta compra todavía no está pagada.",
  noexiste:  "No encontramos esa compra.",
  error:     "No pudimos agregarla a Google Wallet. Probá de nuevo en un rato.",
} as const;
type Aviso = keyof typeof MOTIVO;

// ── configuración ───────────────────────────────────────────────────
type Cfg = { issuer: string; email: string; clave: string; modo: "demo" | "on" };

/* Se lee en cada pedido y no una vez al arrancar: cargar o cambiar un
   secret reinicia la función, pero así no hay ninguna versión en la que un
   valor viejo quede pegado en una variable. Nunca se imprime un valor; sólo
   el NOMBRE de lo que falta. */
function configuracion(): Cfg | { falta: string } {
  const issuer = (Deno.env.get("GOOGLE_WALLET_ISSUER_ID") ?? "").trim();
  if (!/^\d{6,30}$/.test(issuer)) return { falta: "GOOGLE_WALLET_ISSUER_ID" };
  const crudo = (Deno.env.get("GOOGLE_WALLET_SA_B64") ?? "").trim();
  if (!crudo) return { falta: "GOOGLE_WALLET_SA_B64" };
  let sa: { client_email?: string; private_key?: string };
  try {
    /* Base64 porque el JSON que baja Google Cloud viene en varias líneas y
       secretos.py lee una por línea. Si alguien pegó el JSON minificado en
       una línea, también sirve: no vale un viaje más para corregirlo. */
    const texto = crudo.startsWith("{") ? crudo
      : new TextDecoder().decode(Uint8Array.from(atob(crudo), (c) => c.charCodeAt(0)));
    sa = JSON.parse(texto);
  } catch {
    return { falta: "GOOGLE_WALLET_SA_B64 (no es un JSON en base64)" };
  }
  if (!sa.client_email || !/PRIVATE KEY/.test(sa.private_key ?? ""))
    return { falta: "GOOGLE_WALLET_SA_B64 (sin client_email o private_key)" };
  const modo = (Deno.env.get("GOOGLE_WALLET_MODO") ?? "").trim().toLowerCase() === "on" ? "on" : "demo";
  return { issuer, email: sa.client_email, clave: sa.private_key!, modo };
}

// ── firma RS256 con WebCrypto ───────────────────────────────────────
const b64url = (b: ArrayBuffer | Uint8Array) => {
  const u = new Uint8Array(b);
  let s = "";
  for (let i = 0; i < u.length; i++) s += String.fromCharCode(u[i]);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
};
const b64urlTxt = (s: string) => b64url(new TextEncoder().encode(s));

/* La clave de la cuenta de servicio viene en PEM PKCS#8 ("BEGIN PRIVATE
   KEY"). Importarla cuesta: se guarda por isolate, atada al PEM para que una
   clave rotada no siga firmando con la vieja. */
let claveCache: { pem: string; key: Promise<CryptoKey> } | null = null;
function claveRS256(pem: string) {
  if (claveCache?.pem === pem) return claveCache.key;
  const der = Uint8Array.from(atob(pem.replace(/-----[^-]+-----|\s/g, "")), (c) => c.charCodeAt(0));
  const key = crypto.subtle.importKey("pkcs8", der, { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
                                      false, ["sign"]);
  claveCache = { pem, key };
  key.catch(() => { if (claveCache?.key === key) claveCache = null; });
  return key;
}
async function firmar(claims: Record<string, unknown>, pem: string) {
  const datos = `${b64urlTxt(JSON.stringify({ alg: "RS256", typ: "JWT" }))}.${b64urlTxt(JSON.stringify(claims))}`;
  const firma = await crypto.subtle.sign("RSASSA-PKCS1-v1_5", await claveRS256(pem),
                                         new TextEncoder().encode(datos));
  return `${datos}.${b64url(firma)}`;
}

// ── Google: token OAuth y la API de objetos ─────────────────────────
/* El token vale una hora. Se guarda lo que viva el isolate: sin esto, cada
   toque son dos idas más a Google (firmar y pedir). */
let tok: { email: string; valor: string; vence: number } | null = null;
async function tokenGoogle(cfg: Cfg) {
  if (tok && tok.email === cfg.email && tok.vence > Date.now() + 60_000) return tok.valor;
  const ahora = Math.floor(Date.now() / 1000);
  const assertion = await firmar({
    iss: cfg.email, scope: "https://www.googleapis.com/auth/wallet_object.issuer",
    aud: "https://oauth2.googleapis.com/token", iat: ahora, exp: ahora + 3600,
  }, cfg.clave);
  const r = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({ grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer", assertion }),
    signal: AbortSignal.timeout(10_000),
  });
  const j = await r.json().catch(() => ({}));
  if (!r.ok || !j.access_token)
    throw new Error(`token de Google ${r.status}: ${j.error ?? ""} ${j.error_description ?? ""}`.trim());
  tok = { email: cfg.email, valor: j.access_token, vence: Date.now() + Number(j.expires_in || 3600) * 1000 };
  return tok.valor;
}

async function google(metodo: string, ruta: string, cuerpo: unknown, token: string) {
  const r = await fetch(`${WO}/${ruta}`, {
    method: metodo,
    headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
    body: JSON.stringify(cuerpo),
    signal: AbortSignal.timeout(10_000),
  });
  const j = await r.json().catch(() => null);
  // Un token que Google ya no acepta no se vuelve a usar: el próximo pide otro.
  if (r.status === 401) tok = null;
  return { status: r.status, j };
}
const fallaGoogle = (que: string, r: { status: number; j: any }) => {
  /* 403 casi siempre es configuración, no un tropiezo: la cuenta de servicio
     no está invitada como Developer en la consola de Wallet, o el issuer no
     es el suyo. Se dice en el log para que no haya que adivinarlo. */
  const pista = r.status === 403
    ? " (¿la cuenta de servicio está como Developer en la consola de Wallet y el ISSUER_ID es el de esa cuenta?)" : "";
  return new Error(`${que} ${r.status}: ${String(r.j?.error?.message ?? "").slice(0, 300)}${pista}`);
};

/* Lo que ya se mandó bien en este isolate no se repite. La clase se guarda
   con su contenido: si el organizador cambió la fecha o el afiche, el
   cuerpo es otro y se vuelve a mandar. */
const clasesHechas = new Map<string, string>();
const objetosHechos = new Set<string>();

/* La clase se REEMPLAZA entera (PUT) y no se parcha: así un afiche que el
   organizador sacó también sale del pase. Primero PUT porque es lo que pasa
   casi siempre (la clase ya existe desde el primer comprador); si no existe,
   404 y recién ahí se crea. Dos idas a Google sólo la primera vez. */
async function asegurarClase(clase: Record<string, unknown>, token: string) {
  const id = String(clase.id);
  const cuerpo = JSON.stringify(clase);
  if (clasesHechas.get(id) === cuerpo) return;
  let r = await google("PUT", `eventTicketClass/${encodeURIComponent(id)}`, clase, token);
  if (r.status === 404) {
    r = await google("POST", "eventTicketClass", clase, token);
    // Otro pedido la creó entre medio: con un PUT más queda al día.
    if (r.status === 409) r = await google("PUT", `eventTicketClass/${encodeURIComponent(id)}`, clase, token);
    if (r.status < 200 || r.status >= 300) throw fallaGoogle("clase", r);
  } else if (r.status < 200 || r.status >= 300) {
    /* La clase existe (no dio 404) y no se pudo poner al día: un 429 o un
       503 de Google. El pase se puede guardar igual con la versión que ya
       tiene, así que no se le corta el toque al comprador. No se anota como
       hecha: el próximo pedido vuelve a intentar el PUT. */
    console.warn(fallaGoogle("clase (sigue la vieja)", r).message);
    return;
  }
  clasesHechas.set(id, cuerpo);
}

/* El objeto se crea y listo: 409 es que ya existe, y lo que lleva (el QR,
   el nombre, el tipo) no cambia. Anular un pase cuando se anula la entrada
   es la versión 1.1 (una cola con trigger); mientras tanto la puerta es la
   que valida, igual que con una captura de pantalla de la entrada. */
async function asegurarObjeto(obj: Record<string, unknown>, token: string) {
  const id = String(obj.id);
  if (objetosHechos.has(id)) return;
  const r = await google("POST", "eventTicketObject", obj, token);
  if (r.status !== 409 && (r.status < 200 || r.status >= 300)) throw fallaGoogle("objeto", r);
  objetosHechos.add(id);
}

// ── el pase ─────────────────────────────────────────────────────────
const txt = (v: string) => ({ defaultValue: { language: IDIOMA, value: v } });
const https = (u: unknown): u is string => typeof u === "string" && /^https:\/\/[^\s]+$/.test(u);

/* Bolivia es UTC-4 todo el año, sin horario de verano: el huso va fijo.
   hora_fin casi siempre es 06:00 del día siguiente; una hora de fin que no
   es posterior a la de inicio es del otro día (la misma regla que el resto
   del sitio). */
const hms = (h: unknown) => String(h).slice(0, 8).padEnd(8, ":00");   // "21:00" → "21:00:00"
function horario(e: any) {
  const hi = hms(e.hora_inicio ?? "21:00");
  const ini = `${e.fecha}T${hi}-04:00`;
  let fin: string | null = null;
  if (e.hora_fin) {
    const hf = hms(e.hora_fin);
    let dia = String(e.fecha);
    if (hf <= hi) {
      const [a, m, d] = dia.split("-").map(Number);
      dia = new Date(Date.UTC(a, m - 1, d + 1)).toISOString().slice(0, 10);
    }
    fin = `${dia}T${hf}-04:00`;
  }
  return { start: ini, ...(fin ? { end: fin } : {}) };
}

function claseDelEvento(cfg: Cfg, e: any, org: any) {
  // Con la marca de título (0104) es la casa y la noche: "BOWIE · Crush", como /orden.
  const marca = org?.titulo_marca === true && !!org?.nombre;
  const nombre = marca ? `${String(org.nombre).toUpperCase()} · ${e.nombre}` : String(e.nombre);
  /* El banner (heroImage) es una franja apaisada, cerca de 3:1, a todo el
     ancho del frente del pase. Sólo el og (el afiche para compartir, que no
     es vertical) puede ir ahí. El flyer vertical NO es respaldo: recortado
     a una franja queda una tira del medio con el texto cortado, y hay
     muchos eventos sin og (los espejos de Puerta, por ejemplo). Sin og el
     pase va sin banner, con el color del evento y el logo. El flyer va
     siempre entero abajo, en los detalles. Cómo recorta Google el og
     cuadrado se mira en la prueba demo, antes de pedir producción. */
  const hero = https(e.og_url) ? e.og_url : null;
  const afiche = https(e.flyer_url) && e.flyer_url !== hero ? e.flyer_url : null;
  /* "Cómo llegar": el punto exacto si lo hay, si no el link del lugar que
     cargó el organizador (el mismo orden que la página del evento). */
  const mapa = e.lat != null && e.lng != null
    ? `https://www.google.com/maps/search/?api=1&query=${encodeURIComponent(`${e.lat},${e.lng}`)}`
    : https(e.maps_url) ? e.maps_url : null;
  const color = typeof e.color_fondo === "string" && /^#([0-9a-f]{3}|[0-9a-f]{6})$/i.test(e.color_fondo)
    ? e.color_fondo : FONDO;

  return {
    id: `${cfg.issuer}.${e.id}`,
    issuerName: "TICKETAZO",
    // underReview siempre, también al reemplazar una clase ya aprobada: es lo que pide Google.
    reviewStatus: "UNDER_REVIEW",
    eventId: String(e.id),
    eventName: txt(nombre),
    /* venue pide nombre Y dirección. Sin lugar no va (mejor nada que "a
       confirmar" grabado en el teléfono); sin dirección, el país, que nunca
       es mentira (no todos los eventos van a ser en Santa Cruz). */
    ...(e.lugar ? { venue: { name: txt(String(e.lugar)), address: txt(String(e.direccion || "Bolivia")) } } : {}),
    dateTime: horario(e),
    logo: { sourceUri: { uri: `${SITIO}/wallet/logo.png` }, contentDescription: txt("TICKETAZO") },
    ...(hero ? { heroImage: { sourceUri: { uri: hero }, contentDescription: txt(nombre) } } : {}),
    ...(afiche ? { imageModulesData: [{ id: "afiche", mainImage: { sourceUri: { uri: afiche },
                                                                   contentDescription: txt(`Afiche de ${nombre}`) } }] } : {}),
    ...(mapa ? { linksModuleData: { uris: [{ id: "mapa", uri: mapa, description: "Cómo llegar" }] } } : {}),
    hexBackgroundColor: color,
    countryCode: "BO",
    finePrint: txt("Cada entrada vale para un solo ingreso. La puerta la valida al escanear el QR."),
    /* Hoy el que compra 4 entradas les reenvía el link de /orden a sus
       amigos. Con el valor por omisión (un solo usuario por pase) el segundo
       que toca "Agregar" recibe un error de Google que no entiende. La puerta
       sigue siendo la que valida el ingreso único: un pase en dos teléfonos
       vale lo mismo que una captura de la entrada en dos teléfonos. */
    multipleDevicesAndHoldersAllowedStatus: "MULTIPLE_HOLDERS",
  };
}

/* Lo que va al pase de cada entrada. Fuera a propósito: el link a /orden
   (es la credencial de TODA la compra; con MULTIPLE_HOLDERS el amigo que
   guardó una vería las de todos), el precio (las cortesías valen 0 y en la
   puerta no aporta) y el recibo de la mesa (su QR no da ingreso, y un pase
   de Wallet se lee como "con esto entro"). */
function objetoDeEntrada(cfg: Cfg, e: any, o: any, x: any) {
  // La misma etiqueta que arma la función `orden` para /orden.
  const etiqueta = x.tipo_entrada?.categoria === "mesa" ? `Entrada · ${x.tipo_entrada.nombre}`
    : x.tipo_entrada?.nombre
      ?? ((x.mesas?.categoria === "lounge" ? "Lounge " : "Mesa ") + (x.mesas?.etiqueta ?? ""));
  const quien = String(o.comprador_nombre ?? "").trim();
  return {
    id: `${cfg.issuer}.${x.id}`,
    classId: `${cfg.issuer}.${e.id}`,
    state: "ACTIVE",
    // Idéntico a payload() de app/ticket.js: lo leen nuestra puerta y la de Plataforma Puerta.
    barcode: { type: "QR_CODE", value: `EVT:${e.id}:${x.code}`, alternateText: String(x.code) },
    ...(quien ? { ticketHolderName: quien } : {}),
    ...(String(etiqueta).trim() ? { ticketType: txt(String(etiqueta).trim()) } : {}),
    // El "Orden #XXXXXXXX" del pie de /orden: con eso la organización encuentra la compra.
    reservationInfo: { confirmationCode: String(o.id).slice(0, 8).toUpperCase() },
  };
}

// ── el pedido ───────────────────────────────────────────────────────
type Resultado =
  | { url: string; parte: number; partes: number; entradas: number }
  | { aviso: Aviso; status: number };

async function armar(id: string, parte: number): Promise<Resultado> {
  const cfg = configuracion();
  if ("falta" in cfg) {
    console.error(`wallet-google sin configurar: falta ${cfg.falta}`);
    return { aviso: "off", status: 503 };
  }
  const o = await uno(`ordenes?id=eq.${id}&select=id,estado,comprador_nombre,evento_id,organizador_id`);
  if (!o) return { aviso: "noexiste", status: 404 };
  if (o.estado !== "pagada") return { aviso: "pendiente", status: 409 };

  const [e, org, ent] = await Promise.all([
    uno(`eventos?id=eq.${o.evento_id}&select=id,nombre,lugar,direccion,fecha,hora_inicio,hora_fin,` +
        `color_fondo,og_url,flyer_url,maps_url,lat,lng`),
    // Con red, como en `orden`: sin el organizador el pase sale igual, sin la marca de título.
    uno(`organizadores?id=eq.${o.organizador_id}&select=nombre,titulo_marca`).catch(() => null),
    /* Sólo las válidas: una anulada no se ofrece, y una usada ya no tiene
       nada que hacer en un teléfono. El orden es el de /orden, con el id de
       desempate: las entradas de una compra nacen en la misma transacción
       con el mismo created_at, y sin desempate la tanda 2 podría repetir una
       de la tanda 1. */
    rest(`entradas?orden_id=eq.${id}&estado=eq.valida` +
         `&select=id,code,tipo_entrada(nombre,categoria),mesas(etiqueta,categoria)&order=created_at,id`),
  ]);
  if (!e) return { aviso: "noexiste", status: 404 };

  const h = horario(e);
  const termina = h.end ? Date.parse(h.end) : Date.parse(h.start) + 24 * 3600e3;
  if (Number.isFinite(termina) && Date.now() > termina + PASADO_MS) return { aviso: "pasado", status: 410 };

  const todas = (ent ?? []) as any[];
  const partes = Math.ceil(todas.length / TANDA);
  const tanda = todas.slice((parte - 1) * TANDA, parte * TANDA);
  if (!tanda.length) return { aviso: "nada", status: 409 };

  const token = await tokenGoogle(cfg);
  const clase = claseDelEvento(cfg, e, org);
  // La clase antes que los objetos: Google rechaza un objeto cuya clase no existe.
  await asegurarClase(clase, token);
  await Promise.all(tanda.map((x) => asegurarObjeto(objetoDeEntrada(cfg, e, o, x), token)));

  const jwt = await firmar({
    iss: cfg.email, aud: "google", typ: "savetowallet",
    iat: Math.floor(Date.now() / 1000),
    // Obligatorio en el JWT aunque con el link no se valide: sin esto el botón web de Google no se dibuja.
    origins: [SITIO],
    payload: { eventTicketObjects: tanda.map((x) => ({ id: `${cfg.issuer}.${x.id}`, classId: clase.id })) },
  }, cfg.clave);
  return { url: `https://pay.google.com/gp/v/save/${jwt}`, parte, partes, entradas: tanda.length };
}

const ES_UUID = (v: string) => /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(v);
const ir = (url: string) =>
  new Response(null, { status: 302, headers: { ...CORS, Location: url, "Cache-Control": "no-store" } });

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  const u = new URL(req.url);

  if (u.searchParams.has("estado")) {
    const cfg = configuracion();
    const ok = !("falta" in cfg);
    /* Cinco minutos de caché en el navegador, pero sólo para la respuesta
       final (configurado y en "on"): la página lo pregunta en cada carga y
       eso ya no cambia. Un "no configurado" o un "demo" se cachearían
       justo en el momento en que alguien carga los secrets o prende el modo
       y prueba enseguida: vería el botón ausente cinco minutos sin motivo. */
    const fijo = ok && (cfg as Cfg).modo === "on";
    return new Response(JSON.stringify({ ok: true, configurado: ok, modo: ok ? (cfg as Cfg).modo : null }), {
      headers: { ...CORS, "Content-Type": "application/json",
                 "Cache-Control": fijo ? "public, max-age=300" : "no-store" },
    });
  }

  const id = String(u.searchParams.get("orden") ?? "").trim().toLowerCase();
  /* Un GET no arma el pase nunca (ver arriba: los escáneres de links). Lo
     manda a la página de la compra, donde el botón está a un toque. */
  if (req.method !== "POST") return ir(ES_UUID(id) ? `${SITIO}/orden/?id=${id}#wallet` : `${SITIO}/orden/`);

  const parte = Number(u.searchParams.get("parte") ?? "1");
  if (!ES_UUID(id) || !Number.isInteger(parte) || parte < 1 || parte > 100)
    return json({ ok: false, aviso: "noexiste", motivo: MOTIVO.noexiste }, 400);

  let r: Resultado;
  try {
    r = await armar(id, parte);
  } catch (err) {
    console.error("wallet-google:", String((err as Error).message ?? err));
    r = { aviso: "error", status: 502 };
  }
  if ("url" in r) return json({ ok: true, ...r });
  return json({ ok: false, aviso: r.aviso, motivo: MOTIVO[r.aviso] }, r.status);
});
