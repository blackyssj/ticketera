/* ══════════════════════════════════════════════════════════════════
   TICKETAZO · la portada

   La puerta de entrada: qué hay a la venta y un link a cada evento. Habla
   con una sola Edge Function (`eventos`) y con nada más — sin sesión, sin
   supabase-js y sin escribir una línea en la base. Todo lo que se pinta
   acá ya vino filtrado por la función, que es la que decide qué puede ver
   el público.

   `fetch` pelado y no el cliente de supabase, como en orden.js: es un GET
   sin autenticación, y traer 40 kB de SDK por CDN para eso retrasaría lo
   único que importa en la primera pantalla — las tarjetas.
   ══════════════════════════════════════════════════════════════════ */
(() => {
"use strict";

const CFG = window.CONFIG || {};
const $ = s => document.querySelector(s);
const esc = s => String(s ?? "").replace(/[&<>"']/g, c =>
  ({ "&":"&amp;", "<":"&lt;", ">":"&gt;", '"':"&quot;", "'":"&#39;" }[c]));

const bs = n => Number(n).toLocaleString("es-BO") + " Bs";

/* Los tres sellos que puede llevar un afiche. `abierta` no lleva ninguno:
   un cartel que dice "hay entradas" en todas las tarjetas no informa nada,
   sólo le quita fuerza al que sí importa. */
const SELLOS = {
  ultimas:  { clase: "sello-pocas",   txt: "Últimas entradas" },
  agotado:  { clase: "sello-agotado", txt: "Agotado" },
};

function pedirCartelera() {
  return fetch(`${CFG.SUPABASE_URL}/functions/v1/eventos`, {
    headers: { Authorization: `Bearer ${CFG.SUPABASE_ANON_KEY}` },
  }).then(r => r.json());
}

/* ── el afiche ──
   Con arte, la imagen. Sin arte, un afiche tipográfico con el nombre a
   tamaño de cartel: un evento recién cargado no puede verse como una
   tarjeta rota, porque el que llega no sabe que le falta el flyer — ve una
   ticketera que no funciona. */
function afiche(e) {
  const sello = SELLOS[e.venta]
    ? `<span class="sello ${SELLOS[e.venta].clase}">${esc(SELLOS[e.venta].txt)}</span>` : "";

  if (e.arte_url) {
    return `<div class="afiche">
      <img src="${esc(e.arte_url)}" alt="Flyer de ${esc(e.nombre)}" loading="lazy" decoding="async">
      ${sello}
    </div>`;
  }
  return `<div class="afiche afiche-tipo">
    <span class="afiche-nombre">${esc(e.nombre)}</span>
    <span class="afiche-org">${esc(e.organizador_nombre)}</span>
    ${sello}
  </div>`;
}

function tarjeta(e, i) {
  /* El nombre y el organizador van en el talón sólo cuando el afiche es una
     imagen. Sin arte los dos ya están arriba —el nombre enorme, el
     organizador bajo la raya fluor—, y repetirlos quince píxeles más abajo
     es un tartamudeo, no una jerarquía. El precio queda a la derecha en
     los dos casos, que es donde se lo busca. */
  const conArte = !!e.arte_url;
  const nombre = conArte ? `<h3 class="nombre">${esc(e.nombre)}</h3>` : "";
  const quien = conArte ? `<span class="quien">${esc(e.organizador_nombre)}</span>` : "";
  const desde = e.desde !== null && e.desde !== undefined
    ? `<span class="desde">Desde <b>${esc(bs(e.desde))}</b></span>` : "";

  return `<a class="evento${e.venta === "agotado" ? " agotado" : ""}"
             href="${esc(e.url)}" style="--i:${i}">
    ${afiche(e)}
    <div class="perf" aria-hidden="true"><i class="izq"></i><i class="der"></i></div>
    <div class="talon">
      <span class="cuando">${esc(e.fecha_txt)}</span>
      ${nombre}
      <p class="donde">${esc(e.lugar)}</p>
      <div class="pie-talon">
        ${quien}
        ${desde}
      </div>
    </div>
  </a>`;
}

/* Un cartel ocupa la pared entera. Se usa para las dos situaciones en que
   no hay tarjetas, que no son la misma: no haber nada a la venta es un
   estado normal del negocio y no pide botón; no haber podido cargar es una
   falla y sí lo pide. */
function cartel(titulo, texto, accion) {
  return `<div class="cartel">
    <h3>${esc(titulo)}</h3>
    <p>${esc(texto)}</p>
    ${accion ? `<button class="btn" id="btnReintentar" type="button">${esc(accion)}</button>` : ""}
  </div>`;
}

function contar(n) {
  $("#rotuloCuenta").textContent =
    n === 1 ? "1 evento" : `${n} eventos`;
}

async function pintar() {
  const grilla = $("#grilla");
  let r = null, motivo = "";
  try {
    r = await pedirCartelera();
  } catch {
    /* No se muestra el error del navegador: "Failed to fetch" está en inglés
       y no le dice nada a nadie. Lo único cierto y accionable es que no se
       llegó al servidor, y que casi siempre es la conexión del teléfono. */
    motivo = "No llegamos al servidor. Puede ser tu conexión: probá de nuevo.";
  }
  if (!motivo && (!r || r.ok === false)) motivo = r?.motivo || "La cartelera no respondió.";

  if (motivo) {
    grilla.setAttribute("aria-busy", "false");
    $("#rotuloCuenta").textContent = "";
    grilla.innerHTML = cartel("No se pudo cargar la cartelera", motivo, "Reintentar");
    $("#btnReintentar").addEventListener("click", () => {
      grilla.setAttribute("aria-busy", "true");
      grilla.innerHTML = "";
      $("#rotuloCuenta").textContent = "Cargando…";
      pintar();
    });
    return;
  }

  const eventos = r.eventos || [];
  grilla.setAttribute("aria-busy", "false");

  if (!eventos.length) {
    $("#rotuloCuenta").textContent = "";
    grilla.innerHTML = cartel(
      "Todavía no hay nada a la venta",
      "Los eventos aparecen acá apenas el organizador los publica. Volvé en unos días.");
    return;
  }

  contar(eventos.length);
  grilla.innerHTML = eventos.map(tarjeta).join("");
}

pintar();
})();
