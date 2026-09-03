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

/* ── mis entradas: la única escritura de esta página sobre esa clave ──
   Quien compra ya queda guardado por la propia pantalla de compra. Este
   link es la otra puerta: alguien lo abre en un teléfono donde la compra
   nunca pasó —típicamente, quien lo recibió por WhatsApp— y si no se suma
   acá, esa persona jamás tiene "Mis entradas", sólo el link suelto. Se
   agrega una sola vez (por id) y nunca se pisa lo que ya estaba: esta
   página no sabe nada del resto de las compras de ese aparato como para
   decidir por ellas. */
const MES_TXT = ["ENE","FEB","MAR","ABR","MAY","JUN","JUL","AGO","SEP","OCT","NOV","DIC"];
const DIA_TXT = ["DOM","LUN","MAR","MIÉ","JUE","VIE","SÁB"];
const diaBoliviano = d => new Date(d.getTime() - 4 * 3600e3).getUTCDay();

/* fecha_txt ("SÁB 12 SEP · 21:00") no trae año: nunca hizo falta para
   mostrarlo. Se prueban este año y el que viene, y gana el que caiga en el
   día de semana que el propio texto declara -la misma reconstrucción que
   usa app.js para el botón de calendario, repetida acá porque esta página
   no comparte módulos con esa. Si ninguno cierra, se guarda sin fecha
   antes que inventar una: mis-entradas sabe mostrar ese caso. */
function fechaDesdeTexto(txt) {
  txt = String(txt || "").toUpperCase();
  const md = txt.match(/(\d{1,2})\s+([A-ZÁÉÍÓÚÑ]{3})/);
  const mes = md ? MES_TXT.indexOf(md[2]) : -1;
  if (mes < 0) return null;
  const hm = txt.match(/(\d{1,2}):(\d{2})/);
  const semana = (txt.match(/^([A-ZÁÉÍÓÚÑ]{3})/) || [])[1];
  const p2 = n => String(n).padStart(2, "0");
  const anio = new Date().getFullYear();
  const cand = [0, 1]
    .map(n => new Date(`${anio + n}-${p2(mes + 1)}-${p2(md[1])}` +
                       `T${hm ? p2(hm[1]) : "21"}:${hm ? hm[2] : "00"}:00-04:00`))
    .filter(d => !isNaN(d.getTime()));
  return cand.find(d => DIA_TXT[diaBoliviano(d)] === semana)
      || cand.find(d => d.getTime() > Date.now() - 864e5)
      || null;
}

function sumarAMisEntradas(r) {
  try {
    const KEY = "ticketazo.compras";
    const lista = JSON.parse(localStorage.getItem(KEY) || "[]");
    if (!Array.isArray(lista) || lista.some(c => c && c.id === r.orden.id)) return;
    // Si la función manda la fecha cruda, ésa manda; el texto es el respaldo.
    const cruda = r.evento.fecha
      ? new Date(`${r.evento.fecha}T${String(r.evento.hora_inicio || "21:00").slice(0, 5)}:00-04:00`) : null;
    const f = cruda && !isNaN(cruda.getTime()) ? cruda : fechaDesdeTexto(r.evento.fecha_txt);
    lista.push({
      id: r.orden.id,
      evento: `${r.evento.marca_1} ${r.evento.marca_2}`.trim(),
      // Esta página sólo tiene el uuid de la orden; el organizador y el
      // slug del evento no viajan en la respuesta de `orden`, así que
      // quedan vacíos. mis-entradas no los necesita para nada: el botón de
      // cada tarjeta abre este mismo link, por id.
      org: "", slug: "",
      fecha: f ? f.toISOString() : "",
      lugar: r.evento.lugar || "",
      entradas: r.entradas.length,
      guardada: Date.now(),
    });
    localStorage.setItem(KEY, JSON.stringify(lista));
  } catch { /* storage bloqueado o clave corrupta: no es motivo para romper esta página */ }
}

/* Un solo lugar donde la página dice en qué está. El estado va en el panel
   porque de él dependen el sello y todo lo que no corresponde mostrar
   mientras la compra no aparezca. */
function decir(titulo, nota, estado) {
  $("#titulo").textContent = titulo;
  $("#nota").textContent = nota;
  $("#panel").dataset.estado = estado || "buscando";
  $("#sello").hidden = estado !== "ok";
}

let entradas = [];
let evento = null;

const ES_UUID = v => /^[0-9a-f-]{36}$/i.test(String(v || ""));

/* A esta página se llega por dos puertas y el `?id=` no significa lo mismo
   en las dos.

   Por el link que queda guardado, es el uuid de la orden.

   Por la vuelta del pago, es el id de transacción de la pasarela — pero ese
   id **empieza con nuestro uuid**, porque lo arma a partir del
   `codigoTransaccion` que le mandamos:

     orden   6654a148-30cf-4c06-88ff-6f40d2e281f3
     ?id=    6654a148-30cf-4c06-88ff-6f40d2e281f3-1522812139-c4ca4238a0b9…

   Así que los 36 primeros caracteres alcanzan y la orden se busca directo
   por su uuid. La búsqueda por pago_ref queda de respaldo, para el día que
   la pasarela cambie cómo arma ese id: si el prefijo deja de ser un uuid,
   se pregunta por el id entero en vez de fallar. Que ese camino sea el raro
   y no el normal también achica lo que se puede tantear con él — devuelve
   el nombre del comprador y los códigos de QR. */
function pedir(cuerpo) {
  return fetch(`${CFG.SUPABASE_URL}/functions/v1/orden`, {
    method: "POST",
    headers: { "Content-Type": "application/json",
               Authorization: `Bearer ${CFG.SUPABASE_ANON_KEY}` },
    body: JSON.stringify(cuerpo),
  }).then(res => res.json());
}

/* Volver del banco y leer "todavía sin confirmar" es el momento en que el
   comprador cree que perdió la plata. El cobro se confirma preguntándole a
   la pasarela, así que se le pregunta —unas cuantas veces, espaciado— antes
   de darle esa noticia. */
async function esperarConfirmacion(orden) {
  for (let i = 0; i < 8; i++) {
    await new Promise(r => setTimeout(r, i < 3 ? 1500 : 4000));
    let e;
    try {
      const res = await fetch(`${CFG.SUPABASE_URL}/functions/v1/estado-orden`, {
        method: "POST",
        headers: { "Content-Type": "application/json",
                   Authorization: `Bearer ${CFG.SUPABASE_ANON_KEY}` },
        body: JSON.stringify({ orden }),
      });
      e = await res.json();
    } catch { continue; }
    if (e.ok && e.estado === "pagada") return true;
    if (e.ok === false) return false;
  }
  return false;
}

async function cargar() {
  const id = new URLSearchParams(location.search).get("id");
  if (!id) { decir("Falta el link", "Abrí el link completo que te llegó al correo.", "error"); return; }

  /* El uuid va adelante. Si los 36 primeros no tienen forma de uuid, el id
     no es lo que esperamos y se cae al respaldo en vez de mandar cualquier
     cosa como si fuera una orden. */
  const prefijo = String(id).slice(0, 36);

  let r;
  try {
    r = await pedir(ES_UUID(prefijo) ? { orden: prefijo } : { pago_ref: id });
  } catch {
    decir("No se pudo cargar", "Revisá tu conexión y volvé a intentar.", "error");
    return;
  }

  if (!r.ok) { decir("No encontramos tu compra", r.motivo || "Revisá el link.", "error"); return; }

  /* El link que le queda al comprador es siempre el del uuid: es el que
     funciona para siempre. El de la pasarela sirve un rato y solo para
     volver. replaceState y no un redirect, para no perder el historial. */
  const uuid = r.orden?.id || r.orden;
  if (id !== uuid && ES_UUID(uuid)) {
    history.replaceState(null, "", `?id=${uuid}`);
  }

  if (r.estado !== "pagada") {
    decir("Confirmando tu pago", "Un momento, estamos verificándolo con el banco.");
    if (ES_UUID(uuid) && await esperarConfirmacion(uuid)) {
      r = await pedir({ orden: uuid });
    }
    if (!r.ok || r.estado !== "pagada") {
      decir("Todavía sin confirmar",
            "Si ya pagaste, el cobro puede tardar unos minutos. Volvé a abrir " +
            "este link en un rato: tus entradas aparecen acá solas.", "error");
      return;
    }
  }

  evento = r.evento;
  $("#marca").innerHTML = `<b>${esc(r.evento.marca_1)}</b> ${esc(r.evento.marca_2)}`;
  $("#barraFecha").textContent = r.evento.fecha_txt;
  document.title = `Tus entradas — ${r.evento.marca_1} ${r.evento.marca_2}`;

  const n = r.entradas.length;
  const usadas = r.entradas.filter(e => e.estado === "usada").length;
  /* "ok" enciende el sello del cobro. Es lo primero que tiene que quedar
     claro: quien abre esta página acaba de pagar, o vuelve semanas después
     a comprobar que lo que pagó sigue existiendo. */
  decir("Tus entradas",
    `${n} ${n === 1 ? "entrada" : "entradas"} a nombre de ${r.orden.comprador}.` +
    (usadas ? ` ${usadas} ya ${usadas === 1 ? "ingresó" : "ingresaron"}.` : ""),
    "ok");

  /* fecha_txt ya trae el día y la hora de apertura; el evento las llama
     "Puertas" en la página de venta y acá se llaman igual. */
  $("#cuandoHora").textContent = r.evento.fecha_txt;
  $("#cuandoLugar").textContent = r.evento.lugar || "—";
  $("#cuando").hidden = !r.evento.lugar && !r.evento.fecha_txt;

  sumarAMisEntradas(r);

  $("#tickets").innerHTML = `<p class="rail-vacio">Dibujando…</p>`;
  if (document.fonts && document.fonts.ready) await document.fonts.ready;

  entradas = r.entradas;
  const pngs = [];
  for (const e of entradas) pngs.push(await window.dibujarTicket(e, r.evento, r.fase));
  entradas.forEach((e, i) => e.png = pngs[i]);

  $("#tickets").innerHTML = window.tiraTickets(entradas, { puerta: true });

  $("#instruccion").hidden = false;
  $("#acciones").hidden = false;

  /* El link con el uuid es el único camino de vuelta si el correo se pierde
     o el teléfono cambia de dueño de pestaña. Se muestra entero y con un
     botón para copiarlo, no escondido en la barra de direcciones. */
  const link = `${location.origin}/orden/?id=${r.orden.id}`;
  $("#linkOrden").textContent = link;
  $("#bloqueLink").hidden = false;
  $("#btnCopiarLink").onclick = async () => {
    try { await navigator.clipboard.writeText(link); avisar("Link copiado."); }
    catch (err) { avisar("No se pudo copiar: " + err.message); }
  };

  /* El uuid entero no le dice nada a nadie y ocupaba dos renglones. Los ocho
     primeros alcanzan para que la organización encuentre la compra, que es
     para lo único que el comprador va a leer este número. */
  $("#pie").textContent =
    `Orden #${String(r.orden.id).slice(0, 8).toUpperCase()}. ` +
    `Pasá este número si necesitás ayuda con tu compra.`;
}

/* ── guardar ─────────────────────────────────────────────────────── */
$("#btnGuardar").addEventListener("click", async () => {
  const b = $("#btnGuardar");
  b.disabled = true;
  try {
    const como = await window.guardarEntradas(entradas);
    // Después de compartir, el sistema ya dio su propio acuse: otro cartel sobra.
    if (como === "bajada")
      avisar(`${entradas.length} ${entradas.length === 1
        ? "entrada guardada" : "entradas guardadas"}.`);
  } catch (err) {
    avisar("No se pudieron guardar. Mantené apretada la entrada y elegí Guardar imagen.");
  } finally {
    b.disabled = false;
  }
});

/* ── modo puerta ─────────────────────────────────────────────────
   Lo que pasa de verdad en la puerta: pantalla negra, el QR lo más grande
   que entre y nada más. El del arte es la entrada que el comprador guarda;
   este es el que se escanea. */
let enPuerta = -1, volverA = null;

/* Se guarda el botón que abrió, no document.activeElement: al cerrar el foco
   tiene que volver exactamente ahí, y con el teclado eso es la diferencia
   entre seguir donde estabas y aparecer arriba de todo. */
function abrirPuerta(i, desde) {
  if (!entradas[i] || !evento) return;
  enPuerta = i;
  volverA = desde || document.activeElement;
  pintarPuerta();
  $("#puerta").hidden = false;
  document.body.classList.add("con-puerta");
  $("#puertaX").focus();
}

function pintarPuerta() {
  const e = entradas[enPuerta];
  const caja = $("#puertaQR");
  /* Se dibuja al tamaño que va a ocupar en píxeles del aparato: más chico se
     ve borroso y más grande no aporta nada. */
  const lado = Math.round(Math.min(innerWidth * .84, innerHeight * .46) *
                          (window.devicePixelRatio || 1));
  caja.src = window.dibujarQR(window.payloadEntrada(evento, e), lado);
  caja.alt = `Código QR de la entrada ${e.etiqueta}, ${e.code}`;
  $("#puertaCode").textContent = "#" + e.code;
  $("#puertaQuien").textContent =
    `${e.etiqueta}${e.estado === "usada" ? " · ya ingresó" : ""} · ${e.cliente || "—"}`;
  $("#puertaNav").hidden = entradas.length < 2;
  $("#puertaCuenta").textContent = `${enPuerta + 1} de ${entradas.length}`;
}

function cerrarPuerta() {
  $("#puerta").hidden = true;
  document.body.classList.remove("con-puerta");
  enPuerta = -1;
  if (volverA && volverA.focus) volverA.focus();
}

function moverPuerta(paso) {
  const n = entradas.length;
  enPuerta = (enPuerta + paso + n) % n;
  pintarPuerta();
}

$("#tickets").addEventListener("click", e => {
  const b = e.target.closest("[data-pase]");
  if (b) abrirPuerta(Number(b.dataset.pase), b);
});
$("#puertaX").addEventListener("click", cerrarPuerta);
$("#puertaAnt").addEventListener("click", () => moverPuerta(-1));
$("#puertaSig").addEventListener("click", () => moverPuerta(1));
addEventListener("keydown", e => {
  if (enPuerta < 0) return;
  if (e.key === "Escape") { e.preventDefault(); cerrarPuerta(); }
  if (e.key === "ArrowLeft") moverPuerta(-1);
  if (e.key === "ArrowRight") moverPuerta(1);
});
addEventListener("resize", () => { if (enPuerta >= 0) pintarPuerta(); });

cargar();
})();
