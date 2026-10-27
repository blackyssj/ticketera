/* enviar-entradas — el correo con las entradas y el link a /orden.
   Cada entrada va adentro del correo: desde el 27/10 como la imagen de
   /orden, con el arte del evento (la dibuja app/api/entrada.js en Vercel con
   el mismo ticket.js), y si esa imagen no llega, con su QR en una tabla
   (26/10). El link sigue: sirve cuando el comprador borra el correo o
   cambia de teléfono, y tiene todas las entradas.
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

/* ── el QR del recibo, dibujado en el correo ──
   El dueño pidió que al correo llegue "el QR de la mesa" (0108), no solo
   el link. Una imagen pediría armar un PNG acá o servirlo desde otra
   función con una URL pública, y un servicio de QR de afuera vería el
   código de cada mesa. Así que se arma la matriz acá —las funciones no
   importan nada, ver comun.ts— y se dibuja como una tabla de celdas negras
   y blancas, que es lo que Gmail, Outlook y Apple Mail muestran igual.
   Lo mismo para las entradas que trae la mesa (ver correoMesa); las de
   una compra de entradas siguen yendo por el link, como siempre.

   Es un QR mínimo y estándar: modo byte, corrección M, versiones 1 a 10
   (el payload `EVT:<uuid>:MESA…` son 53 bytes y entra en la 4). Sigue al
   pie de la letra la construcción de Nayuki (QR Code generator library,
   MIT), que es la referencia más leída. Se probó leyéndolo con jsQR, el
   mismo lector de la puerta. */
const QR_ECC = [10, 16, 26, 18, 24, 16, 18, 22, 22, 26];   // por bloque, nivel M, v1..v10
const QR_BLOQUES = [1, 1, 1, 2, 2, 4, 4, 4, 5, 5];

function qrMul(x: number, y: number): number {
  let z = 0;
  for (let i = 7; i >= 0; i--) {
    z = (z << 1) ^ ((z >>> 7) * 0x11d);
    z ^= ((y >>> i) & 1) * x;
  }
  return z;
}
function qrDivisor(grado: number): number[] {
  const r = new Array(grado).fill(0);
  r[grado - 1] = 1;
  let raiz = 1;
  for (let i = 0; i < grado; i++) {
    for (let j = 0; j < r.length; j++) {
      r[j] = qrMul(r[j], raiz);
      if (j + 1 < r.length) r[j] ^= r[j + 1];
    }
    raiz = qrMul(raiz, 0x02);
  }
  return r;
}
function qrResto(datos: number[], div: number[]): number[] {
  const r = new Array(div.length).fill(0);
  for (const b of datos) {
    const f = b ^ (r.shift() as number);
    r.push(0);
    div.forEach((c, i) => { r[i] ^= qrMul(c, f); });
  }
  return r;
}
function qrModulosCrudos(v: number): number {
  let r = (16 * v + 128) * v + 64;
  if (v >= 2) {
    const n = Math.floor(v / 7) + 2;
    r -= (25 * n - 10) * n - 55;
    if (v >= 7) r -= 36;
  }
  return r;
}
function qrAlineacion(v: number, lado: number): number[] {
  if (v === 1) return [];
  const n = Math.floor(v / 7) + 2;
  const paso = Math.ceil((v * 4 + 4) / (n * 2 - 2)) * 2;
  const r = [6];
  for (let p = lado - 7; r.length < n; p -= paso) r.splice(1, 0, p);
  return r;
}

/** La matriz del QR: true = módulo negro. Null si no entra en la versión 10. */
function qrMatriz(texto: string): boolean[][] | null {
  const bytes = Array.from(new TextEncoder().encode(texto));
  let v = 0, cap = 0;
  for (let i = 1; i <= 10; i++) {
    cap = Math.floor(qrModulosCrudos(i) / 8) - QR_ECC[i - 1] * QR_BLOQUES[i - 1];
    if (4 + (i < 10 ? 8 : 16) + bytes.length * 8 <= cap * 8) { v = i; break; }
  }
  if (!v) return null;

  // el chorro de bits: modo byte, largo, datos, terminador y relleno
  const bits: number[] = [];
  const poner = (val: number, n: number) => { for (let i = n - 1; i >= 0; i--) bits.push((val >>> i) & 1); };
  poner(4, 4);
  poner(bytes.length, v < 10 ? 8 : 16);
  bytes.forEach((b) => poner(b, 8));
  poner(0, Math.min(4, cap * 8 - bits.length));
  poner(0, (8 - bits.length % 8) % 8);
  for (let p = 0xec; bits.length < cap * 8; p ^= 0xec ^ 0x11) poner(p, 8);
  const datos: number[] = [];
  for (let i = 0; i < bits.length; i += 8)
    datos.push(bits.slice(i, i + 8).reduce((a, b) => (a << 1) | b, 0));

  // bloques con su corrección, entrelazados
  const nb = QR_BLOQUES[v - 1], ecc = QR_ECC[v - 1];
  const crudos = Math.floor(qrModulosCrudos(v) / 8);
  const cortos = nb - crudos % nb, largoCorto = Math.floor(crudos / nb);
  const div = qrDivisor(ecc);
  const bloques: number[][] = [];
  for (let i = 0, k = 0; i < nb; i++) {
    const d = datos.slice(k, k + largoCorto - ecc + (i < cortos ? 0 : 1));
    k += d.length;
    const e = qrResto(d, div);
    if (i < cortos) d.push(0);
    bloques.push(d.concat(e));
  }
  const final: number[] = [];
  for (let i = 0; i < bloques[0].length; i++)
    for (let j = 0; j < bloques.length; j++)
      if (i !== largoCorto - ecc || j >= cortos) final.push(bloques[j][i]);

  // la matriz: patrones fijos primero, marcados como "de función"
  const lado = v * 4 + 17;
  const m: boolean[][] = Array.from({ length: lado }, () => new Array(lado).fill(false));
  const fn: boolean[][] = Array.from({ length: lado }, () => new Array(lado).fill(false));
  const fijo = (x: number, y: number, negro: boolean) => { m[y][x] = negro; fn[y][x] = true; };
  for (let i = 0; i < lado; i++) { fijo(6, i, i % 2 === 0); fijo(i, 6, i % 2 === 0); }
  for (const [cx, cy] of [[3, 3], [lado - 4, 3], [3, lado - 4]]) {
    for (let dy = -4; dy <= 4; dy++) for (let dx = -4; dx <= 4; dx++) {
      const d = Math.max(Math.abs(dx), Math.abs(dy)), x = cx + dx, y = cy + dy;
      if (x >= 0 && x < lado && y >= 0 && y < lado) fijo(x, y, d !== 2 && d !== 4);
    }
  }
  const al = qrAlineacion(v, lado);
  al.forEach((a, i) => al.forEach((b, j) => {
    if ((i === 0 && j === 0) || (i === 0 && j === al.length - 1) || (i === al.length - 1 && j === 0)) return;
    for (let dy = -2; dy <= 2; dy++) for (let dx = -2; dx <= 2; dx++)
      fijo(a + dx, b + dy, Math.max(Math.abs(dx), Math.abs(dy)) !== 1);
  }));
  const formato = (mask: number) => {
    const d = (0 << 3) | mask;                    // nivel M = 00
    let r = d;
    for (let i = 0; i < 10; i++) r = (r << 1) ^ ((r >>> 9) * 0x537);
    const b = ((d << 10) | r) ^ 0x5412;
    const bit = (i: number) => ((b >>> i) & 1) !== 0;
    for (let i = 0; i <= 5; i++) fijo(8, i, bit(i));
    fijo(8, 7, bit(6)); fijo(8, 8, bit(7)); fijo(7, 8, bit(8));
    for (let i = 9; i < 15; i++) fijo(14 - i, 8, bit(i));
    for (let i = 0; i < 8; i++) fijo(lado - 1 - i, 8, bit(i));
    for (let i = 8; i < 15; i++) fijo(8, lado - 15 + i, bit(i));
    fijo(8, lado - 8, true);
  };
  formato(0);
  if (v >= 7) {
    let r = v;
    for (let i = 0; i < 12; i++) r = (r << 1) ^ ((r >>> 11) * 0x1f25);
    const b = (v << 12) | r;
    for (let i = 0; i < 18; i++) {
      const negro = ((b >>> i) & 1) !== 0, a = lado - 11 + (i % 3), c = Math.floor(i / 3);
      fijo(a, c, negro); fijo(c, a, negro);
    }
  }

  // los datos, en zigzag de abajo a la derecha, salteando la columna 6
  let n = 0;
  for (let der = lado - 1; der >= 1; der -= 2) {
    if (der === 6) der = 5;
    for (let vert = 0; vert < lado; vert++) for (let j = 0; j < 2; j++) {
      const x = der - j, sube = ((der + 1) & 2) === 0, y = sube ? lado - 1 - vert : vert;
      if (!fn[y][x] && n < final.length * 8) {
        m[y][x] = ((final[n >>> 3] >>> (7 - (n & 7))) & 1) !== 0;
        n++;
      }
    }
  }

  // la máscara que menos castiga (las cuatro reglas del estándar)
  const enmascarar = (k: number) => {
    for (let y = 0; y < lado; y++) for (let x = 0; x < lado; x++) {
      if (fn[y][x]) continue;
      const s = [(x + y) % 2, y % 2, x % 3, (x + y) % 3, (Math.floor(x / 3) + Math.floor(y / 2)) % 2,
                 (x * y) % 2 + (x * y) % 3, ((x * y) % 2 + (x * y) % 3) % 2,
                 ((x + y) % 2 + (x * y) % 3) % 2][k];
      if (s === 0) m[y][x] = !m[y][x];
    }
  };
  const castigo = () => {
    let p = 0, negros = 0;
    const lineas: boolean[][] = [];
    for (let i = 0; i < lado; i++) { lineas.push(m[i]); lineas.push(m.map((f) => f[i])); }
    for (const l of lineas) {
      let corrida = 1;
      for (let i = 1; i <= lado; i++) {
        if (i < lado && l[i] === l[i - 1]) corrida++;
        else { if (corrida >= 5) p += corrida - 2; corrida = 1; }
      }
      const s = l.map((b) => (b ? "1" : "0")).join("");
      for (const pat of ["10111010000", "00001011101"])
        for (let i = s.indexOf(pat); i >= 0; i = s.indexOf(pat, i + 1)) p += 40;
    }
    for (let y = 0; y < lado; y++) for (let x = 0; x < lado; x++) {
      if (m[y][x]) negros++;
      if (y < lado - 1 && x < lado - 1 && m[y][x] === m[y][x + 1] && m[y][x] === m[y + 1][x]
          && m[y][x] === m[y + 1][x + 1]) p += 3;
    }
    return p + Math.floor(Math.abs(negros * 20 - lado * lado * 10) / (lado * lado)) * 10;
  };
  let mejor = 0, menor = Infinity;
  for (let k = 0; k < 8; k++) {
    enmascarar(k); formato(k);
    const c = castigo();
    if (c < menor) { menor = c; mejor = k; }
    enmascarar(k);                      // la máscara es un XOR: se deshace igual
  }
  enmascarar(mejor); formato(mejor);
  return m;
}

/** El QR como tabla HTML. El margen blanco de 4 módulos que pide el
    estándar (sin él la cámara no lo encuentra sobre el violeta del correo)
    va como relleno de la tabla de afuera y no como celdas: el correo entero
    tiene que quedar lejos de los 102 KB en los que Gmail lo corta.

    Por lo mismo, cada fila va por tramos: los módulos seguidos del mismo
    color son UNA celda con colspan. Una celda por módulo eran ~40 KB por
    QR, y con las entradas de la mesa en el correo (cada una con el suyo)
    ya con la segunda se pasaba del corte. La primera fila sí va módulo por
    módulo y con su ancho: es la que fija cuánto mide cada columna, y sin
    ella una celda vacía con colspan no tiene de dónde sacarlo. El alto va
    en la primera celda de cada fila: la fila mide lo de su celda más alta. */
function qrTabla(texto: string, px = 5): string {
  const m = qrMatriz(texto);
  if (!m) return "";
  const filas = m.map((f, y) => {
    let tr = "";
    for (let x = 0; x < f.length;) {
      let k = 1;
      if (y > 0) while (x + k < f.length && f[x + k] === f[x]) k++;
      tr += `<td${k > 1 ? ` colspan="${k}"` : ""}${y === 0 ? ` width="${px}"` : ""}` +
        `${x === 0 ? ` height="${px}"` : ""}${f[x] ? ` bgcolor="black"` : ""}></td>`;
      x += k;
    }
    return `<tr>${tr}</tr>`;
  }).join("");
  const lado = m.length * px;
  return `<table role="presentation" cellpadding="${4 * px}" cellspacing="0" border="0" bgcolor="#FFFFFF" ` +
    `style="background:#FFFFFF;border-radius:6px"><tr><td>` +
    `<table role="presentation" cellpadding="0" cellspacing="0" border="0" width="${lado}" ` +
    `style="width:${lado}px;border-collapse:collapse;line-height:0;font-size:0">${filas}</table>` +
    `</td></tr></table>`;
}

/* ── la entrada con el arte del evento (27/10) ──
   El QR en tabla del 26/10 llegó, y el dueño lo miró y dijo que "llegó
   pero no con el diseño que tiene la entrada de cada evento": lo que se
   compra es la pieza con el arte del organizador, la de /orden. Esa imagen
   la dibuja app/api/entrada.js (una función de Vercel en Node) corriendo
   el MISMO ticket.js; acá no se puede, porque ticket.js necesita un canvas
   de verdad y en una Edge Function no hay ninguno que lo dibuje igual (ver
   el comentario de arriba de ese archivo).

   Va adjunta e inline (cid), no como <img src="https://…">: el adjunto
   viaja ADENTRO del mensaje, así que el teléfono que bajó el correo la
   muestra sin señal en la fila, que fue la razón de meter los QR en el
   correo. Y una imagen remota la bloquean varios clientes hasta que uno
   toca "mostrar imágenes".

   Nada de esto puede trabar un correo, y menos una venta:
     · sin ENTRADA_FIRMA no se intenta (se despliega apagado y se prende
       cargando el secret, acá y en Vercel);
     · cada entrada tiene su tope de tiempo y todas juntas otro: la que no
       llegue a tiempo, o falle, va con su QR en tabla como el 26/10;
     · si Resend rechaza el correo con adjuntos, sale otra vez sin ellos.
   Los datos del dibujo se le piden a la función `orden`, la misma que usa
   /orden: marca, fecha_txt, la fase con su sello, si es una fecha de
   Puerta. Copiar ese armado acá era la forma segura de que el correo y la
   página dibujaran entradas distintas. */
const FIRMA = Deno.env.get("ENTRADA_FIRMA");
const RENDER = Deno.env.get("ENTRADA_RENDER_URL") ?? `${SITIO}/api/entrada`;
const IMG_ESPERA_MS = 8_000;    // una entrada; el arranque en frío de la de Vercel es 1-2 s
const IMG_TOTAL_MS = 15_000;    // todas juntas: el botón "reenviar" del panel espera esto
const IMG_A_LA_VEZ = 4;
/* Lo que pesan todas las imágenes de un correo, más o menos. Una entrada
   de /orden pesa 150-440 KB y con una o dos va tal cual; con diez, cada una
   se achica (mismo dibujo, menos píxeles) para que el correo no pase de
   ~1 MB, que en la fila se baja con datos móviles. */
const PESO_IMAGENES = 900_000;
/* El ancho de la columna del correo (520 menos 28 de cada lado). Con 300
   el QR adentro de la imagen quedaba en ~130 px, más chico que el de la
   tabla del 26/10 (165): el guardia tenía que acercar el lector, en la fila
   y de noche. Las imágenes miden 560-1000 px, así que no pierden nitidez; en
   el teléfono el max-width la lleva al ancho que haya. */
const ANCHO_ENTRADA = 464;

/* conArte: si salió sobre el arte del evento o la propia de TICKETAZO
   (X-Entrada-Variante). La propia es la que corresponde a un evento sin
   arte, y la que sale cuando el arte no llegó a tiempo. */
type Imagen = { cid: string; tipo: string; bytes: Uint8Array; ancho: number; alto: number; conArte: boolean };

const hex = (b: ArrayBuffer) => Array.from(new Uint8Array(b), (x) => x.toString(16).padStart(2, "0")).join("");
let llave: Promise<CryptoKey> | null = null;
function firmar(ts: string, cuerpo: string): Promise<string> {
  llave ??= crypto.subtle.importKey("raw", new TextEncoder().encode(FIRMA!),
    { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  return llave.then((k) => crypto.subtle.sign("HMAC", k, new TextEncoder().encode(`${ts}.${cuerpo}`))).then(hex);
}

/** Las imágenes de las entradas `codes`, por código. Las que no llegan no
    están en el mapa: esas van con el QR en tabla. Nunca tira. */
async function imagenesDeEntradas(ordenId: string, codes: string[]): Promise<Map<string, Imagen>> {
  const out = new Map<string, Imagen>();
  if (!FIRMA || !codes.length) return out;
  const hasta = Date.now() + IMG_TOTAL_MS;
  let d: any;
  try {
    const r = await fetch(`${SB}/functions/v1/orden`, {
      method: "POST", headers: H, body: JSON.stringify({ orden: ordenId }), signal: AbortSignal.timeout(6_000),
    });
    d = await r.json();
    if (!r.ok || d?.estado !== "pagada" || !d.evento) throw new Error(d?.motivo ?? `respondió ${r.status}`);
  } catch (e) {
    console.error(`entradas con diseño: la función orden no dio los datos de ${ordenId}: ${e}`);
    return out;
  }
  const porCode = new Map<string, any>((d.entradas ?? []).map((t: any) => [t.code, t]));
  const tope = Math.max(90_000, Math.floor(PESO_IMAGENES / codes.length));
  const esperaArte = Boolean(d.fase?.arte_url || d.evento.arte_url);
  const sinArte: string[] = [];
  /* Devuelve si la entrada quedó con imagen; en un reintento (`otraVez`),
     si esta vez vino con el arte. Un reintento que falla no le saca la
     imagen que ya tenía. */
  const una = async (code: string, otraVez = false): Promise<boolean> => {
    const t = porCode.get(code), resta = hasta - Date.now();
    if (!t || resta < 1_000) return false;
    try {
      const cuerpo = JSON.stringify({ t: { code: t.code, cliente: t.cliente, etiqueta: t.etiqueta },
                                      evento: d.evento, fase: d.fase, tope });
      const ts = String(Math.floor(Date.now() / 1000));
      const r = await fetch(RENDER, {
        method: "POST",
        headers: { "Content-Type": "application/json", "x-ts": ts, "x-firma": await firmar(ts, cuerpo) },
        body: cuerpo, signal: AbortSignal.timeout(Math.min(IMG_ESPERA_MS, resta)),
      });
      const tipo = r.headers.get("content-type") ?? "";
      if (!r.ok || !/^image\/(jpeg|png)$/.test(tipo)) {
        // El motivo va al log: "Faltan fuentes en el deploy: …" se arregla distinto que una firma que no coincide.
        const motivo = tipo.includes("json") ? (await r.json().catch(() => null))?.motivo : await r.body?.cancel();
        throw new Error(`respondió ${r.status} ${motivo ?? tipo}`);
      }
      const bytes = new Uint8Array(await r.arrayBuffer());
      const conArte = r.headers.get("x-entrada-variante") === "arte";
      if (esperaArte && !conArte) {
        console.error(`entrada ${code}: el arte no cargó en el servidor` +
                      (otraVez ? " tampoco al reintentar, va la entrada propia" : ", se reintenta al final"));
        if (otraVez) return false;
        sinArte.push(code);
      }
      out.set(code, { cid: `entrada-${code}`, tipo, bytes, conArte,
                      ancho: Number(r.headers.get("x-entrada-ancho")) || 0,
                      alto: Number(r.headers.get("x-entrada-alto")) || 0 });
      return true;
    } catch (e) {
      console.error(otraVez ? `entrada ${code}: el reintento falló, queda la entrada propia: ${e}`
                            : `entrada ${code} sin diseño, va con el QR en tabla: ${e}`);
      return false;
    }
  };
  const deAVarias = async (lista: string[], otraVez = false) => {
    let i = 0;
    await Promise.all(Array.from({ length: IMG_A_LA_VEZ }, async () => {
      while (i < lista.length) await una(lista[i++], otraVez);
    }));
  };
  /* La primera sola: calienta la instancia y deja el arte en su caché, así
     las otras no lo bajan cada una por su lado. Y si la primera no sale
     (Vercel caído, firma que no coincide), no se insiste con las demás:
     fallarían igual y el botón "reenviar" del panel esperaría el doble. */
  if (!(await una(codes[0]))) return out;
  await deAVarias(codes.slice(1));
  /* Las que salieron sin el arte del evento se piden otra vez, si queda
     tiempo. Pasa sobre todo con la primera: en una instancia fría el arte
     pesado (el PNG de 2,2 MB de Dark Garden) puede tardar más de los 4 s que
     lo espera app/api/entrada.js, y la entrada sale con el diseño propio
     de TICKETAZO. Justo lo que el dueño reclamó, y solo quedaba en el log.
     Si alguna otra sí lo trajo, el arte ya está en la caché de la instancia
     y el reintento sale en milisegundos. Si ninguna lo trajo, se prueba con
     una sola: si tampoco, el bucket está caído y reintentar las demás solo
     demora el correo (y el botón "reenviar" del panel). */
  if (sinArte.length) {
    const otra = sinArte.splice(0);
    if ([...out.values()].some((m) => m.conArte) || await una(otra.shift()!, true)) await deAVarias(otra, true);
  }
  return out;
}

// btoa necesita un string binario; de a tramos, que un spread de 400 KB revienta la pila.
function base64(b: Uint8Array): string {
  let s = "";
  for (let i = 0; i < b.length; i += 0x8000) s += String.fromCharCode(...b.subarray(i, i + 0x8000));
  return btoa(s);
}

/* El nombre de cada entrada en la lista. Las que vienen con una mesa dicen
   de cuál (0108): son las que pasan el molinete, y el comprador tiene que
   poder distinguirlas del recibo, que no lo pasa. */
const etiqueta = (x: any) =>
  x.tipo_entrada?.categoria === "mesa" ? `Entrada · ${x.tipo_entrada.nombre}`
    : x.tipo_entrada?.nombre
      ?? ((x.mesas?.categoria === "lounge" ? "Lounge " : "Mesa ") + (x.mesas?.etiqueta ?? ""));

/* Una entrada adentro del correo: la imagen de /orden si llegó, y si no
   su QR en tabla (que lee la misma puerta). Abajo, qué entrada es y su
   código, como en el pie de cada pase de /orden. El alto va en el atributo
   para que el correo no salte mientras carga la imagen. `respaldo`: si su
   QR en tabla va también al final (ver respaldoSinSenal); el texto que se
   ve cuando la imagen no carga manda ahí. */
function bloqueEntrada(e: any, x: any, i: number, n: number, img?: Imagen, respaldo = false): string {
  const F = "font-family:Helvetica,Arial,sans-serif";
  const alt = `Entrada ${etiqueta(x)}, código #${x.code}` + (respaldo ? ". Si no se ve, su QR está al final del correo." : "");
  const visual = img
    ? `<img src="cid:${img.cid}" width="${ANCHO_ENTRADA}"` +
      (img.ancho && img.alto ? ` height="${Math.round(ANCHO_ENTRADA * img.alto / img.ancho)}"` : "") +
      ` alt="${esc(alt)}" style="display:block;width:${ANCHO_ENTRADA}px;` +
      `max-width:100%;height:auto;border:0;outline:none;border-radius:10px;${F};font-size:13px;color:#F3EFE2">`
    : qrTabla(`EVT:${e.id}:${x.code}`);
  return `<table role="presentation" cellpadding="0" cellspacing="0" border="0" align="center" style="margin:22px auto 0"><tr><td align="center">
     ${visual}
     <p style="margin:10px 0 0;${F};font-size:13px;color:#F3EFE2;text-align:center">${esc(etiqueta(x))}${n > 1 ? ` · ${i + 1} de ${n}` : ""}</p>
     <p style="margin:2px 0 0;font-family:Courier,monospace;font-size:13px;color:#A79EC0;text-align:center">#${esc(x.code)}</p>
    </td></tr></table>`;
}

/* Cuántas entradas de la mesa van con su QR adentro del correo. El dueño
   pidió que lleguen los QR, no solo el link. Dos topes: diez, que es una
   mesa grande, y el tamaño (CORREO_TOPE): pasados los 102 KB Gmail esconde
   el final detrás de "Ver mensaje completo", y ahí quedaba también el
   botón. Las que no entran van con su código y con el QR en el link, que
   las tiene todas. */
const QR_ENTRADAS_TOPE = 10;
const CORREO_TOPE = 95_000;

/* ── el respaldo sin señal (27/10) ──
   La imagen de cada entrada viaja como adjunto inline (cid). El HTML el
   teléfono lo baja junto con el mensaje, y por eso el QR en tabla del
   26/10 se veía sin señal; los adjuntos, en cambio, varios clientes (Gmail
   en Android y en iPhone, Mail del iPhone) los bajan recién al abrir el
   correo. El que paga, no abre el correo y lo abre por primera vez en la
   fila sin datos vería el texto de la imagen y ningún QR: lo contrario de
   lo que vino a hacer el QR en el correo. Hasta probarlo en modo avión con
   un correo que nunca se abrió, en esos tres, cada entrada con imagen
   lleva además su QR en tabla, al final, para no competir con el arte: es
   el mismo EVT:<evento>:<código>, lo lee la misma puerta. Si la prueba da
   que las imágenes están, esto se saca y el correo queda con el arte solo.
   `filas` son las entradas con respaldo y su lugar en la compra; `conImagen`,
   cuántas del correo tienen imagen (si son más, el resto está en el link). */
function respaldoSinSenal(e: any, filas: [any, number][], n: number, conImagen: number): string {
  if (!filas.length) return "";
  const F = "font-family:Helvetica,Arial,sans-serif";
  const cuales = filas.length < conImagen
    ? `Acá van los QR de las primeras ${filas.length}, sin imágenes; las demás están en el link`
    : filas.length === 1 ? "Este es el mismo QR, sin imágenes" : "Estos son los mismos QR, sin imágenes";
  return `<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="margin-top:28px;border-top:1px solid #4A3A8A">
     <tr><td style="padding:18px 0 0">
      <p style="margin:0;${F};font-size:11px;letter-spacing:2px;text-transform:uppercase;color:#FFE24B">Si no ves ${conImagen === 1 ? "tu entrada" : "tus entradas"}</p>
      <p style="margin:6px 0 0;${F};font-size:13px;line-height:1.5;color:#A79EC0">Sin señal, algunos teléfonos no muestran las imágenes de un correo que todavía no abriste. ${cuales}: la puerta los lee igual.</p>
      ${filas.map(([x, i]) => bloqueEntrada(e, x, i, n)).join("")}
     </td></tr>
    </table>`;
}

/* Hasta dónde entra en CORREO_TOPE: `armar(k, b)` arma el correo con las
   primeras k entradas adentro y, de las que llevan imagen, las primeras b
   con su respaldo en tabla. Primero se sacan respaldos y recién después
   entradas: una imagen pesa ~400 bytes de HTML y un respaldo ~13 KB, y la
   entrada con el arte es lo que se compró. Bytes y no largo del texto:
   Gmail cuenta bytes, y cada tilde son dos. Sin imágenes (b = 0 siempre)
   es el mismo recorte de antes, de a una entrada menos. */
function queEntre(n: number, conImagen: (k: number) => number, armar: (k: number, b: number) => string): string {
  const bytes = (t: string) => new TextEncoder().encode(t).length;
  let k = Math.min(n, QR_ENTRADAS_TOPE), b = conImagen(k), html = armar(k, b);
  while (k > 0 && bytes(html) > CORREO_TOPE) html = b > 0 ? armar(k, --b) : armar(--k, 0);
  return html;
}

/* Las primeras k entradas, cada una con su bloque (imagen o QR en tabla), y
   el respaldo de las primeras b que llevan imagen. */
function entradasDelCorreo(e: any, ent: any[], imgs: Map<string, Imagen>, k: number, b: number) {
  const n = ent.length;
  const conImg = ent.slice(0, k).map((x, i): [any, number] => [x, i]).filter(([x]) => imgs.has(x.code));
  const respaldadas = new Set(conImg.slice(0, b).map(([x]) => x.code));
  return {
    bloques: ent.slice(0, k).map((x, i) => bloqueEntrada(e, x, i, n, imgs.get(x.code), respaldadas.has(x.code))),
    respaldo: respaldoSinSenal(e, conImg.slice(0, b), n, conImg.length),
  };
}
const conImagenEn = (ent: any[], imgs: Map<string, Imagen>) => (k: number) =>
  ent.slice(0, k).filter((x) => imgs.has(x.code)).length;

/* ── el correo de una mesa (0108) ──
   Lo que el dueño pidió que llegue: el QR de la mesa y el recibo, las
   entradas incluidas con su QR si las hay, y las condiciones de la
   reserva. El mismo cascarón que el de entradas (paleta, tablas, estilos
   en línea) para que parezcan del mismo lado. El carnet va enmascarado:
   un correo se reenvía, y el completo lo ve el guardia en su pantalla. */
function correoMesa(o: any, e: any, mesa: any, ent: any[], link: string,
                    imgs: Map<string, Imagen> = new Map()): string {
  const F = "font-family:Helvetica,Arial,sans-serif";
  const fila = (k: string, v: string) =>
    `<tr><td style="padding:6px 14px 6px 0;${F};font-size:12px;letter-spacing:1px;text-transform:uppercase;color:#A79EC0;vertical-align:top;white-space:nowrap">${k}</td>` +
    `<td style="padding:6px 0;${F};font-size:14px;line-height:1.45;color:#F3EFE2">${v}</td></tr>`;
  const inc = Number(mesa.entradas_incluidas ?? 0);
  const n = ent.length;
  const condiciones = (Array.isArray(mesa.condiciones) ? mesa.condiciones : [])
    .map((c: string) => `<p style="margin:4px 0 0;${F};font-size:14px;line-height:1.5;color:#F3EFE2">· ${esc(c)}</p>`).join("");

  /* Cada entrada con su imagen de /orden (o su QR en tabla, si la imagen
     no llegó), y abajo de qué mesa es: es la que pasa el molinete, y el
     comprador tiene que poder distinguirla del recibo, que no lo pasa. */
  const soloCodigo = (x: any) =>
    `<tr>
        <td style="padding:7px 12px 7px 0;${F};font-size:13px;color:#A79EC0">${esc(etiqueta(x))}</td>
        <td style="padding:7px 0;font-family:Courier,monospace;font-size:13px;color:#F3EFE2">#${esc(x.code)}</td>
      </tr>`;
  const parrafo = (txt: string) =>
    `<p style="margin:24px 0 0;${F};font-size:15px;line-height:1.55;color:#F3EFE2">${txt}</p>`;
  const entradas = (k: number, bloques: string[]) => {
    if (inc === 0 || n === 0) return parrafo("Tu mesa no incluye entradas: para entrar, cada uno necesita la suya.");
    const cuantas = k === n ? (n === 1 ? "Tenés 1, con su QR acá abajo." : `Tenés ${n}, cada una con su QR acá abajo.`)
      : k === 0 ? (n === 1 ? "Tenés 1, con su QR en el link:" : `Tenés ${n}, cada una con su QR en el link:`)
      : `Tenés ${n}: acá abajo van ${k === 1 ? "la primera" : `las primeras ${k}`} con su QR, y todas están en el link.`;
    return parrafo(`Para entrar se usan las entradas de la mesa. ${cuantas} Cada QR vale para un solo ingreso.`) +
      bloques.join("") +
      (k === n ? "" : (k > 0
        ? `<p style="margin:22px 0 0;${F};font-size:14px;line-height:1.5;color:#A79EC0">${n - k === 1 ? "La que falta" : `Las ${n - k} que faltan`}, con su QR en el link:</p>`
        : "") +
        `<table role="presentation" cellpadding="0" cellspacing="0" border="0" style="margin-top:10px;border-collapse:collapse">${ent.slice(k).map(soloCodigo).join("")}</table>`);
  };

  const armar = (k: number, b: number) => { const { bloques, respaldo } = entradasDelCorreo(e, ent, imgs, k, b); return `<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="background:#180E3A;margin:0;padding:0">
 <tr><td align="center" style="padding:32px 16px">
  <table role="presentation" width="520" cellpadding="0" cellspacing="0" border="0" style="width:520px;max-width:100%">
   <tr><td style="padding:0 0 26px"><img src="${SITIO}/logo-correo.png" alt="TICKETAZO" width="180" style="display:block;border:0;outline:none;text-decoration:none;width:180px;height:auto;color:#F3EFE2;${F};font-size:22px;font-weight:bold"></td></tr>
   <tr><td style="background:#231550;border-radius:10px;padding:32px 28px">
    <p style="margin:0 0 6px;${F};font-size:11px;letter-spacing:2px;text-transform:uppercase;color:#FFE24B">${esc(e.lugar)}</p>
    <h1 style="margin:0 0 4px;${F};font-size:26px;line-height:1.15;text-transform:uppercase;color:#F3EFE2">${esc(e.nombre)}</h1>
    <p style="margin:0 0 22px;${F};font-size:14px;color:#A79EC0">${esc(e.fecha)} · ${esc(String(e.hora_inicio).slice(0,5))}</p>
    <p style="margin:0 0 20px;${F};font-size:15px;line-height:1.55;color:#F3EFE2">Hola ${esc(mesa.titular ?? o.comprador_nombre)}, tu mesa está confirmada. Este es tu recibo.</p>
    <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="border:1px solid #4A3A8A;border-radius:8px">
     <tr><td style="padding:16px 18px">
      <p style="margin:0 0 8px;${F};font-size:11px;letter-spacing:2px;text-transform:uppercase;color:#FFE24B">Recibo de mesa</p>
      <table role="presentation" cellpadding="0" cellspacing="0" border="0">
       ${fila("Mesa", esc(mesa.tipo))}
       ${fila("Incluye", esc(mesa.incluye || "—"))}
       ${fila("Entradas", inc === 0 ? "No incluye entradas" : inc === 1 ? "1 entrada incluida" : `${inc} entradas incluidas`)}
       ${fila("A nombre de", `${esc(mesa.titular)}${mesa.ci ? ` · CI ${esc(mesa.ci)}` : ""}`)}
       ${fila("Correo", esc(mesa.email))}
      </table>
     </td></tr>
    </table>
    <table role="presentation" cellpadding="0" cellspacing="0" border="0" align="center" style="margin:24px auto 0"><tr><td align="center">
     ${qrTabla(`EVT:${e.id}:${mesa.code}`)}
    </td></tr></table>
    <p style="margin:10px 0 0;text-align:center;font-family:Courier,monospace;font-size:13px;color:#F3EFE2">#${esc(mesa.code)}</p>
    <p style="margin:12px 0 0;${F};font-size:13px;line-height:1.5;color:#A79EC0;text-align:center">Este QR es el recibo de tu mesa: mostralo en la puerta y el guardia ve tu reserva. <b style="color:#F3EFE2">No sirve para entrar.</b></p>
    ${entradas(k, bloques)}
    <table role="presentation" cellpadding="0" cellspacing="0" border="0" style="margin-top:22px"><tr>
     <td align="center" bgcolor="#FFE24B" style="border-radius:8px">
      <a href="${link}" style="display:inline-block;padding:14px 26px;${F};font-size:15px;font-weight:bold;color:#180E3A;text-decoration:none">${inc > 0 ? "Ver mi mesa y mis entradas" : "Ver mi mesa"}</a>
     </td>
    </tr></table>
    <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="margin-top:24px;border-top:1px solid #4A3A8A">
     <tr><td style="padding:16px 0 0">
      <p style="margin:0;${F};font-size:11px;letter-spacing:2px;text-transform:uppercase;color:#FFE24B">Condiciones de la reserva</p>
      ${condiciones}
     </td></tr>
    </table>${respaldo ? `
    ${respaldo}` : ""}
   </td></tr>
   <tr><td style="padding:22px 4px 0;${F};font-size:12px;line-height:1.5;color:#6E6392">TICKETAZO · Entradas y control de puerta · Santa Cruz de la Sierra</td></tr>
  </table>
 </td></tr>
</table>`; };

  // Si las entradas incluidas no son de esta mesa (inc = 0), no van: tampoco su respaldo.
  return queEntre(n, inc === 0 ? () => 0 : conImagenEn(ent, imgs), armar);
}

/* ── el correo de una compra de entradas ──
   Violeta y fluor, los mismos valores que portada.css y que la plantilla
   de recuperar contraseña (supabase/plantillas-correo/). Antes iba en
   negro, rojo y dorado cerveza: la paleta de Amstel, que quedó de cuando
   la ticketera vestía un solo evento. Un comprador recibe estos dos
   correos y tienen que parecer del mismo lado.

   Tablas y estilos en línea, no divs con flex: Outlook renderiza con el
   motor de Word y descarta casi todo el CSS moderno. Feo de escribir,
   igual en todos lados. Hexadecimales sólidos y ninguna rgba: los clientes
   viejos la ignoran y dejarían el texto en negro sobre violeta.

   Cada entrada va con su QR adentro del correo (26/10). Antes el correo
   decía "abrí ese link en la puerta: ahí están los QR", y el link necesita
   señal: en la fila de un boliche lleno, el que no tenía datos no podía
   mostrar su entrada. El correo sí queda guardado en el teléfono. Es el
   mismo QR que dibuja ticket.js (EVT:<evento>:<código>), así que lo lee
   tanto nuestra puerta como la de Plataforma Puerta en Bowie y BurTown.
   Los mismos topes que el de la mesa: diez QR y CORREO_TOPE; las que no
   entran van con su código y están todas en el link. Desde el 27/10 cada
   una va con la imagen de /orden si llegó (ver imagenesDeEntradas): un
   <img cid:> pesa casi nada en el HTML, así que CORREO_TOPE sigue
   midiendo lo mismo, el HTML, que es lo que Gmail corta. */
function correoEntradas(o: any, e: any, ent: any[], link: string,
                        imgs: Map<string, Imagen> = new Map()): string {
  const F = "font-family:Helvetica,Arial,sans-serif";
  const n = ent.length;
  const soloCodigo = (x: any) =>
    `<tr>
        <td style="padding:7px 12px 7px 0;${F};font-size:13px;color:#A79EC0">${esc(etiqueta(x))}</td>
        <td style="padding:7px 0;font-family:Courier,monospace;font-size:13px;color:#F3EFE2">#${esc(x.code)}</td>
      </tr>`;
  const aviso = (k: number) =>
    k === n ? (n === 1 ? "Mostrá este QR en la puerta." : "Mostrá estos QR en la puerta, uno por persona.")
      : k === 0 ? "Tus QR están en el link: abrilo antes de salir de tu casa."
      : `Acá abajo van ${k === 1 ? "la primera" : `las primeras ${k}`}; todas están en el link.`;

  const armar = (k: number, b: number) => { const { bloques, respaldo } = entradasDelCorreo(e, ent, imgs, k, b); return `<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="background:#180E3A;margin:0;padding:0">
 <tr><td align="center" style="padding:32px 16px">
  <table role="presentation" width="520" cellpadding="0" cellspacing="0" border="0" style="width:520px;max-width:100%">
   <tr><td style="padding:0 0 26px"><img src="${SITIO}/logo-correo.png" alt="TICKETAZO" width="180" style="display:block;border:0;outline:none;text-decoration:none;width:180px;height:auto;color:#F3EFE2;${F};font-size:22px;font-weight:bold"></td></tr>
   <tr><td style="background:#231550;border-radius:10px;padding:32px 28px">
    <p style="margin:0 0 6px;${F};font-size:11px;letter-spacing:2px;text-transform:uppercase;color:#FFE24B">${esc(e.lugar)}</p>
    <h1 style="margin:0 0 4px;${F};font-size:26px;line-height:1.15;text-transform:uppercase;color:#F3EFE2">${esc(e.nombre)}</h1>
    <p style="margin:0 0 22px;${F};font-size:14px;color:#A79EC0">${esc(e.fecha)} · ${esc(String(e.hora_inicio).slice(0,5))}</p>
    <p style="margin:0 0 6px;${F};font-size:15px;line-height:1.55;color:#F3EFE2">Hola ${esc(o.comprador_nombre)}, tu compra está confirmada. ${n === 1 ? "Tenés 1 entrada" : `Tenés ${n} entradas`}. ${aviso(k)}</p>
    <p style="margin:0;${F};font-size:13px;line-height:1.5;color:#A79EC0">Si en la puerta no hay señal, este correo igual se abre${respaldo ? ": si no ves las imágenes, al final van los mismos QR sin ellas" : ""}. Cada QR vale para un solo ingreso: no lo compartas.</p>
    ${bloques.join("")}
    ${k === n ? "" : `<table role="presentation" cellpadding="0" cellspacing="0" border="0" style="margin-top:18px;border-collapse:collapse">${ent.slice(k).map(soloCodigo).join("")}</table>`}
    <table role="presentation" cellpadding="0" cellspacing="0" border="0" style="margin-top:26px"><tr>
     <td align="center" bgcolor="#FFE24B" style="border-radius:8px">
      <a href="${link}" style="display:inline-block;padding:14px 26px;${F};font-size:15px;font-weight:bold;color:#180E3A;text-decoration:none">Ver mis entradas</a>
     </td>
    </tr></table>
    <p style="margin:14px 0 0;${F};font-size:12px;line-height:1.5;color:#6E6392">En el link están siempre, con el arte del evento. Guardalo.</p>${respaldo ? `
    ${respaldo}` : ""}
   </td></tr>
   <tr><td style="padding:22px 4px 0;${F};font-size:12px;line-height:1.5;color:#6E6392">TICKETAZO · Entradas y control de puerta · Santa Cruz de la Sierra</td></tr>
  </table>
 </td></tr>
</table>`; };

  // Igual que el de la mesa: pasados los 102 KB Gmail esconde el final
  // detrás de "Ver mensaje completo", y ahí quedaba el botón.
  return queEntre(n, conImagenEn(ent, imgs), armar);
}

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

    const e = await uno(`eventos?id=eq.${o.evento_id}&select=id,nombre,lugar,fecha,hora_inicio`);
    const ent = await rest(`entradas?orden_id=eq.${orden}&select=code,tipo_entrada(nombre,categoria),mesas(etiqueta,categoria)&order=created_at`);
    const n = (ent ?? []).length;
    const link = `${SITIO}/orden/?id=${o.id}`;
    /* El recibo de la mesa, si la compra es una mesa (0108). Si la función
       no existe todavía o falla, sale el correo de siempre: un correo que no
       sale no puede tumbar una venta, y uno de entradas es mejor que nada. */
    const mesa = await rpc("recibo_mesa_orden", { p_orden: o.id }).catch(() => null);

    if (!RESEND) {
      console.log(`sin RESEND_API_KEY: no se envió nada. orden=${o.id} a=${o.comprador_email} link=${link}`);
      return json({ ok: true, enviado: false, motivo: "El envío de correos no está configurado.", link });
    }

    // Las que van adentro del correo (las primeras QR_ENTRADAS_TOPE), con su imagen si llega.
    const lista: any[] = ent ?? [];
    const imgs = await imagenesDeEntradas(o.id, lista.slice(0, QR_ENTRADAS_TOPE).map((x) => x.code));
    const armar = (m: Map<string, Imagen>) =>
      mesa?.code ? correoMesa(o, e, mesa, lista, link, m) : correoEntradas(o, e, lista, link, m);
    const html = armar(imgs);
    /* Solo las que quedaron en el HTML: si CORREO_TOPE dejó afuera alguna,
       su imagen no viaja colgando como un adjunto suelto. En el orden de
       la compra, que es como aparecen en la lista de adjuntos del correo. */
    const van = lista.map((x, i) => ({ i, m: imgs.get(x.code), code: x.code }))
      .filter(({ m }) => m && html.includes(`cid:${m.cid}`)) as { i: number; m: Imagen; code: string }[];
    const adjuntos = van.map(({ i, m, code }) => ({
      filename: `entrada-${i + 1}-${code}.${m.tipo === "image/png" ? "png" : "jpg"}`,
      content: base64(m.bytes), content_type: m.tipo, content_id: m.cid,
    }));

    const enviar = (cuerpo: string, adj: unknown[]) => fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: { Authorization: `Bearer ${RESEND}`, "Content-Type": "application/json" },
      body: JSON.stringify({
        from: DESDE, to: [o.comprador_email],
        subject: mesa?.code ? `Tu mesa — ${e.nombre}` : `Tus entradas — ${e.nombre}`,
        html: cuerpo,
        ...(adj.length ? { attachments: adj } : {}),
      }),
    });
    let r = await enviar(html, adjuntos);
    let j = await r.json().catch(() => ({}));
    let conDiseno = adjuntos.length, conArte = van.filter(({ m }) => m.conArte).length;
    /* Si Resend no acepta el correo con los adjuntos (un 4xx de validación:
       un adjunto que no le gusta, el tamaño), sale el de antes, todo en
       tablas. Un 5xx o un 429 no se reintenta: puede haberlo encolado, y
       dos correos iguales confunden más que uno que no llegó (el link y el
       botón "reenviar" del panel siguen estando). */
    if (!r.ok && adjuntos.length && [400, 413, 422].includes(r.status)) {
      console.error(`resend rechazó el correo con imágenes de ${o.id} (${r.status}): ` +
                    `${JSON.stringify(j).slice(0, 300)}; va con el QR en tabla`);
      r = await enviar(armar(new Map()), []);
      j = await r.json().catch(() => ({}));
      conDiseno = conArte = 0;
    }
    if (!r.ok) {
      // Un correo que no sale no puede tumbar una venta ya cobrada.
      console.error(`resend falló para ${o.id}: ${JSON.stringify(j).slice(0, 300)}`);
      return json({ ok: true, enviado: false, motivo: "No se pudo enviar el correo.", link });
    }
    const adentro = Math.min(lista.length, QR_ENTRADAS_TOPE);
    // Con el arte del organizador, o con el diseño propio de TICKETAZO (evento sin arte, o arte que no llegó).
    if (FIRMA && adentro)
      console.log(`orden ${o.id}: ${conDiseno}/${adentro} entradas con imagen, ${conArte} con el arte del evento`);
    return json({ ok: true, enviado: true, id: j.id, link, con_diseno: conDiseno, con_arte: conArte });
  } catch (err) {
    return json({ ok: false, motivo: String((err as Error).message ?? err) }, 500);
  }
});
