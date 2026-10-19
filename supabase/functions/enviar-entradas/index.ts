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

/* ── el QR del recibo, dibujado en el correo ──
   El dueño pidió que al correo llegue "el QR de la mesa" (0108), no solo
   el link. Una imagen pediría armar un PNG acá o servirlo desde otra
   función con una URL pública, y un servicio de QR de afuera vería el
   código de cada mesa. Así que se arma la matriz acá —las funciones no
   importan nada, ver comun.ts— y se dibuja como una tabla de celdas negras
   y blancas, que es lo que Gmail, Outlook y Apple Mail muestran igual.
   Solo el del recibo: las entradas siguen yendo por el link, como siempre.

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

/** El QR como tabla HTML, una celda por módulo. El margen blanco de 4
    módulos que pide el estándar (sin él la cámara no lo encuentra sobre el
    violeta del correo) va como relleno de la tabla de afuera y no como
    celdas: son 600 celdas menos, y el correo entero tiene que quedar lejos
    de los 102 KB en los que Gmail lo corta. */
function qrTabla(texto: string, px = 5): string {
  const m = qrMatriz(texto);
  if (!m) return "";
  const negro = `<td width="${px}" height="${px}" bgcolor="black"></td>`;
  const blanco = `<td width="${px}" height="${px}"></td>`;
  const filas = m.map((f) => `<tr>${f.map((b) => (b ? negro : blanco)).join("")}</tr>`).join("");
  const lado = m.length * px;
  return `<table role="presentation" cellpadding="${4 * px}" cellspacing="0" border="0" bgcolor="#FFFFFF" ` +
    `style="background:#FFFFFF;border-radius:6px"><tr><td>` +
    `<table role="presentation" cellpadding="0" cellspacing="0" border="0" width="${lado}" ` +
    `style="width:${lado}px;border-collapse:collapse;line-height:0;font-size:0">${filas}</table>` +
    `</td></tr></table>`;
}

/* El nombre de cada entrada en la lista. Las que vienen con una mesa dicen
   de cuál (0108): son las que pasan el molinete, y el comprador tiene que
   poder distinguirlas del recibo, que no lo pasa. */
const etiqueta = (x: any) =>
  x.tipo_entrada?.categoria === "mesa" ? `Entrada · ${x.tipo_entrada.nombre}`
    : x.tipo_entrada?.nombre
      ?? ((x.mesas?.categoria === "lounge" ? "Lounge " : "Mesa ") + (x.mesas?.etiqueta ?? ""));

/* ── el correo de una mesa (0108) ──
   Lo que el dueño pidió que llegue: el QR de la mesa y el recibo, las
   entradas incluidas si las hay, y las condiciones de la reserva. El mismo
   cascarón que el de entradas (paleta, tablas, estilos en línea) para que
   parezcan del mismo lado. El carnet va enmascarado: un correo se
   reenvía, y el completo lo ve el guardia en su pantalla. */
function correoMesa(o: any, e: any, mesa: any, filas: string, n: number, link: string): string {
  const F = "font-family:Helvetica,Arial,sans-serif";
  const fila = (k: string, v: string) =>
    `<tr><td style="padding:6px 14px 6px 0;${F};font-size:12px;letter-spacing:1px;text-transform:uppercase;color:#A79EC0;vertical-align:top;white-space:nowrap">${k}</td>` +
    `<td style="padding:6px 0;${F};font-size:14px;line-height:1.45;color:#F3EFE2">${v}</td></tr>`;
  const inc = Number(mesa.entradas_incluidas ?? 0);
  const condiciones = (Array.isArray(mesa.condiciones) ? mesa.condiciones : [])
    .map((c: string) => `<p style="margin:4px 0 0;${F};font-size:14px;line-height:1.5;color:#F3EFE2">· ${esc(c)}</p>`).join("");
  return `<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="background:#180E3A;margin:0;padding:0">
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
    ${inc > 0
      ? `<p style="margin:24px 0 0;${F};font-size:15px;line-height:1.55;color:#F3EFE2">Para entrar se usan las entradas de la mesa. ${n === 1 ? "Tenés 1" : `Tenés ${n}`}, cada una con su QR en el link:</p>
    <table role="presentation" cellpadding="0" cellspacing="0" border="0" style="margin-top:10px;border-collapse:collapse">${filas}</table>`
      : `<p style="margin:24px 0 0;${F};font-size:15px;line-height:1.55;color:#F3EFE2">Tu mesa no incluye entradas: para entrar, cada uno necesita la suya.</p>`}
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
    </table>
   </td></tr>
   <tr><td style="padding:22px 4px 0;${F};font-size:12px;line-height:1.5;color:#6E6392">TICKETAZO · Entradas y control de puerta · Santa Cruz de la Sierra</td></tr>
  </table>
 </td></tr>
</table>`;
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
    const filas = (ent ?? []).map((x: any) =>
      `<tr>
        <td style="padding:7px 12px 7px 0;font-family:Helvetica,Arial,sans-serif;font-size:13px;color:#A79EC0">${esc(etiqueta(x))}</td>
        <td style="padding:7px 0;font-family:Courier,monospace;font-size:13px;color:#F3EFE2">#${esc(x.code)}</td>
      </tr>`).join("");

    const html = mesa?.code ? correoMesa(o, e, mesa, filas, n, link) : `<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="background:#180E3A;margin:0;padding:0">
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
        subject: mesa?.code ? `Tu mesa — ${e.nombre}` : `Tus entradas — ${e.nombre}`,
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
