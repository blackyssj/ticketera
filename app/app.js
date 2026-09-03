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
   (rewrite a evento.html en app/vercel.json), y esa ruta es la ÚNICA fuente
   del evento: config.js ya no trae un organizador por defecto. Lo traía
   cuando `/` servía este archivo; ahora `/` es la portada de TICKETAZO y un
   default acá haría que una ruta rota vendiera el evento de otro cliente en
   vez de fallar. Sin los dos segmentos, `evento` responde que falta el
   organizador y la página lo dice — que es lo que corresponde. */
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

/* La atribución del relacionador. Se guarda al entrar y se arrastra hasta el
   checkout: el comprador puede mirar, irse y volver sin el ?r=, y la venta
   sigue siendo de quien le pasó el link.
   sessionStorage y no localStorage a propósito: dura la visita, no para
   siempre — si el mismo teléfono compra un mes después por otro lado, ya no
   es de él. */
const REL = (() => {
  const key = "ticketera.r";
  const url = new URLSearchParams(location.search).get("r");
  try {
    if (url) sessionStorage.setItem(key, url);
    return sessionStorage.getItem(key) || null;
  } catch { return url || null; }   // navegador con storage bloqueado
})();

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

/* Si lo único a la venta son mesas, la página deja de hablar de "entradas".
   No es cosmético: quien compra un combo no compra una entrada, reserva una
   mesa que trae manillas, y llamar igual a las dos cosas es lo que hace que
   después pregunte por WhatsApp cuántas personas entran. Se deriva de lo que
   hay en venta y no de una constante: el día que el organizador vuelva a
   activar entradas sueltas, el vocabulario vuelve solo. */
let VOCAB = { plural: "entradas", singular: "entrada", elegi: "Elegí tus entradas" };

function fijarVocabulario() {
  const soloMesas = D.tipos.length > 0 && D.tipos.every(t => t.categoria === "mesa");
  const hayMesas = D.tipos.some(t => t.categoria === "mesa");
  VOCAB = soloMesas
    ? { plural: "reservas", singular: "reserva", elegi: "Elegí tu reserva",
        titulo: "reservas" }
    : { plural: "entradas", singular: "entrada", elegi: "Elegí tus entradas",
        titulo: hayMesas ? "entradas y mesas" : "entradas" };
  PASOS[0].txt = soloMesas ? "Reservas"   : "Entradas";
  PASOS[3].txt = soloMesas ? "Tu reserva" : "Tu entrada";
  const h2 = $('[data-paso="entradas"] .panel-cab h2');
  if (h2) h2.textContent = PASOS[0].txt;
  const gm = GRUPOS.find(g => g.cat === "mesa");
  if (gm) gm.titulo = soloMesas ? null : "Mesas y lounges";
  $("#railResumen").textContent = VOCAB.elegi;
}

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
const linkDeOrden = () => `${location.origin}/orden/?id=${S.orden.id}`;

/* 9999 es como la función `evento` dice "este tipo no tiene tope" (cupo nulo
   en la base). Pintarlo tal cual dejaba "9999 disponibles" en la tarjeta, que
   no es un dato: es un número de relleno con cara de dato. */
const SIN_TOPE = 9999;

/* Gratis de verdad. No alcanza con que las entradas valgan cero: el fijo por
   transacción y el piso del organizador también tienen que estar en cero,
   porque si no el carrito suma algo y ese algo hay que cobrarlo. Decir
   "gratis" ahí sería la mentira al revés de decir "pagá" cuando no hay nada
   que pagar. */
function eventoGratis() {
  const o = D.organizador || {};
  return D.tipos.length > 0 && D.tipos.every(t => Number(t.precio) === 0)
      && !Number(o.fee_fijo) && !Number(o.fee_piso);
}

/* ── cuándo es el evento ──────────────────────────────────────────
   La fecha en ISO no viaja: la función `evento` arma `fecha_txt` ("SÁB 12 SEP
   · 21:00") y manda sólo eso. El .ics y lo que se guarda en el dispositivo
   necesitan una fecha de verdad, así que se reconstruye de ese texto. El año
   no está escrito, y no se adivina a ciegas: se prueban éste y el que viene, y
   gana el que caiga en el día de semana que el propio texto declara. Si
   ninguno coincide, el que no esté en el pasado. Si nada de eso cierra,
   devuelve null y el botón de calendario no aparece — meterle a alguien una
   fecha equivocada en su agenda es peor que no darle el botón. */
const MES_TXT = ["ENE","FEB","MAR","ABR","MAY","JUN","JUL","AGO","SEP","OCT","NOV","DIC"];
const DIA_TXT = ["DOM","LUN","MAR","MIÉ","JUE","VIE","SÁB"];
/* Bolivia no mueve el reloj en todo el año: -04:00 fijo. Por eso el día se lee
   corriendo cuatro horas atrás y mirando el UTC, y no con getDay()/getDate(),
   que contestan según el reloj del que está mirando la página: a las 21:00 de
   Santa Cruz, en Madrid ya es el día siguiente. */
const enBolivia = d => new Date(d.getTime() - 4 * 3600e3);

function fechaEvento() {
  const e = D.evento || {};
  // Si algún día la función manda la fecha en crudo, esa manda y no se adivina.
  if (e.fecha) {
    const d = new Date(`${e.fecha}T${String(e.hora_inicio || "21:00").slice(0, 5)}:00-04:00`);
    if (!isNaN(d.getTime())) return d;
  }
  const txt = String(e.fecha_txt || "").toUpperCase();
  const md = txt.match(/(\d{1,2})\s+([A-ZÁÉÍÓÚÑ]{3})/);
  const mes = md ? MES_TXT.indexOf(md[2]) : -1;
  if (mes < 0) return null;
  const hm = txt.match(/(\d{1,2}):(\d{2})/);
  const semana = (txt.match(/^([A-ZÁÉÍÓÚÑ]{3})/) || [])[1];
  const p2 = n => String(n).padStart(2, "0");
  const anio = new Date().getFullYear();
  const dia = Number(md[1]);
  const cand = [0, 1]
    .map(n => new Date(`${anio + n}-${p2(mes + 1)}-${p2(dia)}` +
                       `T${hm ? p2(hm[1]) : "21"}:${hm ? hm[2] : "00"}:00-04:00`))
    /* Un 31 de abril no explota: el navegador lo corre al 1 de mayo y no dice
       nada. Si el día que vuelve no es el que se pidió, esa fecha no existía y
       se descarta — de lo contrario el .ics saldría con el día corrido. */
    .filter(d => !isNaN(d.getTime()) && enBolivia(d).getUTCDate() === dia);
  /* Primero las que todavía no pasaron: esta página vende un evento futuro, y
     la del año pasado nunca es la respuesta. Recién entre ésas manda el día de
     semana que declara el propio texto; si ninguna coincide, la más cercana.
     El día de gracia es para el evento que empieza esta noche. */
  const futuras = cand.filter(d => d.getTime() > Date.now() - 864e5);
  return futuras.find(d => DIA_TXT[enBolivia(d).getUTCDay()] === semana) || futuras[0] || null;
}

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
      return { id: crypto.randomUUID(), subtotal, fee, total, gratis: total === 0,
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
                                          items, comprador, r: REL,
                                          client_key: crypto.randomUUID() });
      return { id: r.orden, subtotal: r.subtotal, fee: r.fee, total: r.total,
               gratis: r.gratis === true, comprador };
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
  /* El dato "Pago · Con QR" lo manda la función para todo evento, gratis
     incluido. Ahí arriba, en el afiche, es lo primero que lee el invitado a
     algo que no cobra: un cobro anunciado que después no aparece por ningún
     lado. Se cae solo cuando no hay nada que cobrar. */
  const datos = eventoGratis()
    ? e.datos.filter(([k]) => String(k).toLowerCase() !== "pago")
    : e.datos;
  $("#heroDatos").innerHTML = datos
    .map(([k, v]) => `<span>${esc(k)} <b>${esc(v)}</b></span>`).join("");
  document.title = `${e.marca_1} ${e.marca_2} — ${VOCAB.titulo}`;
  $("#faseChip").innerHTML = `<i></i>${esc(D.fase.nombre)} · ${esc(D.fase.hasta_txt)}`;
  /* La nota se arma con las partes que el organizador realmente cobra. Con
     el fijo y el piso en cero, "8% + 0 Bs por compra, mínimo 0 Bs" es la
     misma frase de siempre diciendo nada dos veces, y una letra chica que
     enumera ceros es la que el comprador deja de leer. */
  const o = D.organizador, notaFee = [`${Math.round(o.fee_pct * 100)}% de servicio`];
  if (o.fee_fijo > 0) notaFee.push(`+ ${o.fee_fijo} Bs por compra`);
  if (o.fee_piso > 0) notaFee.push(`mínimo ${o.fee_piso} Bs`);
  $("#feeNota").textContent =
    notaFee.join(", ") + ". Ya incluye el procesamiento del pago.";
}

/* ── cuánto le queda a la fase ────────────────────────────────────
   La única urgencia que se muestra es la que existe: si la fase no trae
   fecha de cierre (`hasta`), acá no aparece nada. Un cartel que apura sin
   tener de qué es el negocio de otros, y además se nota — el que vuelve
   mañana ve el mismo "últimas horas" y ya no cree ninguno.
   Tampoco es una cuenta regresiva al segundo: un número latiendo al lado del
   precio apura, no informa, y se pelea con el reloj del hold, que ese sí
   cuenta algo que se vence de verdad. Se escribe una vez, al cargar.        */
function pintarCierre() {
  const el = $("#faseCierre");
  const hasta = D.fase && D.fase.hasta ? new Date(D.fase.hasta) : null;
  const falta = hasta && !isNaN(hasta.getTime()) ? hasta.getTime() - Date.now() : 0;
  if (falta <= 0) { el.hidden = true; return; }
  const nombre = String(D.fase.nombre || "").trim();
  el.textContent = `${nombre ? "La " + nombre.toLowerCase() : "La venta"} cierra en ${cuantoFalta(falta)}`;
  // Bajo las 24 horas "cierra mañana" pasa a ser "cierra hoy", y ahí sí
  // corresponde el acento del evento.
  el.dataset.urgente = falta <= 24 * 3600e3 ? "1" : "0";
  el.hidden = false;
}

// Redondea siempre para abajo: prometer un día entero cuando quedan trece
// horas es la clase de exageración que después se cobra en la puerta.
function cuantoFalta(ms) {
  const h = Math.floor(ms / 3600e3);
  if (h < 1) {
    const m = Math.max(1, Math.floor(ms / 60e3));
    return `${m} ${m === 1 ? "minuto" : "minutos"}`;
  }
  if (h < 24) return `${h} ${h === 1 ? "hora" : "horas"}`;
  const d = Math.floor(h / 24);
  return `${d} ${d === 1 ? "día" : "días"}`;
}

/* El nombre de cada paso va en su propio span porque en un teléfono no entran
   los cuatro: ahí queda visible el del paso actual y los otros se leen por el
   número. El span sigue en el DOM —escondido a la vista, no borrado— así que
   el lector de pantalla los sigue nombrando. */
function pintarPasos() {
  const i = PASOS.findIndex(p => p.id === S.paso);
  $("#pasos").innerHTML = PASOS.map((p, k) => {
    const estado = k < i ? "hecho" : k === i ? "actual" : "pendiente";
    const tag = estado === "hecho" ? "button" : "div";
    return (k ? '<span class="paso-sep"></span>' : "") +
      `<${tag} class="paso" data-estado="${estado}"` +
      (estado === "actual" ? ' aria-current="step"' : "") +
      (estado === "hecho" ? ` data-ir="${p.id}" type="button"` : "") +
      `><span class="n">${k + 1}</span><span class="t">${esc(p.txt)}</span></${tag}>`;
  }).join("");
  marcarDesborde();
}

/* Con vocabularios largos ("Reservas", "Tu reserva") el rail puede seguir sin
   entrar. Antes se cortaba en seco contra el borde y no había nada que dijera
   que seguía: se degradaba a un scroll invisible. El degradado de la derecha
   es esa señal, y se apaga al llegar al final para no teñir el último paso. */
function marcarDesborde() {
  const r = $("#pasos");
  const falta = r.scrollWidth - r.clientWidth - r.scrollLeft > 1;
  r.dataset.mas = falta ? "1" : "0";
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
    // El título del grupo se calla cuando no separa nada — con mesas y nada
    // más, "Mesas y lounges" repite el encabezado del panel. La nota queda:
    // esa sí dice algo que el comprador no sabe.
    return ((g.titulo || g.nota)
        ? `<div class="grupo-cab">` +
          (g.titulo ? `<h3>${esc(g.titulo)}</h3>` : "") +
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
  const topeMas = q >= t.cupo || usadas >= tope;

  /* El renglón del cupo dice el número real o no dice nada. Sin tope en la
     base llegaba el 9999 de la función y la tarjeta anunciaba "9999
     disponibles": un número que nadie escribió y que además delata que no
     hay cuenta. Y cuando quedan pocas, el número es el argumento — "quedan
     6" vende, "últimas unidades" no. */
  const sinTope = t.cupo >= SIN_TOPE;
  const cls = t.cupo === 0 ? "agotado" : (!sinTope && t.cupo <= 20) ? "poco" : "";
  const partes = [];
  if (t.cupo === 0) partes.push("Agotado");
  else if (!sinTope) partes.push(t.cupo <= 20 ? `Quedan ${t.cupo}` : `${t.cupo} disponibles`);
  if (esMesa && t.manillas > 1) partes.push(`entran ${t.manillas}`);
  const txtCupo = partes.join(" · ");

  return `<article class="tipo${esMesa ? " es-mesa" : ""}" data-activo="${q ? 1 : 0}">
    <h3 class="tipo-nombre">${esc(t.nombre)}</h3>
    <p class="tipo-desc">${esc(t.desc)}</p>
    ${t.incluye ? `<p class="tipo-incluye"><b>Incluye</b> ${esc(t.incluye)}</p>` : ""}
    ${txtCupo ? `<p class="tipo-cupo ${cls}">${esc(txtCupo)}</p>` : ""}
    <div class="tipo-der">
      <span class="tipo-precio">${
        // "0 Bs" es un precio y esto no tiene precio. Además el resumen ya dice
        // Gratis: dos palabras distintas para lo mismo en la misma pantalla.
        Number(t.precio) === 0 ? "Gratis" : bs(t.precio)
      }${t.antes ? `<s>antes ${t.antes} Bs</s>` : ""}</span>
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

  /* Con todo en cero, "Subtotal 0 Bs" y "Servicio 0 Bs" son dos renglones que
     el invitado a un evento gratis tiene que descartar solo, y la nota del fee
     abajo le explica el procesamiento de un pago que no existe. Queda el
     total, y el total dice Gratis: es la única palabra que hace falta. */
  const gratis = hay && total === 0;
  $("#railTotales").hidden = !hay;
  $("#vSubtotal").closest("div").hidden = gratis;
  $("#vFee").closest("div").hidden = gratis;
  $("#feeNota").hidden = gratis;
  $("#vSubtotal").textContent = bs(subtotal);
  $("#vFee").textContent = bs(fee);
  $("#vTotal").textContent = gratis ? "Gratis" : bs(total);
  $("#railTotalChico").textContent = gratis ? "Gratis" : bs(total);

  /* El rótulo del tercer paso sale de lo que suma el carrito y no de una
     constante: si no hay nada que cobrar, no hay un paso de pago que
     anunciar. Se repinta el rail sólo cuando cambió, que es la única forma de
     que el cartel no quede un paso atrasado respecto del carrito. */
  // Con algo en el carrito manda el carrito; con el carrito vacío manda el
  // evento, que ya se sabe si cobra o no. Si no, el invitado a un evento
  // gratis lee "3 · Pago" desde que entra y antes de elegir nada.
  const rotulo = (hay ? total === 0 : eventoGratis()) ? "Confirmación" : "Pago";
  if (PASOS[2].txt !== rotulo) { PASOS[2].txt = rotulo; pintarPasos(); }

  const partes = [];
  const mesas = D.tipos.filter(t => t.categoria === "mesa")
                       .reduce((a, t) => a + (S.cant[t.id] || 0), 0);
  const sueltas = entradas - mesas;
  if (sueltas) partes.push(sueltas + (sueltas === 1 ? " entrada" : " entradas"));
  if (mesas) partes.push(mesas + (mesas === 1 ? " mesa" : " mesas"));
  $("#railResumen").textContent = hay ? partes.join(" · ") : VOCAB.elegi;

  // el botón cambia de nombre y de habilitación según el paso
  const b = $("#btnSeguir"), atras = $("#btnAtras");
  const cfg = {
    entradas: { txt: "Seguir",     on: hay,               atras: false },
    // Sin nada que cobrar, "Ir a pagar" es una mentira que asusta: el que
    // viene a un evento gratis lee "pagar" y cierra la pestaña.
    datos:    { txt: total === 0 ? "Confirmar mi lugar" : "Ir a pagar",
                on: formValido(false), atras: true  },
    pago:     { txt: "Procesando…",   on: false,        atras: false },
    listo:    { txt: "Listo",         on: false,        atras: false }
  }[S.paso];
  b.textContent = cfg.txt;
  b.disabled = !cfg.on;
  b.hidden = S.paso === "listo" || S.paso === "pago";
  atras.hidden = !cfg.atras;

  $("#railAviso").textContent = "";
  if (hay) arrancarReloj(); else pararReloj();
  medirBarra();
}

/* En el teléfono el resumen es una barra fija abajo, y el contenido tenía
   reservados 96px a mano. La barra mide 149 y cambia sola —el botón "Volver"
   aparece en el paso de datos, el aviso puede ocupar dos líneas, el iPhone
   suma su franja segura—, así que el número escrito a mano siempre iba a
   quedar corto: la última entrada de la lista terminaba debajo de la barra.
   Se mide lo que tapa de verdad y se publica en --alto-barra.

   Solo el tirador y el pie, no el rail entero: cuando el resumen está
   desplegado es una hoja que el comprador abrió a propósito, y reservarle
   media pantalla al contenido de abajo no tendría sentido. */
function medirBarra() {
  const r = $("#rail");
  const fija = r && !r.hidden && getComputedStyle(r).position === "fixed";
  const alto = fija
    ? $("#railTirador").offsetHeight + $(".rail-pie").offsetHeight : 0;
  document.documentElement.style.setProperty("--alto-barra", alto + "px");
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
  /* En un evento gratis el tercer paso no es un pago: llamarlo así deja al
     invitado esperando un cobro que no existe. El rótulo del rail lo pone
     pintarRail; el h2 del panel estaba escrito a mano en el HTML y no lo
     tocaba nadie, así que la pantalla decía "PAGO" en 44px con el rail
     diciendo "Confirmación" dos centímetros más arriba. */
  const gratis = cotizar().total === 0;
  $('[data-paso="pago"] .panel-cab h2').textContent = gratis ? "Confirmación" : "Pago";
  irA("pago");
  try {
    pagoDice(`<div class="girador"></div><h3>Reservando tu lugar</h3>
      <p>${gratis ? "Guardamos lo que elegiste mientras lo confirmamos."
                  : "Guardamos lo que elegiste por 10 minutos mientras pagás."}</p>`);
    const items = [];
    Object.entries(S.cant).forEach(([id, q]) => { if (q) items.push({ tipo_id: id, cantidad: q }); });
      S.orden = await API.crearOrden(items, { ...S.comprador });

    /* Evento gratis: la orden ya nació emitida del lado del servidor, así que
       no hay pasarela que abrir ni pago que verificar. Se salta derecho a la
       entrada. Un paso de cobro por Bs 0 no es sólo feo: la pasarela lo
       rechaza y el comprador se queda trabado en una pantalla que no avanza. */
    if (S.orden.gratis) {
      pagoDice(`<div class="girador"></div><h3>Confirmando tu lugar</h3>
        <p>Es gratis. Estamos emitiendo tu entrada.</p>`);
      S.entradas = await API.emitir(S.orden);
      await mostrarListo();
      return;
    }

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

/* ── la compra, guardada en este teléfono ─────────────────────────
   Sin correo configurado la entrada vive en la pantalla y en el link, y
   cerrar la pestaña sin copiarlo es perderla. Esta lista es la red: la lee
   /mis-entradas. El formato es un contrato con esa página — id, evento, org,
   slug, fecha, lugar, entradas, guardada— y no se le cambia una clave sin
   avisar del otro lado.

   Todo adentro de un try, sin excepción: hay navegadores con el storage
   bloqueado y modos privados que tiran al escribir, y una compra que ya salió
   bien no se puede caer porque no se pudo guardar un recuerdo de ella.
   Devuelve si quedó guardada, que es lo que decide si el link a /mis-entradas
   tiene algo que mostrar. */
const CLAVE_COMPRAS = "ticketazo.compras";
const TOPE_COMPRAS = 50;

function recordarCompra() {
  try {
    const cuando = fechaEvento();
    const compra = {
      id: S.orden.id,
      evento: `${D.evento.marca_1} ${D.evento.marca_2 || ""}`.trim(),
      org: CFG.ORGANIZADOR || "",
      slug: CFG.EVENTO || "",
      fecha: cuando ? cuando.toISOString() : null,
      lugar: D.evento.lugar || "",
      entradas: S.entradas.length,
      guardada: Date.now()
    };
    const previas = JSON.parse(localStorage.getItem(CLAVE_COMPRAS) || "[]");
    // Filtrar por id es a la vez "no duplicar" y "actualizar": la compra que
    // ya estaba sale de donde estaba y vuelve a entrar con los datos de ahora.
    const lista = Array.isArray(previas) ? previas.filter(c => c && c.id !== compra.id) : [];
    // Adelante la última, que es la que se viene a buscar. Y de a 50: un
    // storage lleno no avisa, empieza a tirar al escribir.
    // Se ordena por `guardada` antes de cortar en vez de confiar en cómo vino
    // la lista: el día que otra página escriba acá y agregue al final, cortar
    // por posición tiraría la compra más nueva en vez de la más vieja.
    lista.unshift(compra);
    lista.sort((a, b) => (Number(b.guardada) || 0) - (Number(a.guardada) || 0));
    localStorage.setItem(CLAVE_COMPRAS, JSON.stringify(lista.slice(0, TOPE_COMPRAS)));
    return true;
  } catch (err) {
    return false;
  }
}

/* ── el evento en la agenda ───────────────────────────────────────
   El .ics se arma acá y no lo trae nadie: son quince renglones de texto y una
   dependencia menos. Dos cosas que parecen ceremonia y no lo son: escapar (una
   coma sin barra invertida parte el campo en dos y el evento entra sin lugar)
   y plegar a 75 octetos, que es lo que el formato pide y lo que hace que
   Outlook no lo abra en blanco.                                             */
const escIcs = s => String(s ?? "")
  .replace(/\\/g, "\\\\").replace(/[;,]/g, m => "\\" + m).replace(/\r?\n/g, "\\n");

// El corte se cuenta en bytes y no en letras: la "ñ" de Cañoto ocupa dos, y
// partirla al medio deja un archivo que el calendario no sabe leer.
function plegar(linea) {
  const enc = new TextEncoder();
  const filas = [];
  let fila = "", bytes = 0;
  for (const ch of linea) {
    const n = enc.encode(ch).length;
    if (bytes + n > 73) { filas.push(fila); fila = " "; bytes = 1; }
    fila += ch; bytes += n;
  }
  filas.push(fila);
  return filas.join("\r\n");
}

const selloIcs = d => d.toISOString().replace(/[-:]/g, "").replace(/\.\d{3}/, "");

function textoIcs(cuando, link) {
  const e = D.evento;
  // Una fiesta no publica hora de cierre. Cinco horas es lo que dura una
  // noche y no se come el día siguiente en la agenda de nadie.
  const fin = new Date(cuando.getTime() + 5 * 3600e3);
  return [
    "BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//TICKETAZO//ES", "CALSCALE:GREGORIAN",
    "BEGIN:VEVENT",
    `UID:${S.orden.id}@ticketazo`,
    `DTSTAMP:${selloIcs(new Date())}`,
    `DTSTART:${selloIcs(cuando)}`,
    `DTEND:${selloIcs(fin)}`,
    `SUMMARY:${escIcs(`${e.marca_1} ${e.marca_2 || ""}`.trim())}`,
    `LOCATION:${escIcs(e.lugar || "")}`,
    // El link va también en la descripción porque hay calendarios que no
    // muestran el campo URL, y ese link es la entrada.
    `DESCRIPTION:${escIcs("Tu entrada: " + link)}`,
    // URL no es un campo de texto: escaparlo le metería barras al link.
    `URL:${link}`,
    "END:VEVENT", "END:VCALENDAR"
  ].map(plegar).join("\r\n") + "\r\n";
}

// Mismo camino que usa ticket.js para bajar los PNG: blob, ancla, click y a
// soltar la URL. Un <a download> escrito en el HTML no sirve — el archivo se
// arma recién cuando se aprieta.
function bajarIcs(cuando, link) {
  const b = new Blob([textoIcs(cuando, link)], { type: "text/calendar;charset=utf-8" });
  const u = URL.createObjectURL(b);
  const a = document.createElement("a");
  a.href = u;
  a.download = `${CFG.EVENTO || "evento"}.ics`;
  document.body.appendChild(a); a.click(); a.remove();
  setTimeout(() => URL.revokeObjectURL(u), 10000);
}

/* Lo que hace falta el día del evento y no hoy. La entrada ya está en la
   pantalla; esto es para que además se llegue al lugar y a la hora. Cada
   botón aparece sólo si tiene con qué: sin fecha reconocible no hay
   calendario, sin lugar no hay mapa, y sin navigator.share no hay compartir.
   Nada de fallbacks — el link para copiar ya está tres centímetros arriba, y
   dos botones que hacen lo mismo no ayudan a nadie.                        */
function armarLlegar(link) {
  const cuando = fechaEvento();
  const lugar = String(D.evento.lugar || "").trim();
  const cal = $("#btnCalendario"), mapa = $("#btnMapa"), comp = $("#btnCompartir");

  cal.hidden = !cuando;
  if (cuando) cal.onclick = () => bajarIcs(cuando, link);

  mapa.hidden = !lugar;
  // Sin API key ni mapa embebido: la búsqueda de Google Maps abre la app del
  // teléfono si está instalada, que es lo que la persona va a usar igual.
  if (lugar) mapa.href =
    "https://www.google.com/maps/search/?api=1&query=" + encodeURIComponent(lugar);

  comp.hidden = !navigator.share;
  if (navigator.share) comp.onclick = async () => {
    try {
      await navigator.share({
        title: `${D.evento.marca_1} ${D.evento.marca_2 || ""}`.trim(),
        text: `Mi entrada para ${D.evento.marca_1} ${D.evento.marca_2 || ""}`.trim(),
        url: link
      });
    } catch (err) { /* cancelar la hoja del sistema no es un error */ }
  };

  $("#llegar").hidden = cal.hidden && mapa.hidden && comp.hidden;
}

async function mostrarListo() {
  irA("listo");
  pararReloj();
  $("#listoNota").textContent =
    `${S.entradas.length} ${S.entradas.length === 1 ? "entrada" : "entradas"} a nombre de ${S.comprador.nombre}.`;
  // Al que no le cobraron nada no le vendiste nada: consiguió un lugar.
  $("#btnOtra").textContent = cotizar().total === 0 ? "Conseguir otra" : "Comprar otra";

  // Este link es el único camino de vuelta si se cierra la pestaña sin
  // descargar: por eso se muestra siempre, no solo cuando el correo falla.
  const linkOrden = linkDeOrden();
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
  // El uuid entero ya está arriba, dentro del link que se copia. Repetirlo
  // acá en crudo ocupaba dos renglones y no le decía nada al comprador: los
  // ocho primeros alcanzan para que la organización encuentre la compra, que
  // es para lo único que este número se lee.
  const correoOk = D.correo_configurado !== false;
  $("#listoRef").textContent =
    `Orden #${String(S.orden.id).slice(0, 8).toUpperCase()}.` +
    (correoOk ? ` También te las mandamos a ${S.comprador.email}.` : "");

  // Antes de dibujar nada: los tickets tardan y el que cierra la pestaña
  // mientras se dibujan igual compró. Si el storage no deja, el link a
  // /mis-entradas no se ofrece.
  $("#listoMias").hidden = !recordarCompra();
  armarLlegar(linkOrden);

  $("#tickets").innerHTML = `<p class="rail-vacio">Dibujando tus entradas…</p>`;

  if (document.fonts && document.fonts.ready) await document.fonts.ready;
  const pngs = [];
  for (const t of S.entradas) pngs.push(await dibujarTicket(t));
  S.entradas.forEach((t, i) => t.png = pngs[i]);

  // Escalonadas: la primera aparece sola y el resto la siguen. Todas juntas
  // se leen como un bloque; de a una se lee como "estas son tuyas".
  // La tira la arma ticket.js, la misma que dibuja /orden/?id=…: son el mismo
  // momento y separarlas en dos plantillas es pedir que se despeguen.
  $("#tickets").innerHTML = window.tiraTickets(S.entradas);
}

/* Guardar y no descargar: en un teléfono la descarga de seis PNG no deja
   nada a la vista. ticket.js abre la hoja de compartir del sistema cuando
   existe —ahí adentro está "Guardar imagen"— y baja los archivos cuando no. */
async function descargar() {
  const b = $("#btnDescargar");
  b.disabled = true;
  try {
    const como = await window.guardarEntradas(S.entradas);
    if (como === "bajada")
      avisar(`${S.entradas.length} ${S.entradas.length === 1
        ? "entrada guardada" : "entradas guardadas"}.`);
  } catch (err) {
    avisar("No se pudieron guardar. Mantené apretada la entrada y elegí Guardar imagen.");
  } finally {
    b.disabled = false;
  }
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
$("#pasos").addEventListener("scroll", marcarDesborde, { passive: true });
addEventListener("resize", () => { marcarDesborde(); medirBarra(); });
/* La barra crece cuando el aviso pasa a dos líneas o cuando termina de cargar
   la tipografía, y eso no pasa por pintarRail(). El observer lo agarra igual. */
if (window.ResizeObserver) new ResizeObserver(medirBarra).observe($("#rail"));

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
  /* Sin RESEND_API_KEY no sale un correo nunca, y la página lo prometía dos
     veces antes de que el comprador escribiera una letra: en el encabezado del
     formulario y en el error del campo. El dato lo manda la función `evento`;
     si dice que no, la página deja de prometerlo. El correo se sigue pidiendo
     —es como la organización encuentra la compra— pero deja de ser un envío. */
  if (D.correo_configurado === false) {
    $('[data-paso="datos"] .panel-nota').textContent = "Con esto emitimos tu entrada.";
    REGLAS.fMail.msg = "Revisá el correo: queda en tu comprobante.";
  }
  D.tipos.forEach(t => S.cant[t.id] = 0);
  fijarVocabulario();
  pintarHero();
  pintarCierre();
  pintarTipos();
  irA("entradas");
}
arrancar();
})();
