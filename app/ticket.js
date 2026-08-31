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
function cargarImagen(url) {
  return new Promise((ok, mal) => {
    const i = new Image();
    i.crossOrigin = "anonymous";
    i.onload = () => ok(i);
    i.onerror = () => mal(new Error("No se pudo cargar el arte."));
    i.src = url;
  });
}

/* Con arte subido: el QR va ENCIMA de la imagen del organizador, como en
   Bowie y BurTown. Mismas proporciones que allá — caja blanca del 52% del
   ancho desde el 29% de la altura — para que un arte hecho para Puerta sirva
   acá sin rehacerlo. */
async function sobreArte(t, evento, fase, arte) {
  const img = await cargarImagen(arte);
  const W = img.naturalWidth, H = img.naturalHeight;
  const c = document.createElement("canvas");
  c.width = W; c.height = H;
  const x = c.getContext("2d");
  x.drawImage(img, 0, 0);

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
  x.font = `700 ${Math.round(W * 0.078)}px "DM Mono", monospace`;
  x.fillText("#" + t.code, W / 2, by + caja + H * 0.055);
  x.font = `500 ${Math.round(W * 0.042)}px "Inter Tight", sans-serif`;
  x.fillText(t.cliente || "—", W / 2, by + caja + H * 0.055 + W * 0.075);
  return c.toDataURL("image/png");
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
function tira(entradas, opciones) {
  const o = opciones || {};
  const n = entradas.length;
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
        ${o.puerta ? `<button type="button" class="btn pase-puerta" data-pase="${i}">Mostrar en la puerta</button>` : ""}
      </div>
    </figure>`;
  }).join("");
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
    return new File([b], `entrada-${i + 1}-${e.code}.png`, { type: "image/png" });
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
})();
