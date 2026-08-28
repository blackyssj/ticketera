/* ══════════════════════════════════════════════════════════════════
   TICKETERA · landing pública de autoservicio
   Diseño: docs/superpowers/specs/2026-08-27-ticketera-design.md

   El flujo es el del spec: se elige, se retiene 10 minutos, se paga, y
   recién con el pago confirmado se emiten las entradas. En MODO 'demo'
   todo eso pasa en memoria; en MODO 'supabase' las mismas cuatro llamadas
   pegan contra las Edge Functions. La interfaz no distingue una de otra.
   ══════════════════════════════════════════════════════════════════ */
(() => {
"use strict";

/* `?modo=demo` fuerza el modo sin backend. Sirve para mostrar la interfaz sin
   consumir cupos reales, y para que la página siga en pie si el proyecto está
   caído. No afecta la seguridad: en ese modo no se habla con la base en
   absoluto, así que no hay nada que saltarse.

   El link público que arma la administración es `/<organizador>/<evento>`
   (rewrite a este mismo index.html en app/vercel.json). config.js queda
   solo de respaldo: para el modo demo, y para cuando la ruta no trae los
   dos segmentos (por ejemplo `/` sirviendo el evento por defecto). */
const CFG = (() => {
  const base = window.CONFIG || { MODO: "demo" };
  const forzado = new URLSearchParams(location.search).get("modo");
  const cfg = forzado === "demo" ? { ...base, MODO: "demo" } : { ...base };

  const RESERVADAS = new Set(["admin", "orden"]);
  const seg = location.pathname.split("/").filter(Boolean).map(decodeURIComponent);
  if (seg.length >= 2 && !RESERVADAS.has(seg[0])) {
    cfg.ORGANIZADOR = seg[0];
    cfg.EVENTO = seg[1];
  }
  return cfg;
})();
// En modo demo sale del archivo; en modo supabase lo trae la función `evento`
// con exactamente la misma forma, así que de acá para abajo da lo mismo.
let D = window.DATOS_DEMO;

const HOLD_SEG = 600;
/* Si `iniciar-pago` devuelve una URL, la pasarela es real y el comprador se
   va a ella. Si no, se queda en la pantalla de cobro por QR de acá. */
/* Sin paso de mesa: el comprador elige un producto, no un lugar del plano.
   La mesa física se la asigna el relacionador después de vender. Eso saca de
   la venta pública el problema más caro que tenía — dos personas peleando por
   la misma chapa mientras pagan. */
const PASOS = [
  { id:"entradas", txt:"Entradas" },
  { id:"datos",    txt:"Tus datos" },
  { id:"pago",     txt:"Pago" },
  { id:"listo",    txt:"Tu entrada" }
];

/* ── estado ────────────────────────────────────────────────────── */
const S = {
  paso: "entradas",
  cant: {},                    // tipo_id → cantidad
  comprador: { nombre:"", telefono:"", email:"" },
  orden: null,
  entradas: [],
  restan: HOLD_SEG,
  tic: null
};
/* ── utilidades ────────────────────────────────────────────────── */
const $  = s => document.querySelector(s);
const $$ = s => Array.from(document.querySelectorAll(s));
const bs = n => Number(n).toLocaleString("es-BO") + " Bs";
const esc = s => String(s ?? "").replace(/[&<>"']/g, c =>
  ({ "&":"&amp;", "<":"&lt;", ">":"&gt;", '"':"&quot;", "'":"&#39;" }[c]));

const ALFA = "23456789BCDFGHJKLMNPQRSTVWXZ";   // sin vocales ni 0/O/1/I
const nuevoCode = () => Array.from({ length: 12 },
  () => ALFA[Math.floor(Math.random() * ALFA.length)]).join("");

let tToast;
function avisar(txt) {
  const t = $("#toast");
  t.textContent = txt; t.dataset.on = "1";
  clearTimeout(tToast);
  tToast = setTimeout(() => t.dataset.on = "0", 4200);
}

const tipoDe = id => D.tipos.find(t => t.id === id);
const esperar = ms => new Promise(r => setTimeout(r, ms));

/* ══ el backend ═══════════════════════════════════════════════════
   Cuatro llamadas, las mismas que expone el Bloque 2. El adaptador de
   demo las resuelve en memoria; el de supabase invoca las Edge
   Functions. Ninguna escribe con la anon key: en producción escribe la
   función, con service_role, del lado del servidor.                */
const API = CFG.MODO === "supabase" ? apiSupabase() : apiDemo();

function apiDemo() {
  return {
    async evento() { return { ok: true, ...window.DATOS_DEMO }; },
    async crearOrden(items, comprador) {
      await esperar(220);
      const { subtotal, fee, total } = cotizar();
      return { id: crypto.randomUUID(), subtotal, fee, total,
               expira_at: Date.now() + HOLD_SEG * 1000, comprador };
    },
    async iniciarPago(orden) {
      await esperar(700);
      return { pago_ref: "SIM-" + orden.id.slice(0, 8).toUpperCase(), url: null };
    },
    async estadoOrden() {
      await esperar(900);
      return { estado: "pagada" };
    },
    async emitir(orden) {
      await esperar(400);
      const out = [];
      Object.entries(S.cant).forEach(([id, q]) => {
        const t = tipoDe(id);
        // una mesa emite una entrada por persona que entra con ella
        for (let i = 0; i < q * (t.manillas || 1); i++) {
          out.push({ code: nuevoCode(), etiqueta: t.nombre, precio: t.precio,
                     cliente: orden.comprador.nombre });
        }
      });
      return out;
    }
  };
}

function apiSupabase() {
  const sb = window.supabase.createClient(CFG.SUPABASE_URL, CFG.SUPABASE_ANON_KEY);
  const fn = async (nombre, body) => {
    const { data, error } = await sb.functions.invoke(nombre, { body });
    if (error) throw new Error(error.message || "No se pudo completar la operación.");
    if (data && data.ok === false) throw new Error(data.motivo || "Operación rechazada.");
    return data;
  };
  return {
    evento: () => fn("evento", { organizador: CFG.ORGANIZADOR, evento: CFG.EVENTO }),
    crearOrden: async (items, comprador) => {
      const r = await fn("crear-orden", { organizador: CFG.ORGANIZADOR, evento: CFG.EVENTO,
                                          items, comprador, client_key: crypto.randomUUID() });
      return { id: r.orden, subtotal: r.subtotal, fee: r.fee, total: r.total, comprador };
    },
    iniciarPago: orden => fn("iniciar-pago", { orden: orden.id }),
    // estado-orden confirma contra la pasarela y emite en el mismo viaje
    estadoOrden: orden => fn("estado-orden", { orden: orden.id }),
    emitir:      orden => fn("estado-orden", { orden: orden.id }).then(r => r.entradas || [])
  };
}

/* ══ cotización ═══════════════════════════════════════════════════
   El fee es % del subtotal + un fijo POR TRANSACCIÓN, con piso. El
   fijo existe porque el costo de la pasarela se paga una vez por
   compra, no una vez por entrada.                                   */
function cotizar() {
  let subtotal = 0, entradas = 0;
  const lineas = [];

  D.tipos.forEach(t => {
    const q = S.cant[t.id];
    if (!q) return;
    subtotal += t.precio * q; entradas += q;
    lineas.push({ q: q + "×", n: t.nombre, v: t.precio * q, quitarTipo: t.id });
  });

  const o = D.organizador;
  const fee = lineas.length
    ? Math.max(Math.round(subtotal * o.fee_pct) + o.fee_fijo, o.fee_piso) : 0;
  return { lineas, subtotal, fee, total: subtotal + fee, entradas };
}

/* ══ pintado ══════════════════════════════════════════════════════ */

function pintarHero() {
  const e = D.evento;
  $("#marca").innerHTML = `<b>${esc(e.marca_1)}</b> ${esc(e.marca_2)}`;
  $("#barraFecha").textContent = e.fecha_txt;
  $("#heroLugar").textContent = e.lugar;
  $("#heroL1").textContent = e.marca_1;
  $("#heroL2").textContent = e.marca_2;
  $("#heroBajada").textContent = e.bajada;
  $("#heroDatos").innerHTML = e.datos
    .map(([k, v]) => `<span>${esc(k)} <b>${esc(v)}</b></span>`).join("");
  document.title = `${e.marca_1} ${e.marca_2} — entradas y mesas`;
  $("#faseChip").innerHTML = `<i></i>${esc(D.fase.nombre)} · ${esc(D.fase.hasta_txt)}`;
  $("#feeNota").textContent =
    `${Math.round(D.organizador.fee_pct * 100)}% + ${D.organizador.fee_fijo} Bs por compra, ` +
    `mínimo ${D.organizador.fee_piso} Bs. Ya incluye el procesamiento del pago.`;
}

function pintarPasos() {
  const i = PASOS.findIndex(p => p.id === S.paso);
  $("#pasos").innerHTML = PASOS.map((p, k) => {
    const estado = k < i ? "hecho" : k === i ? "actual" : "pendiente";
    const tag = estado === "hecho" ? "button" : "div";
    return (k ? '<span class="paso-sep"></span>' : "") +
      `<${tag} class="paso" data-estado="${estado}"` +
      (estado === "hecho" ? ` data-ir="${p.id}" type="button"` : "") +
      `><span class="n">${k + 1}</span>${esc(p.txt)}</${tag}>`;
  }).join("");
}

/* Dos grupos, no una lista sola: una entrada y una mesa se compran distinto
   —una es una persona, la otra es un espacio para un grupo— y mezclarlas hace
   que la de 3.000 parezca una entrada carísima. */
const GRUPOS = [
  { cat: "entrada", titulo: null },
  { cat: "mesa", titulo: "Mesas y lounges",
    nota: "El lugar exacto te lo asigna el equipo el día del evento." },
];

function pintarTipos() {
  const tope = D.evento.tope_entradas_orden;
  const usadas = Object.values(S.cant).reduce((a, b) => a + b, 0);

  $("#tipos").innerHTML = GRUPOS.map(g => {
    const suyos = D.tipos.filter(t => (t.categoria || "entrada") === g.cat);
    if (!suyos.length) return "";
    return (g.titulo
        ? `<div class="grupo-cab"><h3>${esc(g.titulo)}</h3>` +
          (g.nota ? `<p>${esc(g.nota)}</p>` : "") + `</div>`
        : "") +
      suyos.map(t => tarjetaTipo(t, tope, usadas)).join("");
  }).join("");

  if (usadas >= tope) {
    $("#tipos").insertAdjacentHTML("beforeend",
      `<p class="letra-chica">Máximo ${tope} por compra. Para más, hacé otra compra.</p>`);
  }
}

function tarjetaTipo(t, tope, usadas) {
  const q = S.cant[t.id];
  const esMesa = (t.categoria || "entrada") === "mesa";
  const cls = t.cupo === 0 ? "agotado" : t.cupo <= 20 ? "poco" : "";
  const txtCupo = t.cupo === 0 ? "Agotado"
    : t.cupo <= 20 ? `Quedan ${t.cupo}` : `${t.cupo} disponibles`;
  const topeMas = q >= t.cupo || usadas >= tope;

  return `<article class="tipo${esMesa ? " es-mesa" : ""}" data-activo="${q ? 1 : 0}">
    <h3 class="tipo-nombre">${esc(t.nombre)}</h3>
    <p class="tipo-desc">${esc(t.desc)}</p>
    ${t.incluye ? `<p class="tipo-incluye"><b>Incluye</b> ${esc(t.incluye)}</p>` : ""}
    <p class="tipo-cupo ${cls}">${txtCupo}${
      esMesa && t.manillas > 1 ? ` · entran ${t.manillas}` : ""}</p>
    <div class="tipo-der">
      <span class="tipo-precio">${bs(t.precio)}${t.antes ? `<s>antes ${t.antes} Bs</s>` : ""}</span>
      <div class="stepper">
        <button type="button" data-paso-t="-1" data-tipo="${t.id}"
          aria-label="Quitar ${esc(t.nombre)}"${q === 0 ? " disabled" : ""}>−</button>
        <output>${q}</output>
        <button type="button" data-paso-t="1" data-tipo="${t.id}"
          aria-label="Agregar ${esc(t.nombre)}"${topeMas ? " disabled" : ""}>+</button>
      </div>
    </div>
  </article>`;
}

function pintarRail() {
  const { lineas, subtotal, fee, total, entradas } = cotizar();
  const hay = lineas.length > 0;

  $("#railLineas").innerHTML = hay
    ? lineas.map(l =>
        `<div class="rlinea"><span class="q">${l.q}</span>` +
        `<span class="n">${esc(l.n)}</span>` +
        (l.quitarMesa ? `<button class="x" data-quitar-mesa="${l.quitarMesa}" aria-label="Quitar ${esc(l.n)}">×</button>` : "") +
        (l.quitarTipo ? `<button class="x" data-quitar-tipo="${l.quitarTipo}" aria-label="Quitar ${esc(l.n)}">×</button>` : "") +
        `<span class="v">${bs(l.v)}</span></div>`).join("")
    : `<p class="rail-vacio">Todavía no elegiste nada.</p>`;

  $("#railTotales").hidden = !hay;
  $("#vSubtotal").textContent = bs(subtotal);
  $("#vFee").textContent = bs(fee);
  $("#vTotal").textContent = bs(total);
  $("#railTotalChico").textContent = bs(total);

  const partes = [];
  const mesas = D.tipos.filter(t => t.categoria === "mesa")
                       .reduce((a, t) => a + (S.cant[t.id] || 0), 0);
  const sueltas = entradas - mesas;
  if (sueltas) partes.push(sueltas + (sueltas === 1 ? " entrada" : " entradas"));
  if (mesas) partes.push(mesas + (mesas === 1 ? " mesa" : " mesas"));
  $("#railResumen").textContent = hay ? partes.join(" · ") : "Elegí tus entradas";

  // el botón cambia de nombre y de habilitación según el paso
  const b = $("#btnSeguir"), atras = $("#btnAtras");
  const cfg = {
    entradas: { txt: "Seguir",     on: hay,               atras: false },
    datos:    { txt: "Ir a pagar", on: formValido(false), atras: true  },
    pago:     { txt: "Procesando…",   on: false,        atras: false },
    listo:    { txt: "Listo",         on: false,        atras: false }
  }[S.paso];
  b.textContent = cfg.txt;
  b.disabled = !cfg.on;
  b.hidden = S.paso === "listo" || S.paso === "pago";
  atras.hidden = !cfg.atras;

  $("#railAviso").textContent = "";
  if (hay) arrancarReloj(); else pararReloj();
}

/* ── el hold ─────────────────────────────────────────────────────
   Diez minutos, y al vencer suelta TODO: mesas y entradas. Es lo que
   hace el barrido del lado del servidor; acá se ve.               */
function arrancarReloj() {
  if (S.tic || S.paso === "listo") return;
  S.restan = HOLD_SEG;
  $$(".reloj").forEach(r => r.hidden = false);
  dibujarReloj();
  S.tic = setInterval(() => { S.restan--; dibujarReloj(); if (S.restan <= 0) vencer(); }, 1000);
}
function pararReloj() {
  clearInterval(S.tic); S.tic = null;
  $$(".reloj").forEach(r => { r.hidden = true; r.classList.remove("urgente"); });
}
function dibujarReloj() {
  const m = Math.floor(S.restan / 60), s = S.restan % 60;
  const txt = `${m}:${String(s).padStart(2, "0")}`;
  $$(".relojTxt").forEach(e => e.textContent = txt);
  $$(".reloj").forEach(r => r.classList.toggle("urgente", S.restan <= 60));
}
function vencer() {
  pararReloj();
  D.tipos.forEach(t => S.cant[t.id] = 0);
  S.orden = null;
  irA("entradas");
  avisar("Se venció la reserva. Las mesas volvieron a estar libres para el resto.");
}

/* ── navegación ──────────────────────────────────────────────── */
function irA(paso) {
  // La dirección hace que la transición signifique algo: adelante entra por
  // la derecha, volver entra por la izquierda. Sin eso son todas iguales y
  // el movimiento es decoración.
  const antes = PASOS.findIndex(p => p.id === S.paso);
  const ahora = PASOS.findIndex(p => p.id === paso);
  $(".cuerpo").dataset.dir = ahora < antes ? "atras" : "adelante";
  S.paso = paso;
  $$(".panel").forEach(p => p.hidden = p.dataset.paso !== paso);
  // comprada la entrada no queda nada que decidir: el rail se va y le deja
  // la pantalla a los tickets
  $("#rail").hidden = paso === "listo";
  document.body.classList.toggle("sin-rail", paso === "listo");
  $("#hero").classList.toggle("compacto", paso !== "entradas");
  pintarPasos();
  if (paso === "entradas") pintarTipos();
  pintarRail();
  const y = $("#pasos").getBoundingClientRect().top + window.scrollY - 70;
  // left explícito: sin él la página se queda donde estaba de costado
  window.scrollTo({ top: Math.max(y, 0), left: 0 });
}

/* ── formulario ─────────────────────────────────────────────────
   Se valida al salir del campo y al intentar avanzar, nunca mientras
   se escribe: corregir a alguien en medio de una palabra es hostil. */
const REGLAS = {
  fNombre: { e:"#eNombre", k:"nombre",
    ok: v => v.trim().length >= 3 && v.trim().includes(" "),
    msg:"Poné nombre y apellido." },
  fTel: { e:"#eTel", k:"telefono",
    ok: v => /^\d{7,8}$/.test(v.replace(/\D/g, "")),
    msg:"7 u 8 dígitos, sin código de país." },
  fMail: { e:"#eMail", k:"email",
    ok: v => /^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/.test(v.trim()),
    msg:"Revisá el correo: ahí te llega el QR." }
};
function formValido(mostrar) {
  let ok = true;
  for (const [id, r] of Object.entries(REGLAS)) {
    const el = $("#" + id);
    if (!el) return false;
    const bien = r.ok(el.value);
    if (!bien) ok = false;
    if (mostrar) {
      el.setAttribute("aria-invalid", String(!bien));
      $(r.e).textContent = bien ? "" : r.msg;
    }
    if (bien) S.comprador[r.k] = el.value.trim();
  }
  return ok;
}

/* ── pago ────────────────────────────────────────────────────────
   Tres pantallas porque son tres cosas distintas que pueden fallar:
   crear la orden, iniciar el cobro y confirmarlo. Si se muestran como
   una sola, un error no dice en cuál de las tres se cayó.          */
function pagoDice(html) { $("#pagoEstado").innerHTML = html; }

async function pagar() {
  irA("pago");
  try {
    pagoDice(`<div class="girador"></div><h3>Reservando tu lugar</h3>
      <p>Guardamos lo que elegiste por 10 minutos mientras pagás.</p>`);
    const items = [];
    Object.entries(S.cant).forEach(([id, q]) => { if (q) items.push({ tipo_id: id, cantidad: q }); });
      S.orden = await API.crearOrden(items, { ...S.comprador });

    pagoDice(`<div class="girador"></div><h3>Abriendo la pasarela</h3>
      <p>Un segundo.</p>`);
    const r = await API.iniciarPago(S.orden);
    S.orden.pago_ref = r.pago_ref;
    if (r.url) { location.href = r.url; return; }   // pasarela real: se va y vuelve
    pasarelaSimulada();
  } catch (err) {
    pagoFallo(err.message, "datos");
  }
}

/* La pasarela simulada. En producción esta pantalla no existe: el comprador
   se va a v2pro y vuelve. Acá se queda, y "Verificar pago" hace lo mismo que
   hace el retorno real — preguntarle a la pasarela, no creerle al navegador. */
function pasarelaSimulada() {
  const { total } = cotizar();
  pagoDice(`
    <div class="pasarela">
      <div class="pasarela-cab">
        <span class="pasarela-marca">BeePay</span>
      </div>
      <p class="pasarela-monto">${bs(total)}</p>
      <p class="pasarela-a">a ${esc(D.organizador.nombre)}</p>
      <p class="pasarela-instruccion">Escaneá con la app de tu banco</p>
      <div class="pasarela-qr" id="pasarelaQr"></div>
      <p class="pasarela-ref">Referencia ${esc(S.orden.pago_ref || "—")}</p>
    </div>
    <button class="btn primario" id="btnVerificar">Verificar pago</button>
    <p class="letra-chica">Apretá cuando hayas pagado.</p>`);

  dibujarQrPasarela();
  $("#btnVerificar").onclick = verificarPago;
}

/* Un QR de mentira sería peor que ninguno: este lleva la referencia real de
   la orden, así que escanearlo muestra exactamente lo que se está pagando. */
function dibujarQrPasarela() {
  const caja = $("#pasarelaQr");
  if (!caja || typeof qrcode !== "function") return;
  const q = qrcode(0, "M");
  q.addData(`BEEPAY:${S.orden.pago_ref}:${cotizar().total}`);
  q.make();

  // Canvas y no createSvgTag: el SVG que genera la librería sale con los
  // módulos en blanco sobre fondo blanco. El canvas es el mismo camino que
  // ya usa el ticket y se controla el color.
  const n = q.getModuleCount(), celda = 6, pad = celda * 2;
  const lado = n * celda + pad * 2;
  const c = document.createElement("canvas");
  c.width = c.height = lado;
  c.style.width = c.style.height = "170px";
  const x = c.getContext("2d");
  x.fillStyle = "#fff"; x.fillRect(0, 0, lado, lado);
  x.fillStyle = "#171310";
  for (let r = 0; r < n; r++)
    for (let k = 0; k < n; k++)
      if (q.isDark(r, k)) x.fillRect(pad + k * celda, pad + r * celda, celda, celda);
  caja.replaceChildren(c);
}

async function verificarPago() {
  const btn = $("#btnVerificar");
  if (btn) { btn.disabled = true; btn.textContent = "Consultando…"; }
  try {
    const r = await API.estadoOrden(S.orden);
    if (r.estado === "revision_manual") {
      pagoFallo("El monto cobrado no coincide con la compra. Lo estamos revisando.", null);
      return;
    }
    if (r.estado !== "pagada") {
      pagoDice(`<h3>Todavía no figura pagado</h3>
        <p>La pasarela dice que la orden sigue <b>${esc(r.estado)}</b>. Si ya pagaste,
           esperá unos segundos y volvé a verificar.</p>
        <button class="btn primario" id="btnVerificar">Verificar de nuevo</button>`);
      $("#btnVerificar").onclick = verificarPago;
      return;
    }
    S.entradas = r.entradas && r.entradas.length ? r.entradas : await API.emitir(S.orden);
    await mostrarListo();
  } catch (err) {
    pagoFallo(err.message, null);
  }
}

/* Un solo lugar donde se dibuja un fallo, para que digan todos lo mismo. */
function pagoFallo(motivo, volverA) {
  pagoDice(`<h3>No se pudo completar</h3><p>${esc(motivo)}</p>
    <button class="btn plano" id="btnReintentar">${volverA ? "Volver a intentar" : "Verificar de nuevo"}</button>`);
  $("#btnReintentar").onclick = volverA ? () => irA(volverA) : verificarPago;
}

/* ── el ticket ───────────────────────────────────────────────────
   Se dibuja en canvas del lado del cliente: cero egress de imágenes.
   El payload del QR es el mismo de Bowie y BurTown, EVT:<evento>:<code>,
   así que el escáner de la puerta lo lee sin cambiarle una línea.   */
const dibujarTicket = (t) => window.dibujarTicket(t, D.evento, D.fase);

async function mostrarListo() {
  irA("listo");
  pararReloj();
  $("#listoNota").textContent =
    `${S.entradas.length} ${S.entradas.length === 1 ? "entrada" : "entradas"} a nombre de ${S.comprador.nombre}.`;

  // Este link es el único camino de vuelta si se cierra la pestaña sin
  // descargar: por eso se muestra siempre, no solo cuando el correo falla.
  const linkOrden = `${location.origin}/orden/?id=${S.orden.id}`;
  $("#listoLink").textContent = linkOrden;
  $("#btnCopiarLink").onclick = async () => {
    try {
      await navigator.clipboard.writeText(linkOrden);
      avisar("Link copiado.");
    } catch (err) {
      avisar("No se pudo copiar: " + err.message);
    }
  };

  // El correo depende de si RESEND_API_KEY está configurada de verdad
  // (D.correo_configurado, que manda la función `evento`). Si no lo está,
  // ningún correo sale nunca — prometerlo ahí sería mentir.
  const correoOk = D.correo_configurado !== false;
  $("#listoRef").textContent =
    `Orden ${S.orden.id}${S.orden.pago_ref ? " · pago " + S.orden.pago_ref : ""}.` +
    (correoOk ? ` También te las mandamos a ${S.comprador.email}.` : "");
  $("#tickets").innerHTML = `<p class="rail-vacio">Dibujando tus entradas…</p>`;

  if (document.fonts && document.fonts.ready) await document.fonts.ready;
  const pngs = [];
  for (const t of S.entradas) pngs.push(await dibujarTicket(t));
  S.entradas.forEach((t, i) => t.png = pngs[i]);

  // Escalonadas: la primera aparece sola y el resto la siguen. Todas juntas
  // se leen como un bloque; de a una se lee como "estas son tuyas".
  $("#tickets").innerHTML = S.entradas.map((t, i) =>
    `<img style="--i:${Math.min(i, 8)}" src="${t.png}"
          alt="Entrada ${esc(t.etiqueta)}, código ${esc(t.code)}"
          loading="${i < 2 ? "eager" : "lazy"}">`
  ).join("");
}

function descargar() {
  S.entradas.forEach((t, i) => {
    const a = document.createElement("a");
    a.href = t.png;
    a.download = `entrada-${i + 1}-${t.code}.png`;
    document.body.appendChild(a); a.click(); a.remove();
  });
  avisar(`${S.entradas.length} ${S.entradas.length === 1 ? "entrada descargada" : "entradas descargadas"}.`);
}

/* ══ eventos ══════════════════════════════════════════════════════ */

$("#tipos").addEventListener("click", e => {
  const b = e.target.closest("button[data-paso-t]");
  if (!b) return;
  const t = tipoDe(b.dataset.tipo);
  const nueva = S.cant[t.id] + Number(b.dataset.pasoT);
  const usadas = Object.values(S.cant).reduce((a, x) => a + x, 0);
  if (nueva < 0 || nueva > t.cupo) return;
  if (Number(b.dataset.pasoT) > 0 && usadas >= D.evento.tope_entradas_orden) {
    avisar(`Máximo ${D.evento.tope_entradas_orden} entradas por compra.`);
    return;
  }
  S.cant[t.id] = nueva;
  pintarTipos(); pintarRail();
});

$("#railLineas").addEventListener("click", e => {
  const t = e.target.closest("[data-quitar-tipo]");
  if (!t) return;
  S.cant[t.dataset.quitarTipo] = 0;
  pintarTipos(); pintarRail();
});

$("#pasos").addEventListener("click", e => {
  const b = e.target.closest("[data-ir]");
  if (b && S.paso !== "pago" && S.paso !== "listo") irA(b.dataset.ir);
});

$("#btnSeguir").addEventListener("click", () => {
  if (S.paso === "entradas") return irA("datos");
  if (S.paso === "datos") {
    if (!formValido(true)) { avisar("Revisá los datos marcados."); return; }
    return pagar();
  }
});
$("#btnAtras").addEventListener("click", () => {
  if (S.paso === "datos") return irA("entradas");
});

Object.keys(REGLAS).forEach(id => {
  const el = $("#" + id);
  el.addEventListener("blur", () => { formValido(true); pintarRail(); });
  el.addEventListener("input", () => {
    if (el.getAttribute("aria-invalid") === "true") formValido(true);
    pintarRail();
  });
});
$("#form").addEventListener("submit", e => e.preventDefault());

$("#railTirador").addEventListener("click", () => {
  const r = $("#rail");
  const abierto = r.dataset.abierto === "1";
  r.dataset.abierto = abierto ? "0" : "1";
  $("#railTirador").setAttribute("aria-expanded", String(!abierto));
});

$("#btnDescargar").addEventListener("click", descargar);
$("#btnOtra").addEventListener("click", () => {
  D.tipos.forEach(t => S.cant[t.id] = 0);
  S.orden = null; S.entradas = [];
  pintarTipos(); irA("entradas");
});

/* ══ arranque ══ */
async function arrancar() {
  if (CFG.MODO === "supabase") {
    $("#tipos").innerHTML = `<p class="rail-vacio">Cargando el evento…</p>`;
    try {
      const r = await API.evento();
      if (!r.ok) throw new Error(r.motivo || "No se pudo cargar el evento.");
      D = r;
    } catch (err) {
      $("#tipos").innerHTML =
        `<article class="tipo"><h3 class="tipo-nombre">No se pudo cargar</h3>` +
        `<p class="tipo-desc">${esc(err.message)}</p></article>`;
      return;
    }
  }
  D.tipos.forEach(t => S.cant[t.id] = 0);
  pintarHero();
  pintarTipos();
  irA("entradas");
}
arrancar();
})();
