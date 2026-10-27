/* entrada — la entrada del correo, dibujada en el servidor con el MISMO
   ticket.js de /orden.

   El 26/10 el correo empezó a llevar el QR de cada entrada adentro (una
   tabla de celdas en enviar-entradas), y el dueño lo recibió y dijo que
   "llegó pero no con el diseño que tiene la entrada de cada evento". Tiene
   razón: lo que se compra es la pieza con el arte del organizador, la que
   se ve en /orden, y en la fila de la puerta una tabla blanca y negra no se
   parece en nada a la entrada que se promocionó.

   Por qué acá y no en una Edge Function de Supabase (lo midió invA el
   26/10, con los artes reales):
     · El dibujo es ticket.js y tiene que seguir siendo UNO solo. Una copia
       en otra API (imagescript, satori) es la forma más segura de que dentro
       de un mes el correo y /orden digan cosas distintas, que es justo lo
       que ticket.js vino a cortar.
     · ticket.js necesita un Canvas2D completo (roundRect, sombras,
       textAlign/textBaseline, measureText, WebP). En Deno el único es
       CanvasKit en WASM: ignora textAlign y textBaseline (el código salía
       corrido y cortado), no trae roundRect, pesa 8 MB y una orden de diez
       se pasaba de los 2 s de CPU de una función de Supabase.
     · @napi-rs/canvas es Skia nativo, el mismo motor del canvas de Chrome:
       sale casi píxel a píxel igual a /orden (hasta la negrita sintética de
       DM Mono) en ~30 ms por entrada. Supabase no corre addons nativos;
       una función de Vercel en Node sí, y vive en el mismo deploy que
       ticket.js: el correo y /orden siempre dibujan con el mismo commit.

   Esto NO lee la base ni tiene ninguna clave de Supabase: dibuja lo que le
   mandan. Y solo si se lo manda enviar-entradas, firmado con ENTRADA_FIRMA
   (HMAC-SHA256 de "<ts>.<cuerpo>", con ±5 min de ventana). Sin firma no
   dibuja: si cualquiera pudiera pedir una entrada linda con el código que
   quisiera, esto sería una imprenta de entradas truchas con nuestro diseño.
   Sin el secret cargado responde 503 y el correo sale con el QR en tabla,
   como antes: se despliega apagado y se prende cargando el secret. */
import fs from "node:fs";
import crypto from "node:crypto";
import { fileURLToPath } from "node:url";
import { createCanvas, Image as ImagenNativa, GlobalFonts, loadImage } from "@napi-rs/canvas";
import qrcode from "qrcode-generator";

const aca = (p) => fileURLToPath(new URL(p, import.meta.url));

/* ── las fuentes ──
   En una función de Vercel no hay fuentes del sistema: lo que no esté
   registrado sale en cuadraditos. Son las mismas caras que /orden pide a
   Google Fonts (las de TICKETAZO y las de Puerta), en TTF estáticas para
   no depender de Google en cada arranque. DM Mono se pide en 700 y no
   existe: Skia, como Chrome, usa la 500 con negrita sintética. */
const FUENTES = [
  ["Big Shoulders Display", "BigShouldersDisplay-800.ttf"],
  ["DM Mono", "DMMono-400.ttf"],
  ["DM Mono", "DMMono-500.ttf"],
  ["Inter", "Inter-500.ttf"],
  ["Inter Tight", "InterTight-500.ttf"],
  ["Inter Tight", "InterTight-600.ttf"],
  ["Space Grotesk", "SpaceGrotesk-700.ttf"],
];
/* Si una no se carga, registerFromPath devuelve null y NO tira: sin esto
   la función seguía y respondía 200 con una entrada a la que le faltaba
   todo el texto (el código, el nombre, la fecha, "powered by"), y
   enviar-entradas la adjuntaba como buena en todas las ventas. Pasa si el
   deploy no trae api/_fuentes (el includeFiles de vercel.json) o si se
   cambia una ruta. Las que faltan se anotan acá y el POST responde 503
   con sus nombres: el correo cae al QR en tabla y queda en el log. */
const FUENTES_FALTAN = FUENTES
  .filter(([familia, archivo]) => GlobalFonts.registerFromPath(aca(`./_fuentes/${archivo}`), familia) == null)
  .map(([, archivo]) => archivo);
if (FUENTES_FALTAN.length)
  console.error(`entrada: no se cargaron ${FUENTES_FALTAN.join(", ")}; responde 503 hasta el próximo deploy`);

/* ── el arte ──
   Solo de los dos buckets públicos de donde sale el arte de verdad: el
   nuestro y el de Plataforma Puerta (Bowie y BurTown traen el suyo). Con
   la firma alcanzaría, pero si algún día se filtra el secreto esto no tiene
   que servir para pegarle a cualquier URL desde adentro de Vercel. Cualquier
   otra cosa se trata como arte que no cargó: ticket.js dibuja la entrada
   propia, con el mismo QR. */
const ORIGENES_ARTE = [
  "https://mjotxzcddhqqpuhkcetl.supabase.co/storage/v1/object/public/arte/",
  "https://kdkjmqrbiszmkcprinir.supabase.co/storage/v1/object/public/disenos/",
];
const ARTE_TOPE = 10 * 1024 * 1024;   // el PNG más pesado de hoy (Dark Garden) son 2,2 MB
const ARTE_ESPERA_MS = 4000;          // ticket.js espera 8 s; enviar-entradas espera menos

function arteAdmitido(u) {
  let url;
  try { url = new URL(u); } catch { return null; }
  if (url.protocol !== "https:" || url.username || url.password) return null;
  // URL ya resolvió los ".." y los %2e: se compara el camino normalizado.
  return ORIGENES_ARTE.some((p) => (url.origin + url.pathname).startsWith(p)) ? url.href : null;
}

/* Una orden de diez son diez pedidos con el mismo arte, y la instancia se
   reusa entre pedidos: sin esto se bajaba el mismo PNG de 2 MB diez veces,
   y eso es egress del bucket. Storage sirve no-cache con etag, así que pasado
   un minuto se revalida con If-None-Match (un 304 sin cuerpo). Los pedidos
   que llegan juntos esperan la misma descarga. */
const artes = new Map();       // url → { etag, buf, visto }
const bajando = new Map();     // url → Promise<Buffer>
const ARTES_MAX = 24, ARTE_FRESCO_MS = 60_000;

function arte(url) {
  const previo = artes.get(url);
  if (previo && Date.now() - previo.visto < ARTE_FRESCO_MS) return Promise.resolve(previo.buf);
  if (bajando.has(url)) return bajando.get(url);
  const p = (async () => {
    let r;
    try {
      r = await fetch(url, {
        headers: previo?.etag ? { "If-None-Match": previo.etag } : {},
        redirect: "error",
        signal: AbortSignal.timeout(ARTE_ESPERA_MS),
      });
    } catch (e) {
      // Un corte al revalidar no le saca el arte a una entrada que ya lo tenía.
      if (previo) return previo.buf;
      throw e;
    }
    if (r.status === 304 && previo) { previo.visto = Date.now(); return previo.buf; }
    if (!r.ok) throw new Error(`el arte respondió ${r.status}`);
    if (Number(r.headers.get("content-length") || 0) > ARTE_TOPE) throw new Error("el arte pesa demasiado");
    const buf = Buffer.from(await r.arrayBuffer());
    if (buf.length > ARTE_TOPE) throw new Error("el arte pesa demasiado");
    artes.delete(url);
    artes.set(url, { etag: r.headers.get("etag"), buf, visto: Date.now() });
    if (artes.size > ARTES_MAX) artes.delete(artes.keys().next().value);
    return buf;
  })().finally(() => bajando.delete(url));
  bajando.set(url, p);
  return p;
}

/* ticket.js hace `new Image()`, le pone onload/onerror y le asigna la URL.
   La Image de Skia acepta bytes y no URLs: esto baja el arte y recién ahí
   se lo pasa. El resto es la Image nativa, con su naturalWidth y su
   decodificador de JPG, PNG y WebP (RED CIRCLE es WebP). */
class Imagen extends ImagenNativa {
  set src(v) {
    if (typeof v !== "string") { super.src = v; return; }
    const url = arteAdmitido(v);
    const fallar = (e) => { if (typeof this.onerror === "function") this.onerror(e); };
    if (!url) { queueMicrotask(() => fallar(new Error("arte fuera de los buckets"))); return; }
    arte(url).then((buf) => { try { super.src = buf; } catch (e) { fallar(e); } }, fallar);
  }
  get src() { return super.src; }
}

/* ── ticket.js, tal cual ──
   Se lee del mismo deploy (vercel.json lo incluye en la función) y se
   corre con un document y un window de mentira: lo único que usa del
   navegador al dibujar es crear canvas y pedir fuentes, y las fuentes ya
   están registradas arriba. No se le cambia una línea: si /orden cambia
   el dibujo, el correo cambia con él en el mismo deploy. */
const documento = {
  createElement(tag) {
    if (tag !== "canvas") throw new Error(`ticket.js pidió un <${tag}> en el servidor`);
    return createCanvas(1, 1);
  },
  fonts: { load: async () => [], ready: Promise.resolve() },
};
const ticket = {};
new Function("window", "document", "Image", "qrcode", "navigator",
  fs.readFileSync(new URL("../ticket.js", import.meta.url), "utf8"))(ticket, documento, Imagen, qrcode, {});

/* ── lo que se recibe ──
   Viene firmado, así que esto no es una defensa contra el que firma: es
   para que un dato raro (un nombre de 5.000 letras, un emoji) no deje una
   entrada rota. Los emoji de presentación no los tiene ninguna de las
   siete fuentes y salen en cuadraditos: hoy solo los usan fases de Puerta
   ("Pre Venta 2️⃣"), que como tienen arte propio no llevan sello, pero el
   día que una no lo traiga el sello diría "PRE VENTA 2" y no "PRE VENTA 2□□". */
const SIN_DIBUJO = /[\p{Emoji_Presentation}\p{Emoji_Modifier}‍️⃣]/gu;
function texto(v, max = 200) {
  if (v == null) return v;
  const s = String(v).slice(0, max), limpio = s.replace(SIN_DIBUJO, "");
  // Solo se toca lo que tenía emoji: el resto va letra por letra como en /orden.
  return limpio === s ? s : limpio.replace(/\s+/g, " ").trim();
}
const urlArte = (v) => (typeof v === "string" && v.length < 2000 ? v : null);

function leerPedido(j) {
  const t = j?.t, e = j?.evento, f = j?.fase;
  if (!t || !e) return null;
  if (typeof t.code !== "string" || !/^[A-Za-z0-9_-]{1,64}$/.test(t.code)) return null;
  if (typeof e.id !== "string" || !/^[0-9a-f-]{36}$/i.test(e.id)) return null;
  return {
    t: { code: t.code, cliente: texto(t.cliente), etiqueta: texto(t.etiqueta ?? ""),
         rotulo: texto(t.rotulo) || undefined },
    evento: { id: e.id, marca_1: texto(e.marca_1 ?? ""), marca_2: texto(e.marca_2 ?? ""),
              lugar: texto(e.lugar ?? ""), fecha_txt: texto(e.fecha_txt ?? ""),
              arte_url: urlArte(e.arte_url), entrada_puerta: e.entrada_puerta === true },
    fase: f ? { nombre: texto(f.nombre ?? ""), arte_url: urlArte(f.arte_url),
                sello: f.sello ? texto(f.sello) : null } : null,
    tope: Number.isFinite(j.tope) && j.tope > 0 ? Math.floor(j.tope) : 0,
  };
}

/* ── el peso ──
   La entrada de /orden es un JPEG de 1000 px a calidad 92: 150 a 360 KB.
   Para una entrada da igual; diez en un mismo correo son más de 3 MB, que
   con datos móviles en la fila es mucho. enviar-entradas manda cuánto le
   toca a cada una (`tope`) y, si se pasa, se achica la MISMA imagen: mismo
   dibujo, menos píxeles. 560 px sigue dejando el QR en ~290 px, más de
   8 px por módulo, de sobra para el lector de la puerta. */
const PASOS = [[800, 86], [720, 82], [640, 78], [560, 74], [560, 66]];

async function aligerar(buf, tope) {
  const img = await loadImage(buf);
  let out = null, w = img.width, h = img.height;
  for (const [ancho, calidad] of PASOS) {
    w = Math.min(ancho, img.width); h = Math.round(img.height * w / img.width);
    const c = createCanvas(w, h), x = c.getContext("2d");
    x.imageSmoothingQuality = "high";
    x.drawImage(img, 0, 0, w, h);
    out = await c.encode("jpeg", calidad);
    if (out.length <= tope) break;
  }
  return { buf: out, tipo: "image/jpeg", ancho: w, alto: h };
}

// Ancho y alto sin decodificar: el correo los usa para reservar el lugar.
function medidas(b) {
  if (b[0] === 0x89 && b[1] === 0x50) return { ancho: b.readUInt32BE(16), alto: b.readUInt32BE(20) };
  for (let i = 2; i + 9 < b.length;) {
    if (b[i] !== 0xff) return null;
    const m = b[i + 1], largo = b.readUInt16BE(i + 2);
    if (m >= 0xc0 && m <= 0xcf && m !== 0xc4 && m !== 0xc8 && m !== 0xcc)
      return { alto: b.readUInt16BE(i + 5), ancho: b.readUInt16BE(i + 7) };
    i += 2 + largo;
  }
  return null;
}

/* ── la firma ── */
const VENTANA_S = 300;
function firmaValida(secreto, ts, cuerpo, firma) {
  if (!/^\d{9,11}$/.test(ts || "") || !/^[0-9a-f]{64}$/.test(firma || "")) return false;
  if (Math.abs(Date.now() / 1000 - Number(ts)) > VENTANA_S) return false;
  const esperada = crypto.createHmac("sha256", secreto).update(`${ts}.`).update(cuerpo).digest();
  return crypto.timingSafeEqual(esperada, Buffer.from(firma, "hex"));
}

const respuesta = (cuerpo, status, extra = {}) =>
  new Response(cuerpo, { status, headers: { "Cache-Control": "no-store", ...extra } });
const error = (motivo, status) =>
  respuesta(JSON.stringify({ ok: false, motivo }), status, { "Content-Type": "application/json" });

/* Handler web (Request → Response) y no (req, res): con (req, res) Vercel
   ya parseó el JSON antes de llegar acá, y la firma se verifica sobre los
   bytes exactos que se firmaron, no sobre un JSON vuelto a armar. */
export async function POST(request) {
  const secreto = process.env.ENTRADA_FIRMA;
  if (!secreto) return error("La entrada del correo no está configurada.", 503);
  const cuerpo = Buffer.from(await request.arrayBuffer());
  if (cuerpo.length > 16_384) return error("Pedido demasiado grande.", 413);
  if (!firmaValida(secreto, request.headers.get("x-ts"), cuerpo, request.headers.get("x-firma")))
    return error("Firma inválida.", 401);
  // Después de la firma: al que no firma no le contamos qué archivos tenemos.
  if (FUENTES_FALTAN.length)
    return error(`Faltan fuentes en el deploy: ${FUENTES_FALTAN.join(", ")}.`, 503);

  let pedido;
  try { pedido = leerPedido(JSON.parse(cuerpo.toString("utf8"))); } catch { pedido = null; }
  if (!pedido) return error("Faltan datos de la entrada.", 400);

  try {
    const url = await ticket.dibujarTicket(pedido.t, pedido.evento, pedido.fase);
    const coma = url.indexOf(",");
    let buf = Buffer.from(url.slice(coma + 1), "base64");
    let tipo = url.slice(5, url.indexOf(";"));
    // ticket.js saca JPEG sobre el arte y PNG en la entrada propia: si se
    // pidió con arte y salió PNG, el arte no cargó (enviar-entradas lo anota).
    const variante = tipo === "image/jpeg" ? "arte" : "propia";
    let m = medidas(buf);
    if (pedido.tope && buf.length > pedido.tope) {
      const a = await aligerar(buf, pedido.tope);
      buf = a.buf; tipo = a.tipo; m = { ancho: a.ancho, alto: a.alto };
    }
    return respuesta(buf, 200, {
      "Content-Type": tipo,
      "X-Entrada-Variante": variante,
      // Para scripts/probar-entrada.mjs: el deploy trae las fuentes y este control.
      "X-Entrada-Fuentes": `${FUENTES.length}/${FUENTES.length}`,
      ...(m ? { "X-Entrada-Ancho": String(m.ancho), "X-Entrada-Alto": String(m.alto) } : {}),
    });
  } catch (e) {
    console.error("no se pudo dibujar la entrada:", e?.message ?? e);
    return error("No se pudo dibujar la entrada.", 500);
  }
}

export function GET() {
  return error("Usá POST.", 405);
}
