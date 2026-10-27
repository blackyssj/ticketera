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
   en qué teléfono se abre; lleva la aclaración "En Android".

   El toque pide el link por fetch y recién ahí navega, en vez de ser un
   link que se va: armar el pase tarda uno o dos segundos (Google crea la
   clase y los objetos) y así la página dice "Preparando tu pase…" y, si
   algo falla, avisa sin recargarse. El href igual apunta a la función,
   que contesta con un 302 a Google: abrir en otra pestaña también anda. */
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
/* Los textos de wallet-google (MOTIVO), para cuando la función vuelve a
   /orden con un 302 (`wallet_aviso`) en vez de contestar al fetch. */
const AVISOS = {
  off:    "Google Wallet todavía no está disponible.",
  nada:   "Esta compra no tiene entradas para agregar.",
  pasado: "Este evento ya pasó.",
  error:  "No pudimos agregarla a Google Wallet. Probá de nuevo en un rato.",
};

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

function conTope(url, ms) {
  const ctl = new AbortController();
  const t = setTimeout(() => ctl.abort(), ms);
  return fetch(url, { signal: ctl.signal }).finally(() => clearTimeout(t));
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
    const href = `${FN}?orden=${encodeURIComponent(ordenId)}&parte=${p}`;
    html += `<div class="gwallet">` +
      (rotulo ? `<span class="gwallet-rotulo">${rotulo}</span>` : "") +
      `<a class="gwallet-btn" href="${esc(href)}" data-gwallet="${esc(ordenId)}" data-parte="${p}" rel="nofollow">` +
        `<img src="${BOTON}" alt="${esc(ALT + (rotulo ? ` (${rotulo.toLowerCase()})` : ""))}" height="48" decoding="async"></a>` +
      `<span class="gwallet-espera" role="status" hidden>Preparando tu pase…</span>` +
      `</div>`;
  }
  return html;
}

/* Lo que trae el 302 de vuelta (?wallet_aviso=…): se lee una vez y se saca
   de la barra, para que recargar no repita el cartel ni quede en el link
   que la persona copia. */
function avisoDeVuelta() {
  try {
    const u = new URL(location.href);
    const a = u.searchParams.get("wallet_aviso");
    if (!a) return "";
    u.searchParams.delete("wallet_aviso");
    history.replaceState(history.state, "", u.pathname + u.search + u.hash);
    return AVISOS[a] || "";
  } catch { return ""; }
}

/* ── el toque ── */
let ocupado = false;
function soltar() {
  ocupado = false;
  document.querySelectorAll("a[data-gwallet][aria-busy]").forEach(a => {
    a.removeAttribute("aria-busy");
    const e = a.parentElement && a.parentElement.querySelector(".gwallet-espera");
    if (e) e.hidden = true;
  });
}
document.addEventListener("click", async ev => {
  const a = ev.target.closest && ev.target.closest("a[data-gwallet]");
  if (!a) return;
  // Con un modificador (otra pestaña, otra ventana) que vaya el link: la función contesta con un 302.
  if (ev.defaultPrevented || ev.button !== 0 || ev.metaKey || ev.ctrlKey || ev.shiftKey || ev.altKey) return;
  ev.preventDefault();
  if (ocupado) return;
  ocupado = true;
  a.setAttribute("aria-busy", "true");
  const espera = a.parentElement && a.parentElement.querySelector(".gwallet-espera");
  if (espera) espera.hidden = false;
  const avisar = typeof GWallet.avisar === "function" ? GWallet.avisar : () => {};
  try {
    const r = await conTope(`${FN}?orden=${encodeURIComponent(a.dataset.gwallet)}` +
                            `&parte=${encodeURIComponent(a.dataset.parte || "1")}&formato=json`, 25000);
    const j = await r.json().catch(() => null);
    if (j && j.ok && typeof j.url === "string" && j.url.startsWith("https://pay.google.com/")) {
      location.href = j.url;
      /* Si Android abre la app de Wallet, esta página no se va y no hay
         `pageshow` que la despierte: el botón vuelve solo en unos segundos. */
      setTimeout(soltar, 4000);
      return;
    }
    avisar((j && j.motivo) || AVISOS.error);
  } catch {
    avisar(AVISOS.error);
  }
  soltar();
});
// Volver con "atrás" desde Google trae la página congelada como quedó: con el botón ocupado.
addEventListener("pageshow", soltar);

const GWallet = window.GWallet = { listo, botones, avisoDeVuelta, avisar: null };
})();
