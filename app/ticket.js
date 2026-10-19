/* El ticket, dibujado en canvas del lado del cliente: cero egress de imágenes
   generadas. Vive aparte porque lo usan dos páginas — la de compra y la de
   `/orden/<uuid>`, adonde llega el link del correo.

   El payload del QR es `EVT:<evento>:<code>`, el mismo de Bowie y BurTown, así
   que el escáner de la puerta lo lee sin cambiarle una línea.

   Acá adentro está todo lo que las dos páginas hacen igual con una entrada:
   dibujarla, apilarla en pantalla, guardarla en el teléfono y mostrarla
   grande en la puerta. Estaba duplicado en app.js y en orden.js, que es la
   forma más segura de que dentro de un mes digan cosas distintas. */
(function () {
"use strict";

const esc = s => String(s ?? "").replace(/[&<>"']/g, c =>
  ({ "&":"&amp;", "<":"&lt;", ">":"&gt;", '"':"&quot;", "'":"&#39;" }[c]));

/* El payload del QR en un solo lugar. El del arte y el que se muestra en la
   puerta tienen que ser el mismo string: si se separan, el escáner lee una
   entrada distinta de la que el comprador cree estar mostrando. */
const payload = (evento, t) => `EVT:${evento.id}:${t.code}`;

/* Carga una imagen y espera a que esté lista. crossOrigin porque el arte
   vive en el storage de Supabase, otro origen: sin esto el canvas queda
   "tainted" y toDataURL tira SecurityError. */
/* Con tope: una descarga que se cuelga (sin fallar) dejaba la página en
   "Dibujando…" sin QR. A los 8 s se rinde y dibujarTicket hace la entrada
   propia, con el mismo QR, que la puerta lee igual. */
function cargarImagen(url) {
  return new Promise((ok, mal) => {
    const i = new Image();
    const t = setTimeout(() => mal(new Error("El arte tardó demasiado.")), 8000);
    i.crossOrigin = "anonymous";
    i.onload = () => { clearTimeout(t); ok(i); };
    i.onerror = () => { clearTimeout(t); mal(new Error("No se pudo cargar el arte.")); };
    i.src = url;
  });
}

/* ── la firma de la ticketera ────────────────────────────────────
   "powered by TICKETAZO", chica, abajo. La entrada es la pieza que más
   viaja —se reenvía por WhatsApp, se muestra en la puerta, queda en el
   rollo de fotos del teléfono— y es el único lugar donde la ticketera
   puede decir su nombre sin pedirle nada a nadie ni tapar nada del
   cliente. Chica de verdad: la letra mide el 3,6% del ancho de la
   entrada, menos de la mitad del código que va debajo del QR. Sobre el arte del cliente va
   en la esquina de abajo a la derecha —donde un afiche no pone nada que
   importe— y con la misma sombra que el código, que ya demostró leerse
   sobre cualquier fondo. En el diseño propio va centrada y limpia.

   Se escribe con las dos partes que definen la marca —TICKET en crema,
   AZO en fluor—, igual que en la barra de todas las páginas. Se dibuja
   por segmentos midiendo cada uno, porque un canvas no sabe pintar dos
   colores en un mismo fillText. */
function firma(x, W, H, o) {
  const s = Math.round(W * 0.036), chico = Math.round(s * 0.66);
  const fDisplay = `800 ${s}px "Big Shoulders Display", "Archivo", "Inter Tight", sans-serif`;
  const fMono    = `400 ${chico}px "DM Mono", monospace`;
  x.save();
  x.textAlign = "left"; x.textBaseline = "alphabetic";
  x.font = fMono;    const wPor = x.measureText("powered by").width;
  x.font = fDisplay; const wTicket = x.measureText("TICKET").width, wAzo = x.measureText("AZO").width;
  const sep = s * 0.35, total = wPor + sep + wTicket + wAzo;
  const x0 = o.centro ? (W - total) / 2 : W - W * 0.045 - total;
  const y  = o.y != null ? o.y : H - W * 0.045;
  if (o.sombra) { x.shadowColor = "rgba(0,0,0,.9)"; x.shadowBlur = W * 0.015; }
  x.font = fMono;    x.fillStyle = "rgba(246,241,228,.8)"; x.fillText("powered by", x0, y);
  x.font = fDisplay;
  x.fillStyle = "#F6F1E4"; x.fillText("TICKET", x0 + wPor + sep, y);
  x.fillStyle = "#FFE24B"; x.fillText("AZO", x0 + wPor + sep + wTicket, y);
  x.restore();
}

/* Con arte subido: el QR va ENCIMA de la imagen del organizador, como en
   Bowie y BurTown. Mismas proporciones que allá — caja blanca del 52% del
   ancho desde el 29% de la altura — para que un arte hecho para Puerta sirva
   acá sin rehacerlo. */
/* A lo sumo 1000px de ancho y en JPEG. Al tamaño natural del arte (1080x1800
   en LÜMEN) y en PNG, cada entrada eran 2-4 MB de texto en la página, cerca
   de 0,3 s de pantalla congelada por entrada en un teléfono medio y archivos
   de 2 MB al guardarla. Todo se dibuja en proporción a W y H, así que el QR
   queda igual de grande en relación al arte: a 1000px su caja mide 520px,
   de sobra para el lector de la puerta. */
const ANCHO_MAX = 1000;

/* ── la entrada de Plataforma Puerta ─────────────────────────────
   Bowie y BurTown son espejo de Puerta (0103): la entrada que se compra
   acá va al mismo escáner y a los mismos chats que la que genera un
   relacionador allá. Se dibuja IGUAL que ticketImage() de Puerta (app.js
   de plataforma): sus fuentes —Space Grotesk 700 el código, Inter 500 el
   nombre—, sin la firma de TICKETAZO, y con el sello de la fase cuando la
   fase no trae arte propio. Si se viera distinta, en la fila sería "la de
   internet" y alguien la discutiría. Lo decide `entrada_puerta`, que manda
   la base por ser espejo (0104), no un slug escrito acá.

   El tamaño sigue topado en ANCHO_MAX: todo va en proporción a W y H, así
   que la pieza es la misma; solo pesa menos. */
const FUENTE_CODIGO = '"Space Grotesk", sans-serif';
const FUENTE_NOMBRE = "Inter, sans-serif";

/* Las fuentes de Puerta no las usa ninguna regla de CSS de acá, así que el
   navegador no las baja solo y document.fonts.ready no las espera: sin
   pedirlas, el canvas dibujaría con la de repuesto y el código saldría en
   otra letra. Las caras las declara el <link> de Google Fonts de la página
   (evento.html, orden/); document.fonts.load baja justo la que hace falta.
   Con tope de 3 s: una fuente que no llega no deja a nadie sin su QR. */
function fuentesPuerta(t) {
  if (!document.fonts || !document.fonts.load) return Promise.resolve();
  const bajar = Promise.all([
    document.fonts.load(`700 64px ${FUENTE_CODIGO}`, "#" + (t.code || "0")),
    document.fonts.load(`500 32px ${FUENTE_NOMBRE}`, t.cliente || "A"),
  ]).catch(() => {});
  return Promise.race([bajar, new Promise(ok => setTimeout(ok, 3000))]);
}

/* El sello de la tanda, el de marcaFase() de Puerta: una pastilla oscura
   abajo, al 92,5% de la altura. El cliente compró un "Hot Ticket" y eso es
   parte de lo que compró. Mismas medidas que allá: 800 se pide como allá
   aunque Space Grotesk llegue hasta 700, y el navegador usa la 700 en los
   dos lados. */
function selloFase(x, W, H, txt) {
  x.shadowColor = "transparent"; x.shadowBlur = 0;
  const t = String(txt).toUpperCase();
  x.font = `800 ${Math.round(W * 0.032)}px ${FUENTE_CODIGO}`;
  x.textAlign = "center"; x.textBaseline = "middle";
  const pw = x.measureText(t).width + W * 0.07, ph = W * 0.068;
  const px = (W - pw) / 2, py = H * 0.925 - ph / 2;
  x.fillStyle = "rgba(0,0,0,.55)";
  x.beginPath(); x.roundRect(px, py, pw, ph, ph / 2); x.fill();
  x.strokeStyle = "rgba(255,255,255,.5)"; x.lineWidth = Math.max(1, W * 0.0025);
  x.beginPath(); x.roundRect(px, py, pw, ph, ph / 2); x.stroke();
  x.fillStyle = "#fff";
  x.fillText(t, W / 2, py + ph / 2 + W * 0.002);
  x.textBaseline = "alphabetic";
}

/* El rótulo de una cortesía ("Invitada especial", "Staff"): lo escribe
   quien la emite y va en una pastilla como la del sello, centrada debajo
   del nombre. Ahí y no abajo de todo porque el pie del arte es del
   cliente —fecha, lugar, logos— y el espacio bajo el nombre es el único
   que ticket.js ya sabe libre en cualquier arte. Medido en el arte de
   Nocturne (15/10), el texto del cliente arranca 0,105 del ancho debajo
   de la base del nombre: la pastilla va de 0,024 a 0,080, lejos de las
   colas del nombre y de la fecha del afiche. Más chica que la del sello
   por eso mismo. Es una copia de selloFase y no una reforma suya a
   propósito: el sello se dibuja igual que en Puerta y esas entradas se
   están vendiendo. */
function rotulo(x, W, cy, txt, fuente) {
  x.save();
  x.shadowColor = "transparent"; x.shadowBlur = 0;
  const t = String(txt).toUpperCase();
  x.font = `800 ${Math.round(W * 0.03)}px ${fuente}`;
  x.textAlign = "center"; x.textBaseline = "middle";
  const pw = x.measureText(t).width + W * 0.06, ph = W * 0.056;
  const px = (W - pw) / 2, py = cy - ph / 2;
  x.fillStyle = "rgba(0,0,0,.55)";
  x.beginPath(); x.roundRect(px, py, pw, ph, ph / 2); x.fill();
  x.strokeStyle = "rgba(255,255,255,.5)"; x.lineWidth = Math.max(1, W * 0.0025);
  x.beginPath(); x.roundRect(px, py, pw, ph, ph / 2); x.stroke();
  x.fillStyle = "#fff";
  x.fillText(t, W / 2, cy + W * 0.002);
  x.restore();
}
const FUENTE_ROTULO = '"Big Shoulders Display", sans-serif';

/* La letra del rótulo no la usa ningún CSS visible del panel, así que el
   navegador no la baja sola y el canvas dibujaría con la de repuesto: se
   pide, con el mismo tope de 3 s que las de Puerta. */
function fuenteRotulo(t) {
  if (!t.rotulo || !document.fonts || !document.fonts.load) return Promise.resolve();
  const bajar = document.fonts.load(`800 40px ${FUENTE_ROTULO}`, String(t.rotulo)).catch(() => {});
  return Promise.race([bajar, new Promise(ok => setTimeout(ok, 3000))]);
}

async function sobreArte(t, evento, fase, arte) {
  const puerta = !!(evento && evento.entrada_puerta);
  // En paralelo con la imagen: las dos cosas viajan a la vez.
  const [img] = await Promise.all([cargarImagen(arte), puerta ? fuentesPuerta(t) : null, fuenteRotulo(t)]);
  const k = Math.min(1, ANCHO_MAX / img.naturalWidth);
  const W = Math.round(img.naturalWidth * k), H = Math.round(img.naturalHeight * k);
  const c = document.createElement("canvas");
  c.width = W; c.height = H;
  const x = c.getContext("2d");
  x.drawImage(img, 0, 0, W, H);

  const caja = W * 0.52, bx = (W - caja) / 2, by = H * 0.29, rad = caja * 0.07;
  x.fillStyle = "#fff";
  x.beginPath(); x.roundRect(bx, by, caja, caja, rad); x.fill();

  const q = qrcode(0, "M");
  q.addData(payload(evento, t));
  q.make();
  const n = q.getModuleCount(), pad = caja * 0.06, celda = (caja - 2 * pad) / n;
  x.fillStyle = "#000";
  for (let r = 0; r < n; r++)
    for (let k = 0; k < n; k++)
      if (q.isDark(r, k)) x.fillRect(bx + pad + k * celda, by + pad + r * celda, celda + 0.5, celda + 0.5);

  // sombra para que el código se lea sobre cualquier arte, claro u oscuro
  x.textAlign = "center";
  x.shadowColor = "rgba(0,0,0,.9)"; x.shadowBlur = W * 0.02;
  x.fillStyle = "#fff";
  x.font = puerta ? `700 ${Math.round(W * 0.078)}px ${FUENTE_CODIGO}`
                  : `700 ${Math.round(W * 0.078)}px "DM Mono", monospace`;
  x.fillText("#" + t.code, W / 2, by + caja + H * 0.055);
  x.font = puerta ? `500 ${Math.round(W * 0.042)}px ${FUENTE_NOMBRE}`
                  : `500 ${Math.round(W * 0.042)}px "Inter Tight", sans-serif`;
  const yNombre = by + caja + H * 0.055 + W * 0.075;
  x.fillText(t.cliente || "—", W / 2, yNombre);
  if (t.rotulo) rotulo(x, W, yNombre + W * 0.052, t.rotulo, puerta ? FUENTE_CODIGO : FUENTE_ROTULO);
  if (puerta) {
    /* Como Puerta: el sello solo si la fase NO trae arte propio (la imagen
       ya la distingue) y solo para fases de Puerta. `sello` lo manda la
       base y viene null en la fase 'Online' que inventa el espejo. Nada de
       firma: en Puerta no hay. */
    if (fase && fase.sello && !fase.arte_url) selloFase(x, W, H, fase.sello);
  } else {
    firma(x, W, H, { sombra: true });
  }
  return c.toDataURL("image/jpeg", 0.92);
}

async function dibujarTicket(t, evento, fase) {
  // El arte de la fase gana sobre el del evento: una preventa se distingue a
  // simple vista sin cambiarle nada al resto.
  const arte = (fase && fase.arte_url) || evento.arte_url;
  if (arte) {
    try { return await sobreArte(t, evento, fase, arte); }
    catch (e) {
      // Si el arte no carga, la entrada igual sale. Una venta cobrada no se
      // queda sin ticket porque una imagen no respondió.
      console.error("arte no disponible, se dibuja el ticket propio:", e.message);
    }
  }
  await fuenteRotulo(t);
  const W = 900, H = 1500;
  const c = document.createElement("canvas");
  c.width = W; c.height = H;
  const x = c.getContext("2d");

  x.fillStyle = "#0B0A0A"; x.fillRect(0, 0, W, H);
  const g = x.createRadialGradient(W * .3, -H * .06, 0, W * .3, -H * .06, H * .52);
  g.addColorStop(0, "rgba(220,10,45,.42)"); g.addColorStop(.55, "rgba(138,6,25,.12)");
  g.addColorStop(1, "rgba(220,10,45,0)");
  x.fillStyle = g; x.fillRect(0, 0, W, H);

  x.textAlign = "center";

  x.fillStyle = "#E9B44C";
  x.font = '400 22px "DM Mono", monospace';
  x.fillText(evento.lugar.toUpperCase(), W / 2, 112);

  x.font = '800 96px "Big Shoulders Display", sans-serif';
  x.fillStyle = "#F6F1E4"; x.fillText(evento.marca_1.toUpperCase(), W / 2, 224);
  x.fillStyle = "#DC0A2D"; x.fillText(evento.marca_2.toUpperCase(), W / 2, 312);

  x.fillStyle = "rgba(246,241,228,.62)";
  x.font = '400 24px "DM Mono", monospace';
  x.fillText(evento.fecha_txt, W / 2, 364);

  // caja blanca del QR
  const box = 440, bx = (W - box) / 2, by = 424, rad = 14;
  x.fillStyle = "#fff";
  x.beginPath(); x.roundRect(bx, by, box, box, rad); x.fill();

  const q = qrcode(0, "M");
  q.addData(payload(evento, t));
  q.make();
  const n = q.getModuleCount(), pad = box * .07, cell = (box - 2 * pad) / n;
  x.fillStyle = "#000";
  for (let r = 0; r < n; r++)
    for (let k = 0; k < n; k++)
      if (q.isDark(r, k)) x.fillRect(bx + pad + k * cell, by + pad + r * cell, cell + .6, cell + .6);

  x.fillStyle = "#F6F1E4";
  x.font = '500 46px "DM Mono", monospace';
  x.fillText("#" + t.code, W / 2, by + box + 74);
  x.font = '500 34px "Inter Tight", sans-serif';
  x.fillText(t.cliente || "—", W / 2, by + box + 124);
  if (t.rotulo) rotulo(x, W, by + box + 124 + W * 0.052, t.rotulo, FUENTE_ROTULO);

  // perforación
  const py = 1104;
  x.strokeStyle = "rgba(246,241,228,.28)"; x.lineWidth = 2; x.setLineDash([12, 12]);
  x.beginPath(); x.moveTo(40, py); x.lineTo(W - 40, py); x.stroke(); x.setLineDash([]);
  x.fillStyle = "#0B0A0A";
  [0, W].forEach(cx => { x.beginPath(); x.arc(cx, py, 26, 0, Math.PI * 2); x.fill(); });

  x.font = '800 54px "Big Shoulders Display", sans-serif';
  x.fillStyle = "#E9B44C";
  x.fillText(t.etiqueta.toUpperCase(), W / 2, 1196);

  x.font = '400 24px "DM Mono", monospace';
  x.fillStyle = "rgba(246,241,228,.62)";
  x.fillText((fase && fase.nombre) || "".toUpperCase(), W / 2, 1244);
  x.fillText("VÁLIDA PARA 1 INGRESO", W / 2, 1288);

  firma(x, W, H, { centro: true, y: 1420 });
  return c.toDataURL("image/png");
}

/* ── el QR solo, para la puerta ──────────────────────────────────
   El QR del arte ocupa el 52% del ancho del flyer porque ahí manda el diseño
   del organizador. Este manda él: se dibuja lo más grande que entre en la
   pantalla y con la zona muda entera —cuatro módulos, lo que pide la norma—,
   que es lo que hace que un lector de mano lo enganche a la primera contra
   una pantalla de celular, de noche y con la fila atrás.

   La celda va en píxeles enteros a propósito: medio píxel de más por módulo
   se acumula fila a fila y deja un código que el lector duda en leer. */
function dibujarQR(texto, ladoObjetivo) {
  const q = qrcode(0, "M");
  q.addData(texto);
  q.make();
  const n = q.getModuleCount(), muda = 4;
  const celda = Math.max(3, Math.round(ladoObjetivo / (n + muda * 2)));
  const lado = celda * (n + muda * 2);
  const c = document.createElement("canvas");
  c.width = c.height = lado;
  const x = c.getContext("2d");
  x.fillStyle = "#fff"; x.fillRect(0, 0, lado, lado);
  x.fillStyle = "#000";
  for (let r = 0; r < n; r++)
    for (let k = 0; k < n; k++)
      if (q.isDark(r, k)) x.fillRect((muda + k) * celda, (muda + r) * celda, celda, celda);
  return c.toDataURL("image/png");
}

/* ── la tira de pases ────────────────────────────────────────────
   Antes era una fila que scrolleaba de costado, y eso daba por hecho que
   siempre hay varias: con una sola entrada quedaba pegada a la izquierda y
   con media pantalla vacía al lado. Peor en un teléfono, donde nadie
   descubre que hay que arrastrar de costado si no se ve el borde de la
   siguiente.

   Apilados, cada pase entra entero en pantalla — que es como se le saca la
   captura, como se mantiene apretado para guardarlo y como se muestra en la
   puerta. Que la página se haga larga con seis entradas es el precio, y es
   barato: nadie mira seis a la vez, se muestran de a una. */
/* Sin loading="lazy": el PNG ya está entero en memoria, así que diferirlo no
   ahorra un solo byte y sí deja la página sin altura hasta que la imagen
   aparece. Con seis entradas eso era el pie saltando mientras uno lee. */
/* `desde` corre el número del botón de la puerta: en /orden el recibo de la
   mesa ocupa el primer lugar del carrusel de la puerta (0108) y las
   entradas vienen detrás. */
function tira(entradas, opciones) {
  const o = opciones || {};
  const n = entradas.length;
  const k0 = Number(o.desde) || 0;
  return entradas.map((e, i) => {
    const usada = e.estado === "usada";
    return `<figure class="pase"${usada ? ' data-usada="1"' : ""}>
      <div class="pase-arte">
        <img style="--i:${Math.min(i, 8)}" src="${e.png}"
             alt="Entrada ${esc(e.etiqueta)}, código ${esc(e.code)}">
        ${usada ? '<figcaption class="ticket-usada">Ya ingresó</figcaption>' : ""}
      </div>
      <div class="pase-pie">
        <span class="pase-tipo">${esc(e.etiqueta)}</span>
        <span class="pase-code">#${esc(e.code)}</span>
        ${n > 1 ? `<span class="pase-n">${i + 1} de ${n}</span>` : ""}
        ${o.puerta ? `<button type="button" class="btn pase-puerta" data-pase="${k0 + i}">Mostrar en la puerta</button>` : ""}
      </div>
    </figure>`;
  }).join("");
}

/* ── la mesa (0108) ──────────────────────────────────────────────
   Las dos condiciones de la reserva, con estas palabras y no otras: las
   pidió el dueño así, las devuelve recibo_mesa_orden() con el recibo y van
   iguales en la tarjeta de la mesa, en el checkout, en el recibo, en el
   correo y en los términos. Viven acá porque ticket.js es lo único que
   cargan las dos páginas del comprador (la de compra y /orden). */
const CONDICIONES_MESA = [
  "Si no te presentás con entrada, perdés la mesa.",
  "Sin devolución si no vas.",
];

/* "Incluye 4 entradas" / "No incluye entradas": la frase de cuántas
   entradas trae una mesa, igual en la tarjeta, el recibo y la pantalla de
   listo. Con 0 hay que decir que NO incluye: "entran 0" se leía como un
   error de carga, y quien no lo lee llega a la puerta sin entrada. */
function entradasDeMesa(n) {
  n = Number(n) || 0;
  return n === 0 ? "No incluye entradas"
       : n === 1 ? "Incluye 1 entrada" : `Incluye ${n} entradas`;
}

/* Corta un texto en renglones que entren en `ancho` con la letra que el
   contexto tiene puesta. Hasta `max` renglones; el último lleva "…" si
   sobró texto: "lo que incluye" lo escribe el organizador y puede ser
   largo, y un recibo que se sale del papel no se lee. */
function renglones(x, txt, ancho, max) {
  const palabras = String(txt || "").split(/\s+/).filter(Boolean);
  const out = [];
  let linea = "";
  for (const p of palabras) {
    const prueba = linea ? linea + " " + p : p;
    if (x.measureText(prueba).width <= ancho || !linea) { linea = prueba; continue; }
    out.push(linea); linea = p;
    if (out.length === max) break;
  }
  if (linea && out.length < max) out.push(linea);
  const usadas = out.join(" ").split(/\s+/).filter(Boolean).length;
  if (usadas < palabras.length && out.length) {
    let u = out[out.length - 1];
    while (u && x.measureText(u + "…").width > ancho) u = u.slice(0, -1);
    out[out.length - 1] = u + "…";
  }
  return out;
}

/* El recibo de la mesa como imagen, para guardarlo con las entradas y
   mostrarlo sin señal. Es CLARO a propósito —papel crema, tinta violeta—
   y las entradas son oscuras: en la fila de la puerta el guardia tiene que
   distinguir de un vistazo "esto es la mesa" de "esto es una entrada", y
   el comprador también. Arriba, en la banda, lo que más importa: que NO
   da ingreso. El QR es el mismo `EVT:<evento>:<code>` de siempre; la
   puerta lo reconoce por el código (MESA…) y abre el recibo, nunca el
   molinete. */
async function dibujarRecibo(m, evento) {
  if (document.fonts && document.fonts.ready) await document.fonts.ready;
  /* Se dibuja en un papel largo y al final se corta donde terminó lo
     escrito: "lo que incluye" va de nada a tres renglones, y con un alto
     fijo la mesa sin nada incluido quedaba con medio recibo en blanco. */
  const W = 900, H = 1700;
  const c = document.createElement("canvas");
  c.width = W; c.height = H;
  const x = c.getContext("2d");
  const TINTA = "#180E3A", PAPEL = "#F6F1E4", FLUOR = "#FFE24B", GRIS = "rgba(24,14,58,.62)";

  x.fillStyle = PAPEL; x.fillRect(0, 0, W, H);
  x.textAlign = "center"; x.textBaseline = "alphabetic";

  // la banda: qué es y qué no es
  x.fillStyle = TINTA; x.fillRect(0, 0, W, 196);
  x.fillStyle = FLUOR;
  x.font = '800 78px "Big Shoulders Display", sans-serif';
  x.fillText("RECIBO DE MESA", W / 2, 104);
  x.fillStyle = PAPEL;
  x.font = '500 25px "DM Mono", monospace';
  x.fillText("NO DA INGRESO · SE ENTRA CON UNA ENTRADA", W / 2, 154);

  // el evento
  const titulo = `${evento.marca_1 || ""} ${evento.marca_2 || ""}`.trim().toUpperCase();
  x.fillStyle = GRIS;
  x.font = '400 24px "DM Mono", monospace';
  x.fillText(renglones(x, [evento.fecha_txt, evento.lugar].filter(Boolean).join(" · "), W - 120, 1)[0] || "",
             W / 2, 252);
  x.fillStyle = TINTA;
  x.font = '800 44px "Big Shoulders Display", sans-serif';
  x.fillText(renglones(x, titulo, W - 120, 1)[0] || "", W / 2, 306);

  // el tipo de mesa, grande
  x.font = '800 92px "Big Shoulders Display", sans-serif';
  x.fillText(renglones(x, String(m.tipo || "Mesa").toUpperCase(), W - 100, 1)[0] || "", W / 2, 404);

  // el QR
  const box = 430, bx = (W - box) / 2, by = 440;
  x.fillStyle = "#fff";
  x.beginPath(); x.roundRect(bx, by, box, box, 14); x.fill();
  x.strokeStyle = "rgba(24,14,58,.16)"; x.lineWidth = 2;
  x.beginPath(); x.roundRect(bx, by, box, box, 14); x.stroke();
  const q = qrcode(0, "M");
  q.addData(payload(evento, m));
  q.make();
  const n = q.getModuleCount(), pad = box * .07, cell = (box - 2 * pad) / n;
  x.fillStyle = "#000";
  for (let r = 0; r < n; r++)
    for (let k = 0; k < n; k++)
      if (q.isDark(r, k)) x.fillRect(bx + pad + k * cell, by + pad + r * cell, cell + .6, cell + .6);

  x.fillStyle = TINTA;
  x.font = '500 40px "DM Mono", monospace';
  x.fillText("#" + m.code, W / 2, by + box + 62);

  // a nombre de quién
  x.font = '600 38px "Inter Tight", sans-serif';
  x.fillText(renglones(x, m.titular || "—", W - 120, 1)[0] || "—", W / 2, by + box + 122);
  x.fillStyle = GRIS;
  x.font = '400 26px "DM Mono", monospace';
  if (m.ci) x.fillText(`CI ${m.ci}`, W / 2, by + box + 164);

  // lo que trae
  let y = by + box + 232;
  x.fillStyle = TINTA;
  x.font = '600 30px "Inter Tight", sans-serif';
  x.fillText(entradasDeMesa(m.entradas_incluidas), W / 2, y);
  if (m.incluye) {
    x.font = '400 27px "Inter Tight", sans-serif';
    x.fillStyle = GRIS;
    for (const l of renglones(x, "Incluye: " + m.incluye, W - 140, 3)) { y += 40; x.fillText(l, W / 2, y); }
  }

  // las condiciones, en una caja: es lo que se aceptó al pagar
  const cond = Array.isArray(m.condiciones) && m.condiciones.length ? m.condiciones : CONDICIONES_MESA;
  y += 46;
  const cy = y, ch = 40 + cond.length * 42;
  x.strokeStyle = TINTA; x.lineWidth = 2.5;
  x.beginPath(); x.roundRect(70, cy, W - 140, ch, 10); x.stroke();
  x.fillStyle = TINTA;
  x.font = '500 26px "Inter Tight", sans-serif';
  cond.forEach((t, i) => x.fillText(t, W / 2, cy + 52 + i * 42));

  if (m.estado === "anulada") {
    // Anulada se dice encima de todo, en diagonal: un recibo anulado que
    // se ve igual que uno válido es una discusión en la puerta.
    x.save();
    x.translate(W / 2, by + box / 2); x.rotate(-0.32);
    x.font = '800 150px "Big Shoulders Display", sans-serif';
    x.fillStyle = "rgba(196,36,59,.82)";
    x.fillText("ANULADA", 0, 50);
    x.restore();
  }

  // el pie oscuro lleva la firma, que está escrita para fondo oscuro
  const PIE = 92, Hf = Math.min(H, Math.ceil(cy + ch + 56 + PIE));
  const f = document.createElement("canvas");
  f.width = W; f.height = Hf;
  const y2 = f.getContext("2d");
  y2.drawImage(c, 0, 0, W, Hf - PIE, 0, 0, W, Hf - PIE);
  y2.fillStyle = TINTA; y2.fillRect(0, Hf - PIE, W, PIE);
  firma(y2, W, Hf, { centro: true, y: Hf - 36 });
  return f.toDataURL("image/png");
}

/* El recibo en la página: la imagen, lo que dice en letras (para quien no
   la puede leer de un vistazo y para el lector de pantalla) y el botón de
   la puerta. `m` es lo que arma recibo_mesa_orden(): el carnet ya viene
   enmascarado y el correo no se muestra, porque este link se reenvía.
   `o.png` es la imagen ya dibujada; `o.pase` el número del botón de la
   puerta (sin él no hay botón). */
function reciboMesa(m, o) {
  if (!m || !m.code) return "";
  o = o || {};
  const cond = Array.isArray(m.condiciones) && m.condiciones.length ? m.condiciones : CONDICIONES_MESA;
  const anulada = m.estado === "anulada";
  const presentado = m.presentado_at
    ? new Date(m.presentado_at).toLocaleTimeString("es-BO", { hour: "2-digit", minute: "2-digit",
        hour12: false, timeZone: "America/La_Paz" }) : null;
  return `<figure class="recibo-mesa${anulada ? " anulada" : ""}">
    ${o.png ? `<div class="pase-arte recibo-arte"><img src="${o.png}"
         alt="Recibo de la mesa ${esc(m.tipo)}, código ${esc(m.code)}"></div>` : ""}
    <figcaption class="recibo-datos">
      <p class="recibo-rotulo">${anulada ? "Mesa anulada" : "Recibo de mesa · no da ingreso"}</p>
      <h3 class="recibo-tipo">${esc(m.tipo || "Mesa")}</h3>
      <dl>
        <div><dt>A nombre de</dt><dd>${esc(m.titular || "—")}${m.ci ? ` · CI ${esc(m.ci)}` : ""}</dd></div>
        <div><dt>Entradas</dt><dd>${esc(entradasDeMesa(m.entradas_incluidas))}</dd></div>
        ${m.incluye ? `<div><dt>Incluye</dt><dd>${esc(m.incluye)}</dd></div>` : ""}
        <div><dt>Código</dt><dd class="recibo-code">#${esc(m.code)}</dd></div>
      </dl>
      ${presentado ? `<p class="recibo-presentado">Ya te presentaste a las ${esc(presentado)}.</p>` : ""}
      <ul class="cond-mesa">${cond.map(t => `<li>${esc(t)}</li>`).join("")}</ul>
      ${o.pase != null && !anulada
        ? `<button type="button" class="btn pase-puerta" data-pase="${Number(o.pase)}">Mostrar la mesa en la puerta</button>` : ""}
    </figcaption>
  </figure>`;
}

/* ── guardarla en el teléfono ────────────────────────────────────
   Guardar no es descargar. En un teléfono la descarga de seis PNG no deja
   nada a la vista, y el que compró tampoco va a buscar una carpeta: comparte,
   saca captura o mantiene apretada la imagen. navigator.share con archivos
   abre esa misma hoja del sistema, con "Guardar imagen" adentro, que es el
   gesto que la gente ya conoce. La descarga queda de respaldo para
   escritorio y para el navegador que no la tenga.

   Devuelve qué pasó para que la página avise lo que corresponde: después de
   compartir, el sistema ya dio su propio acuse y otro cartel sobra. */
async function guardar(entradas) {
  const archivos = await Promise.all(entradas.map(async (e, i) => {
    const b = await (await fetch(e.png)).blob();
    // Con arte la entrada es JPEG; la propia, PNG. El nombre sigue al tipo.
    const tipo = b.type || "image/png";
    const ext = tipo === "image/jpeg" ? "jpg" : "png";
    // El recibo de la mesa (0108) se llama recibo-mesa-…: guardado junto a
    // las entradas, tiene que poder distinguirse en el rollo de fotos.
    return new File([b], `${e.archivo || "entrada"}-${i + 1}-${e.code}.${ext}`, { type: tipo });
  }));

  if (navigator.canShare && navigator.canShare({ files: archivos })) {
    try {
      await navigator.share({ files: archivos });
      return "compartida";
    } catch (err) {
      if (err.name === "AbortError") return "cancelada";
      // Cualquier otro fallo cae a la descarga: la entrada se guarda igual.
    }
  }

  archivos.forEach(f => {
    const u = URL.createObjectURL(f);
    const a = document.createElement("a");
    a.href = u; a.download = f.name;
    document.body.appendChild(a); a.click(); a.remove();
    setTimeout(() => URL.revokeObjectURL(u), 10000);
  });
  return "bajada";
}

window.dibujarTicket   = dibujarTicket;
window.dibujarQR       = dibujarQR;
window.payloadEntrada  = payload;
window.tiraTickets     = tira;
window.guardarEntradas = guardar;
window.dibujarRecibo   = dibujarRecibo;
window.reciboMesa      = reciboMesa;
window.entradasDeMesa  = entradasDeMesa;
window.CONDICIONES_MESA = CONDICIONES_MESA;
})();
