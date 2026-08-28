/* El ticket, dibujado en canvas del lado del cliente: cero egress de imágenes
   generadas. Vive aparte porque lo usan dos páginas — la de compra y la de
   `/orden/<uuid>`, adonde llega el link del correo.

   El payload del QR es `EVT:<evento>:<code>`, el mismo de Bowie y BurTown, así
   que el escáner de la puerta lo lee sin cambiarle una línea. */
window.dibujarTicket = (function () {
"use strict";

async function dibujarTicket(t, evento, fase) {
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
