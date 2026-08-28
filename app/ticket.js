/* El ticket, dibujado en canvas del lado del cliente: cero egress de imágenes
   generadas. Vive aparte porque lo usan dos páginas — la de compra y la de
   `/orden/<uuid>`, adonde llega el link del correo.

   El payload del QR es `EVT:<evento>:<code>`, el mismo de Bowie y BurTown, así
   que el escáner de la puerta lo lee sin cambiarle una línea. */
window.dibujarTicket = (function () {
"use strict";

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
  q.addData(`EVT:${evento.id}:${t.code}`);
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
  q.addData(`EVT:${evento.id}:${t.code}`);
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

return dibujarTicket;
})();
