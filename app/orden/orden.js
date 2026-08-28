/* La página del link del correo. Redibuja las entradas de una compra a partir
   del uuid de la orden, que es la credencial: impredecible, y solo lo tiene
   quien compró. No pide login a propósito — en la puerta, con la fila atrás,
   nadie se acuerda de una clave. */
(() => {
"use strict";

const CFG = window.CONFIG || {};
const $ = s => document.querySelector(s);
const esc = s => String(s ?? "").replace(/[&<>"']/g, c =>
  ({ "&":"&amp;", "<":"&lt;", ">":"&gt;", '"':"&quot;", "'":"&#39;" }[c]));

let tToast;
function avisar(txt) {
  const t = $("#toast");
  t.textContent = txt; t.dataset.on = "1";
  clearTimeout(tToast);
  tToast = setTimeout(() => t.dataset.on = "0", 4000);
}

function decir(titulo, nota) {
  $("#titulo").textContent = titulo;
  $("#nota").textContent = nota;
}

let entradas = [];

async function cargar() {
  const id = new URLSearchParams(location.search).get("id");
  if (!id) { decir("Falta el link", "Abrí el link completo que te llegó al correo."); return; }

  let r;
  try {
    const res = await fetch(`${CFG.SUPABASE_URL}/functions/v1/orden`, {
      method: "POST",
      headers: { "Content-Type": "application/json",
                 Authorization: `Bearer ${CFG.SUPABASE_ANON_KEY}` },
      body: JSON.stringify({ orden: id }),
    });
    r = await res.json();
  } catch {
    decir("No se pudo cargar", "Revisá tu conexión y volvé a intentar.");
    return;
  }

  if (!r.ok) { decir("No encontramos tu compra", r.motivo || "Revisá el link."); return; }
  if (r.estado !== "pagada") {
    decir("Todavía sin confirmar", r.motivo || "Esta compra aún no está pagada.");
    return;
  }

  $("#marca").innerHTML = `<b>${esc(r.evento.marca_1)}</b> ${esc(r.evento.marca_2)}`;
  $("#barraFecha").textContent = r.evento.fecha_txt;
  document.title = `Tus entradas — ${r.evento.marca_1} ${r.evento.marca_2}`;

  const n = r.entradas.length;
  const usadas = r.entradas.filter(e => e.estado === "usada").length;
  decir("Tus entradas",
    `${n} ${n === 1 ? "entrada" : "entradas"} a nombre de ${r.orden.comprador}.` +
    (usadas ? ` ${usadas} ya ${usadas === 1 ? "ingresó" : "ingresaron"}.` : ""));

  $("#tickets").innerHTML = `<p class="rail-vacio">Dibujando…</p>`;
  if (document.fonts && document.fonts.ready) await document.fonts.ready;

  entradas = r.entradas;
  const pngs = [];
  for (const e of entradas) pngs.push(await window.dibujarTicket(e, r.evento, r.fase));
  entradas.forEach((e, i) => e.png = pngs[i]);

  $("#tickets").innerHTML = entradas.map((e, i) =>
    `<figure class="ticket-fig">
       <img style="--i:${Math.min(i, 8)}" src="${e.png}"
            alt="Entrada ${esc(e.etiqueta)}, código ${esc(e.code)}"
            loading="${i < 2 ? "eager" : "lazy"}">
       ${e.estado === "usada" ? `<figcaption class="ticket-usada">Ya ingresó</figcaption>` : ""}
     </figure>`).join("");

  $("#acciones").hidden = false;
  $("#pie").textContent = `Orden ${r.orden.id}. Cada QR vale para un solo ingreso.`;
}

$("#btnDescargar").addEventListener("click", () => {
  entradas.forEach((e, i) => {
    const a = document.createElement("a");
    a.href = e.png;
    a.download = `entrada-${i + 1}-${e.code}.png`;
    document.body.appendChild(a); a.click(); a.remove();
  });
  avisar(`${entradas.length} ${entradas.length === 1 ? "entrada descargada" : "entradas descargadas"}.`);
});

cargar();
})();
