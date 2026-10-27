/* "Agregar a Google Wallet" en las páginas del comprador: /orden y
   /mis-entradas. Las dos no comparten módulos (no hay build), así que lo de
   Wallet vive acá una sola vez y cada página sólo dice dónde va el botón.

   El botón aparece únicamente si se cumplen las cuatro:
     1. el teléfono es Android, o la página se abrió con ?wallet=probar;
     2. la función wallet-google está configurada (José cargó sus secrets);
     3. Google aprobó el acceso de producción (modo "on"), o se está
        probando con ?wallet=probar: en modo demo Google sólo deja guardar a
        las cuentas de prueba y cualquier otro vería un error suyo;
     4. el botón oficial está en /wallet/. Las pautas de marca de Google
        piden usar SU botón, sin redibujarlo; si el archivo falta, no hay
        botón (mejor nada que una imitación).
   Si falla cualquiera no aparece nada: ni un botón muerto ni un hueco.

   Por qué sólo en Android: Google Wallet es una app de Android. En un
   iPhone el botón lleva a una página de Google que no puede poner nada en
   el teléfono (y Apple Wallet pide la membresía paga de Apple). En una
   computadora el pase se guarda en la cuenta de Google, pero en la puerta
   hace falta en el teléfono, y ahí el comprador abre este mismo link. El
   botón del correo (más adelante) sí va siempre, porque un correo no sabe
   en qué teléfono se abre; lleva la aclaración "En Android" y apunta a
   /orden/?id=<uuid>#wallet, NUNCA a la función: los escáneres de links de
   los buzones abren todo lo que trae el correo, y el pase (con el nombre
   del comprador) sólo se arma cuando una persona toca este botón.

   Por eso es un <button> y no un link: lo que arma el pase es un POST
   (wallet-google no hace nada con un GET). Tarda uno o dos segundos
   (Google crea la clase y los objetos), así que la página dice "Preparando
   tu pase…" y, si algo falla, avisa sin recargarse. */
(() => {
"use strict";

const CFG = window.CONFIG || {};
const FN = `${CFG.SUPABASE_URL}/functions/v1/wallet-google`;
/* El archivo oficial de Google, sin tocar: "Add to Google Wallet",
   variante primaria, en español de Latinoamérica (del zip de SVG de
   developers.google.com/wallet/.../brand-guidelines). */
const BOTON = "/wallet/agregar-a-google-wallet.svg";
const ALT = "Agregar a Google Wallet";
/* El mismo tope que la función: con 7 entradas el link pasa de los 1.800
   caracteres y el navegador lo puede cortar. Una compra de más va en tandas. */
const TANDA = 6;
/* El `error` de MOTIVO en wallet-google, para cuando la función ni
   contesta. Los demás avisos los manda ella. */
const AVISO_ERROR = "No pudimos agregarla a Google Wallet. Probá de nuevo en un rato.";
/* Hasta cuándo se ofrece: la misma cuenta que wallet-google para aceptarlo
   (horario() + PASADO_MS), así no hay botón que sólo sirva para recibir
   "este evento ya pasó". */
const DESPUES_MS = 12 * 3600e3;

const esc = s => String(s ?? "").replace(/[&<>"']/g, c =>
  ({ "&":"&amp;", "<":"&lt;", ">":"&gt;", '"':"&quot;", "'":"&#39;" }[c]));

/* ?wallet=probar queda en la pestaña: la prueba es abrir /mis-entradas con
   eso y tocar "Ver entrada", y el link de la tarjeta no lo lleva. */
function probando() {
  const enUrl = new URLSearchParams(location.search).get("wallet") === "probar";
  try {
    if (enUrl) sessionStorage.setItem("ticketazo.wallet", "probar");
    return enUrl || sessionStorage.getItem("ticketazo.wallet") === "probar";
  } catch { return enUrl; }
}

const esAndroid = () =>
  (navigator.userAgentData && navigator.userAgentData.platform === "Android") ||
  /Android/i.test(navigator.userAgent || "");

function conTope(url, ms, init = {}) {
  const ctl = new AbortController();
  const t = setTimeout(() => ctl.abort(), ms);
  return fetch(url, { ...init, signal: ctl.signal }).finally(() => clearTimeout(t));
}

/* ¿Todavía se ofrece? `abre` es la apertura (Date o ms), `horaFin` "HH:MM".
   El fin es ese día a esa hora en Bolivia (UTC-4 todo el año), y si no es
   posterior a la apertura es del día siguiente: la regla de horario() en
   wallet-google. Sin la hora de fin (Mis entradas: mis_compras() no la trae)
   va la 06:00, el default de la columna y el fin de casi todos los eventos.
   Sin fecha no se esconde nada: que decida la función. */
function vigente(abre, horaFin) {
  const t = abre instanceof Date ? abre.getTime() : abre == null ? NaN : Number(abre);
  if (!Number.isFinite(t)) return true;
  const m = /^(\d{1,2}):(\d{2})/.exec(String(horaFin || "06:00")) || [0, 6, 0];
  const BO = 4 * 3600e3;
  const medianoche = Math.floor((t - BO) / 864e5) * 864e5 + BO;   // 00:00 en Bolivia del día que abre
  let fin = medianoche + (Number(m[1]) * 60 + Number(m[2])) * 60e3;
  if (fin <= t) fin += 864e5;
  return Date.now() <= fin + DESPUES_MS;
}

/* Una sola consulta por carga, aunque la pidan las dos mitades de la
   página. Nunca tira: cualquier cosa rara es "no hay botón". */
let disponible = null;
function listo() {
  if (disponible) return disponible;
  const probar = probando();
  if (CFG.MODO !== "supabase" || !CFG.SUPABASE_URL || (!esAndroid() && !probar))
    return (disponible = Promise.resolve(false));
  // GET sin cabeceras, como la función `orden`: sin OPTIONS previo.
  const estado = conTope(`${FN}?estado=1`, 8000)
    .then(r => (r.ok ? r.json() : null)).catch(() => null);
  const imagen = new Promise(res => {
    const i = new Image();
    i.onload = () => res(true);
    i.onerror = () => res(false);
    i.src = BOTON;
  });
  disponible = Promise.all([estado, imagen])
    .then(([e, img]) => !!(img && e && e.configurado === true && (e.modo === "on" || probar)))
    .catch(() => false);
  return disponible;
}

/* Un botón por tanda de 6. Con una sola tanda no lleva rótulo: es el caso
   de casi todas las compras. */
function botones(ordenId, cuantas) {
  const n = Math.max(0, Math.floor(Number(cuantas) || 0));
  const partes = Math.ceil(n / TANDA);
  let html = "";
  for (let p = 1; p <= partes; p++) {
    const desde = (p - 1) * TANDA + 1, hasta = Math.min(n, p * TANDA);
    const rotulo = partes < 2 ? "" : desde === hasta ? `Entrada ${desde}` : `Entradas ${desde} a ${hasta}`;
    html += `<div class="gwallet">` +
      (rotulo ? `<span class="gwallet-rotulo">${rotulo}</span>` : "") +
      `<button type="button" class="gwallet-btn" data-gwallet="${esc(ordenId)}" data-parte="${p}">` +
        `<img src="${BOTON}" alt="${esc(ALT + (rotulo ? ` (${rotulo.toLowerCase()})` : ""))}" height="48" decoding="async"></button>` +
      `<span class="gwallet-espera" role="status" hidden>Preparando tu pase…</span>` +
      `</div>`;
  }
  return html;
}

/* ── el toque ── */
let ocupado = false;
function soltar() {
  ocupado = false;
  document.querySelectorAll("[data-gwallet][aria-busy]").forEach(a => {
    a.removeAttribute("aria-busy");
    const e = a.parentElement && a.parentElement.querySelector(".gwallet-espera");
    if (e) e.hidden = true;
  });
}
document.addEventListener("click", async ev => {
  const a = ev.target.closest && ev.target.closest("button[data-gwallet]");
  if (!a || ev.defaultPrevented) return;
  if (ocupado) return;
  ocupado = true;
  a.setAttribute("aria-busy", "true");
  const espera = a.parentElement && a.parentElement.querySelector(".gwallet-espera");
  if (espera) espera.hidden = false;
  const avisar = typeof GWallet.avisar === "function" ? GWallet.avisar : () => {};
  try {
    // Sin cuerpo ni cabeceras: un POST "simple", sin OPTIONS previo.
    const r = await conTope(`${FN}?orden=${encodeURIComponent(a.dataset.gwallet)}` +
                            `&parte=${encodeURIComponent(a.dataset.parte || "1")}`, 25000, { method: "POST" });
    const j = await r.json().catch(() => null);
    if (j && j.ok && typeof j.url === "string" && j.url.startsWith("https://pay.google.com/")) {
      location.href = j.url;
      /* Si Android abre la app de Wallet, esta página no se va y no hay
         `pageshow` que la despierte: el botón vuelve solo en unos segundos. */
      setTimeout(soltar, 4000);
      return;
    }
    avisar((j && j.motivo) || AVISO_ERROR);
  } catch {
    avisar(AVISO_ERROR);
  }
  soltar();
});
// Volver con "atrás" desde Google trae la página congelada como quedó: con el botón ocupado.
addEventListener("pageshow", soltar);

const GWallet = window.GWallet = { listo, botones, vigente, avisar: null };
})();
