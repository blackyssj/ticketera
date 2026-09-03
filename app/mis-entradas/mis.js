/* ══════════════════════════════════════════════════════════════════
   MIS ENTRADAS — la lista de compras de ESTE teléfono.

   No hay login ni backend acá: todo lo que esta página sabe vive en
   localStorage, bajo la clave `ticketazo.compras`. La llena quien compra
   (al pagar) y orden.js (cuando alguien abre el link de una compra que
   este aparato todavía no tenía guardada — típicamente, quien lo recibe
   por WhatsApp). Esta página sólo LEE esa lista, salvo por una escritura
   propia: sacar una compra cuando alguien toca "Quitar".

   El contrato de cada elemento:
     { id, evento, org, slug, fecha, lugar, entradas, guardada }
   `fecha` debería ser un ISO con año y huso (así la escribe quien acaba de
   comprar, y así la reconstruye orden.js a partir de `fecha_txt`). Pero la
   clave es de otro proceso y puede llegar vacía, vieja o rota, así que acá
   nada se da por sentado: si `JSON.parse` falla, o un campo no es el que
   se espera, la página cae al estado vacío o al mejor dato disponible —
   nunca a un error en pantalla. */
(() => {
"use strict";

const KEY = "ticketazo.compras";
const $ = s => document.querySelector(s);
const esc = s => String(s ?? "").replace(/[&<>"']/g, c =>
  ({ "&":"&amp;", "<":"&lt;", ">":"&gt;", '"':"&quot;", "'":"&#39;" }[c]));

/* ── leer / guardar ──
   Un solo lugar toca la clave, y siempre con try/catch: un navegador con
   el storage bloqueado (modo privado agresivo, política de la empresa) no
   tiene por qué dejar esta página en blanco, sólo sin memoria. */
function leer() {
  try {
    const l = JSON.parse(localStorage.getItem(KEY) || "[]");
    return Array.isArray(l) ? l.filter(c => c && typeof c.id === "string") : [];
  } catch { return []; }
}
function guardar(lista) {
  try { localStorage.setItem(KEY, JSON.stringify(lista)); } catch { /* no persiste, no rompe */ }
}

/* ── la fecha sin año ──
   Misma idea que la reconstrucción de app.js para el botón de calendario:
   `fecha_txt` ("SÁB 12 SEP · 21:00") no trae año porque nunca hizo falta
   para mostrarlo. Cuando `fecha` ya es un ISO de verdad (el camino normal,
   hoy) `new Date` la entiende sola y no se llega ni a intentar esto; el
   regex es la red por si algún registro viejo o corrupto sólo trae el
   texto. Se prueban este año y el que viene y gana el que caiga en el día
   de semana que el propio texto declara — adivinar el año a ciegas puede
   mandar un evento de septiembre a la lista de "ya pasaron" en enero. */
const MES_TXT = ["ENE","FEB","MAR","ABR","MAY","JUN","JUL","AGO","SEP","OCT","NOV","DIC"];
const DIA_TXT = ["DOM","LUN","MAR","MIÉ","JUE","VIE","SÁB"];
const diaBoliviano = d => new Date(d.getTime() - 4 * 3600e3).getUTCDay();

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

function fechaDe(c) {
  if (!c || !c.fecha) return null;
  const directa = new Date(c.fecha);
  if (!isNaN(directa.getTime())) return directa;
  return fechaDesdeTexto(c.fecha);
}

/* "SÁB 12 SEP · 21:00": el mismo formato que ya usa orden.js, para que la
   fecha de una entrada se lea igual en todo el sitio. Se arma con
   Intl + America/La_Paz y no con getDay()/getHours(), que contestan según
   el reloj de quien mira la página — y esta lista la puede abrir alguien
   de visita, con el teléfono en otro huso. */
const DIA_ES = ["DOM","LUN","MAR","MIÉ","JUE","VIE","SÁB"];
const MES_ES = ["ENE","FEB","MAR","ABR","MAY","JUN","JUL","AGO","SEP","OCT","NOV","DIC"];
const DIA_EN = ["Sun","Mon","Tue","Wed","Thu","Fri","Sat"];
const MES_EN = ["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"];

function partesBolivia(d) {
  return new Intl.DateTimeFormat("en-US", {
    timeZone: "America/La_Paz", weekday: "short", day: "numeric",
    month: "short", hour: "2-digit", minute: "2-digit", hour12: false,
  }).formatToParts(d).reduce((o, p) => (o[p.type] = p.value, o), {});
}
function formatearFecha(d) {
  const p = partesBolivia(d);
  const dia = DIA_ES[DIA_EN.indexOf(p.weekday)] ?? p.weekday;
  const mes = MES_ES[MES_EN.indexOf(p.month)] ?? p.month;
  const hora = p.hour === "24" ? "00" : p.hour;
  return `${dia} ${p.day} ${mes} · ${hora}:${p.minute}`;
}
function diaGrande(d) {
  return new Intl.DateTimeFormat("en-US", { timeZone: "America/La_Paz", day: "numeric" }).format(d);
}

/* ── la tarjeta ──
   La misma entrada troquelada de la portada (.evento → .afiche/.papel →
   .perf → .talon): esta lista nunca tiene flyer, así que el papel —que en
   la cartelera es el respaldo para cuando la imagen no llegó— es acá la
   única superficie, y por eso el nombre va SIEMPRE ahí y no se repite en
   el talón (la misma regla que ya usan tarjeta() y destacado() en
   portada.js). El talón cambia el precio por la cantidad de entradas, que
   es el dato que importa en esta lista, y cierra con dos botones en vez
   de ser el link entero: "Ver entrada" abre el link de siempre, "Quitar"
   sólo saca la fila de este teléfono. */
function tarjetaCompra(c, pasada) {
  const d = fechaDe(c);
  const cuando = d ? formatearFecha(d) : "Fecha a confirmar";
  const diaTxt = d ? diaGrande(d) : "—";
  const n = Math.max(1, Number(c.entradas) || 1);
  return `<article class="evento compra${pasada ? " pasada" : ""}">
    <div class="afiche">
      <div class="papel">
        <span class="papel-dia" aria-hidden="true">${esc(diaTxt)}</span>
        <h3 class="papel-nombre">${esc(c.evento || "Entrada")}</h3>
        ${c.org ? `<span class="papel-org">${esc(c.org)}</span>` : ""}
      </div>
    </div>
    <div class="perf" aria-hidden="true"><i class="p1"></i><i class="p2"></i></div>
    <div class="talon">
      <div class="cuando"><span>${esc(cuando)}</span></div>
      <div class="pie-talon">
        <span class="donde">${esc(c.lugar || "Lugar a confirmar")}</span>
        <span class="cant">${n} ${n === 1 ? "entrada" : "entradas"}</span>
      </div>
      <div class="accion">
        <a class="ver" href="/orden/?id=${encodeURIComponent(c.id)}">Ver entrada<i class="flecha" aria-hidden="true"></i></a>
        <button type="button" class="quitar" data-quitar="${esc(c.id)}">Quitar</button>
      </div>
    </div>
  </article>`;
}

/* El cartel de "no hay nada" reusa el mismo componente que la cartelera
   vacía o caída (`.cartel`, en portada.css): un talón en blanco no puede
   parecer una página rota. Dice las tres cosas que pide el spec — dónde
   se guardan, qué pasa si compró en otro aparato, y a dónde ir. */
function cartelVacio() {
  return `<div class="cartel">
    <h3>Todavía no tenés entradas acá</h3>
    <p>Se guardan en este teléfono cuando comprás. Si compraste desde otro
       dispositivo, no las vas a ver acá — pero tenés el link que te quedó
       después de pagar, y ese sigue sirviendo siempre.</p>
    <a class="btn" href="/">Ver la cartelera</a>
  </div>`;
}

/* ── pintar ──
   Próximas primero (la que sigue, antes), pasadas después (la más
   reciente arriba: es la que alguien más probablemente vino a revisar).
   Una compra sin fecha reconocible cae del lado de "próxima" — esconder
   una entrada que ya se pagó por no poder leerle la fecha es peor que
   dejarla arriba sin ordenar bien. */
function pintar() {
  const compras = leer();
  const ahora = Date.now();
  const enriquecidas = compras.map(c => {
    const d = fechaDe(c);
    return { c, d, pasada: !!d && d.getTime() < ahora };
  });

  const proximas = enriquecidas.filter(x => !x.pasada)
    .sort((a, b) => (a.d ? a.d.getTime() : Infinity) - (b.d ? b.d.getTime() : Infinity));
  const pasadas = enriquecidas.filter(x => x.pasada)
    .sort((a, b) => b.d.getTime() - a.d.getTime());

  $("#seccionVacio").hidden = compras.length > 0;
  if (!compras.length) $("#carrilVacio").innerHTML = cartelVacio();

  $("#seccionProximas").hidden = !proximas.length;
  $("#grillaProximas").innerHTML = proximas.map(x => tarjetaCompra(x.c, false)).join("");

  $("#seccionPasadas").hidden = !pasadas.length;
  $("#grillaPasadas").innerHTML = pasadas.map(x => tarjetaCompra(x.c, true)).join("");
}

/* ── el toast con deshacer ──
   Quitar es local y reversible durante unos segundos: no hay servidor del
   que perder nada, pero si esta era la única copia del link a mano, un
   toque de más no tiene por qué costar la entrada. */
let tOculto;
function avisar(texto, deshacer) {
  const t = $("#toast");
  $("#toastTxt").textContent = texto;
  const btn = $("#toastDeshacer");
  btn.hidden = !deshacer;
  btn.onclick = deshacer ? () => { deshacer(); ocultarToast(); } : null;
  t.dataset.on = "1";
  clearTimeout(tOculto);
  tOculto = setTimeout(ocultarToast, 6000);
}
function ocultarToast() { $("#toast").dataset.on = "0"; }

function quitar(id) {
  const lista = leer();
  const idx = lista.findIndex(c => c.id === id);
  if (idx < 0) return;
  const [quitada] = lista.splice(idx, 1);
  guardar(lista);
  pintar();
  avisar(`Quitaste "${quitada.evento || "esa entrada"}" de este teléfono.`, () => {
    const actuales = leer();
    actuales.push(quitada);
    guardar(actuales);
    pintar();
  });
}

document.addEventListener("click", e => {
  const b = e.target.closest("[data-quitar]");
  if (b) quitar(b.dataset.quitar);
});

pintar();
})();
