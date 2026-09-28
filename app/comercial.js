/* ══════════════════════════════════════════════════════════════════
   TICKETAZO — las dos páginas comerciales

   Un archivo para /organizadores y /presentacion. Lo que hace:
   1. pone el contacto en todos los botones desde UN solo lugar,
   2. hace aparecer las secciones al llegar,
   3. y en el deck, mueve el índice y la barra de progreso.
   ══════════════════════════════════════════════════════════════════ */

/* El contacto de las dos páginas, en un solo lugar.
   `wa` va sin +, sin espacios y sin guiones: es lo que pide wa.me.
   Si queda vacío, los botones de WhatsApp se esconden solos en vez de
   mandar a un número que no existe — un botón roto en una presentación
   comercial cuesta más que un botón de menos. */
const CONTACTO = {
  wa: "59178183001",
  texto: "Hola, quiero vender mis entradas con TICKETAZO.",
  correo: "",                        // opcional
  instagram: ""                      // opcional, sin @
};

(function contacto(){
  const url = CONTACTO.wa
    ? `https://wa.me/${CONTACTO.wa}?text=${encodeURIComponent(CONTACTO.texto)}`
    : "";
  document.querySelectorAll("[data-wa]").forEach(a => {
    if (url) { a.href = url; a.target = "_blank"; a.rel = "noopener"; }
    else a.hidden = true;
  });
  document.querySelectorAll("[data-ig]").forEach(a => {
    if (CONTACTO.instagram) { a.href = `https://instagram.com/${CONTACTO.instagram}`; a.target = "_blank"; a.rel = "noopener"; }
    else a.hidden = true;
  });
  document.querySelectorAll("[data-correo]").forEach(a => {
    if (CONTACTO.correo) a.href = `mailto:${CONTACTO.correo}`;
    else a.hidden = true;
  });
})();

/* Aparecer al llegar. Se desconecta apenas apareció: una sección que ya
   se vio no vuelve a esconderse, así que el observer no tiene nada más
   que mirar y quedarse escuchando el scroll de una página entera es la
   clase de gasto que sólo se nota en un teléfono viejo. */
(function revelar(){
  const cosas = document.querySelectorAll(".rev");
  if (!cosas.length) return;
  if (!("IntersectionObserver" in window) ||
      matchMedia("(prefers-reduced-motion: reduce)").matches) {
    cosas.forEach(c => c.classList.add("vista"));
    return;
  }
  const raiz = document.querySelector(".deck") || null;

  /* La red de seguridad. Todo esto nace invisible y sólo el observer lo
     enciende, así que si el observer no entrega —pestaña abierta en
     segundo plano, pantalla nunca visible, cualquier motivo— la página
     queda en blanco. Y una página comercial en blanco es peor que una sin
     animación. Si a segundo y medio no llegó ni una entrega, se muestra
     todo de una vez y se acabó el efecto. */
  let entrego = false;
  const obs = new IntersectionObserver((entradas, o) => {
    entrego = true;
    entradas.forEach(e => {
      if (!e.isIntersecting) return;
      e.target.classList.add("vista");
      o.unobserve(e.target);
    });
  }, { root: raiz, rootMargin: "0px 0px -8% 0px", threshold: .12 });
  cosas.forEach(c => obs.observe(c));
  setTimeout(() => {
    if (!entrego) cosas.forEach(c => c.classList.add("vista"));
  }, 1500);
})();

/* El deck. Sólo corre si la página es un deck. */
(function deck(){
  const caja = document.querySelector(".deck");
  if (!caja) return;

  const laminas = [...caja.querySelectorAll(".lamina")];
  const indice  = document.getElementById("indice");
  const barra   = document.getElementById("progreso");
  const avanzar = document.getElementById("avanzar");

  /* El índice se dibuja acá y no en el HTML: son tantos puntos como
     láminas haya, y así agregar una lámina no obliga a acordarse de
     tocar dos lugares. */
  if (indice) {
    laminas.forEach((l, i) => {
      const a = document.createElement("a");
      a.href = "#" + l.id;
      a.textContent = String(i + 1).padStart(2, "0");
      a.setAttribute("aria-label", `Ir a la lámina ${i + 1}: ${l.dataset.titulo || ""}`);
      indice.append(a);
    });
  }

  const puntos = indice ? [...indice.children] : [];
  let actual = 0;

  function pintar(i){
    actual = i;
    puntos.forEach((p, n) => p.setAttribute("aria-current", n === i ? "true" : "false"));
    if (barra) barra.style.width = ((i + 1) / laminas.length * 100) + "%";
    if (avanzar) avanzar.hidden = (i === laminas.length - 1);
  }

  /* Qué lámina está en pantalla. Con `proximity` el scroll puede quedar a
     mitad de camino, así que gana la que más superficie ocupa y no la
     primera que toca el borde. */
  const obs = new IntersectionObserver(entradas => {
    let mejor = null;
    entradas.forEach(e => {
      if (e.isIntersecting && (!mejor || e.intersectionRatio > mejor.intersectionRatio)) mejor = e;
    });
    if (mejor) pintar(laminas.indexOf(mejor.target));
  }, { root: caja, threshold: [.3, .55, .8] });
  laminas.forEach(l => obs.observe(l));
  pintar(0);

  function ir(i){
    const n = Math.max(0, Math.min(laminas.length - 1, i));
    laminas[n].scrollIntoView({ behavior:
      matchMedia("(prefers-reduced-motion: reduce)").matches ? "auto" : "smooth" });
  }
  if (avanzar) avanzar.addEventListener("click", () => ir(actual + 1));

  /* Teclado: flechas y espacio, como cualquier presentación. Se ignora si
     el foco está en un enlace del índice — ahí la flecha ya navega. */
  addEventListener("keydown", ev => {
    if (ev.metaKey || ev.ctrlKey || ev.altKey) return;
    const k = ev.key;
    if (k === "ArrowRight" || k === "ArrowDown" || k === "PageDown" || k === " ") {
      ev.preventDefault(); ir(actual + 1);
    } else if (k === "ArrowLeft" || k === "ArrowUp" || k === "PageUp") {
      ev.preventDefault(); ir(actual - 1);
    } else if (k === "Home") { ev.preventDefault(); ir(0); }
    else if (k === "End")  { ev.preventDefault(); ir(laminas.length - 1); }
  });
})();

/* ══════════════════════════════════════════════════════════════════
   La cuenta del evento

   Dos campos y un recibo que se rehace. Es la única parte de la
   presentación que el cliente toca, y existe por una razón de venta:
   un ejemplo con números nuestros se mira; el número propio se
   discute. La reunión donde el cliente discute su propio número ya
   está ganada.
   ══════════════════════════════════════════════════════════════════ */
(function cuenta(){
  const cant = document.getElementById("cant");
  const precio = document.getElementById("precio");
  if (!cant || !precio) return;
  const fee = document.getElementById("fee");   // sólo en la presentación

  const $ = id => document.getElementById(id);
  const salida = { linea: $("lineaEntradas"), sub: $("subtotal"), cargo: $("cargo"),
                   filaTotal: $("filaTotal"), total: $("total"), tuyo: $("tuyo") };

  const bs = n => n.toLocaleString("es-BO", { minimumFractionDigits: 2,
                                              maximumFractionDigits: 2 });
  const entero = n => n.toLocaleString("es-BO");

  /* Un campo vacío no es cero: es alguien a mitad de escribir. Mientras
     tanto se sostiene el último valor válido en vez de mostrar Bs 0,00,
     que en una reunión se lee como que el sistema se rompió. */
  let ultimaCant = 1000, ultimoPrecio = 100;

  function leer(campo, ultimo){
    const n = Math.floor(Number(campo.value));
    if (!Number.isFinite(n) || n < 1) return ultimo;
    return Math.min(n, Number(campo.max) || n);
  }

  /* El cargo es la excepción: vacío SÍ significa vacío. Ninguna de las dos
     páginas publica una tarifa —cada cliente negocia la suya— así que sin
     número el recibo muestra sólo lo que no se negocia: que el precio de la
     entrada es entero del organizador. Con número, la cuenta se completa. */
  function leerFee(){
    if (!fee) return null;
    const n = Number(fee.value);
    if (fee.value.trim() === "" || !Number.isFinite(n) || n < 0) return null;
    return Math.min(n, Number(fee.max) || n) / 100;
  }

  function pintar(){
    ultimaCant   = leer(cant, ultimaCant);
    ultimoPrecio = leer(precio, ultimoPrecio);

    const sub = ultimaCant * ultimoPrecio;
    const pct = leerFee();

    salida.linea.textContent = `${entero(ultimaCant)} × Bs ${entero(ultimoPrecio)}`;
    salida.sub.textContent   = bs(sub);
    salida.tuyo.textContent  = "Bs " + bs(sub);

    if (pct === null) {
      salida.cargo.textContent = "a convenir";
      if (salida.filaTotal) salida.filaTotal.hidden = true;
    } else {
      const cargo = Math.round(sub * pct);
      salida.cargo.textContent = bs(cargo);
      if (salida.filaTotal) {
        salida.filaTotal.hidden = false;
        salida.total.textContent = "Bs " + bs(sub + cargo);
      }
    }
  }

  [cant, precio, fee].forEach(c => c && c.addEventListener("input", pintar));
  pintar();
})();

/* ══════════════════════════════════════════════════════════════════
   Quiero vender con TICKETAZO

   Dos pasos y ninguno bloquea al otro. Primero se guarda el pedido en la
   función `contacto` —para que exista aunque la conversación se pierda—
   y después se abre WhatsApp con el mismo resumen ya escrito, que es el
   único aviso que hay: no hay correo configurado, y un pedido que sólo
   vive en una tabla es un pedido que nadie vio.

   Si guardar falla (sin señal, función caída), el WhatsApp se abre igual.
   Perder un cliente porque se cayó una tabla sería absurdo.
   ══════════════════════════════════════════════════════════════════ */
(function contacto(){
  const forma = document.getElementById("formaContacto");
  if (!forma) return;
  const error = document.getElementById("formaError");
  const boton = document.getElementById("formaEnviar");
  const listo = document.getElementById("formaListo");
  const cfg = window.CONFIG || {};

  const v = n => (forma.elements[n]?.value ?? "").trim();

  function resumen(){
    const l = [`Hola, quiero vender mis entradas con TICKETAZO.`, ``,
               `Soy ${v("nombre")}.`];
    if (v("evento"))       l.push(`Evento: ${v("evento")}`);
    if (v("fecha_evento")) l.push(`Fecha: ${v("fecha_evento")}`);
    if (v("lugar"))        l.push(`Lugar: ${v("lugar")}`);
    if (v("publico"))      l.push(`Público estimado: ${v("publico")} personas`);
    if (v("mensaje"))      l.push(``, v("mensaje"));
    l.push(``, `Me contactás en: ${v("contacto")}`);
    return l.join("\n");
  }

  function fallar(msj){
    error.textContent = msj; error.hidden = false;
    boton.disabled = false; boton.textContent = "Quiero vender con TICKETAZO";
  }

  forma.addEventListener("submit", async ev => {
    ev.preventDefault();
    error.hidden = true;
    if (v("nombre").length < 2)   return fallar("Contanos tu nombre.");
    if (v("contacto").length < 5) return fallar("Dejanos un WhatsApp o un correo para responderte.");

    boton.disabled = true; boton.textContent = "Enviando…";

    /* El WhatsApp se arma antes de guardar y se muestra pase lo que pase. */
    const wa = document.getElementById("formaWa");
    wa.href = CONTACTO.wa
      ? `https://wa.me/${CONTACTO.wa}?text=${encodeURIComponent(resumen())}`
      : "#";

    if (cfg.SUPABASE_URL && cfg.SUPABASE_ANON_KEY) {
      try {
        const r = await fetch(`${cfg.SUPABASE_URL}/functions/v1/contacto`, {
          method: "POST",
          headers: { "Content-Type": "application/json",
                     apikey: cfg.SUPABASE_ANON_KEY,
                     Authorization: `Bearer ${cfg.SUPABASE_ANON_KEY}` },
          body: JSON.stringify({
            nombre: v("nombre"), contacto: v("contacto"), evento: v("evento"),
            fecha_evento: v("fecha_evento"), lugar: v("lugar"), publico: v("publico"),
            mensaje: v("mensaje"), sitio: v("sitio"),
            origen: location.pathname.includes("presentacion") ? "presentacion" : "organizadores",
          }),
        });
        const j = await r.json().catch(() => ({}));
        /* 429 es "demasiados desde esta IP": se le dice al que lo intenta y
           NO se sigue a WhatsApp, que es lo que un script querría. */
        if (r.status === 429) return fallar(j.motivo || "Probá de nuevo en un rato.");
      } catch (e) {
        console.warn("contacto: no se pudo guardar, se sigue por WhatsApp", e);
      }
    }

    forma.hidden = true; listo.hidden = false;
    listo.scrollIntoView({ block: "center", behavior:
      matchMedia("(prefers-reduced-motion: reduce)").matches ? "auto" : "smooth" });
  });
})();

/* ══════════════════════════════════════════════════════════════════
   LAS MAQUETAS — 28/09/2026

   Cuatro piezas: el fondo de ondas, el QR dibujado, la puerta que
   escanea mientras mantenés apretado, y el panel con las fases.

   Tres reglas que valen para las cuatro:

   1. Nada arranca hasta estar en pantalla, y todo se detiene al salir.
      Un `requestAnimationFrame` corriendo detrás de una sección que
      nadie mira le come la batería a un teléfono por nada.
   2. `prefers-reduced-motion` no es "más lento": es apagado. La maqueta
      se dibuja en su estado final y se queda ahí.
   3. Si algo falla —un canvas que no da contexto, un elemento que no
      está— la pieza se calla y la página sigue. Ninguna de estas
      animaciones vale una excepción que corte el script de contacto o
      el del formulario, que son los que dan plata.
   ══════════════════════════════════════════════════════════════════ */

const QUIETO = matchMedia("(prefers-reduced-motion: reduce)").matches;

/* Corre `arrancar` cuando el elemento entra en pantalla y `parar`
   cuando sale. Devuelve una función que desconecta todo. */
function enPantalla(el, arrancar, parar) {
  if (!el || !("IntersectionObserver" in window)) { arrancar(); return () => {}; }
  let dentro = false;
  const obs = new IntersectionObserver(es => {
    const v = es.some(e => e.isIntersecting);
    if (v === dentro) return;
    dentro = v;
    v ? arrancar() : parar();
  }, { threshold: .08 });
  obs.observe(el);
  /* Una pestaña en segundo plano no dispara el observer pero tampoco
     pinta: parar acá ahorra el rAF de una ventana que nadie ve. */
  document.addEventListener("visibilitychange", () => {
    if (document.hidden) parar(); else if (dentro) arrancar();
  });
  return () => obs.disconnect();
}

/* ─── 1. el fondo de ondas ────────────────────────────────────────
   Tres senos superpuestos, dibujados por cuadro. No es ruido Perlin ni
   WebGL: a este tamaño y esta velocidad la diferencia no se ve, y un
   seno corre en cualquier teléfono.

   El canvas se dibuja a resolución de dispositivo (devicePixelRatio)
   pero tapado a 2: en un teléfono con pantalla 3x, dibujar 3x de un
   fondo desenfocado es triplicar el trabajo para nada. */
(function ondas(){
  const cv = document.getElementById("ondas");
  if (!cv) return;
  const cx = cv.getContext("2d", { alpha: true });
  if (!cx) return;
  if (QUIETO) return;                       // el CSS ya lo esconde

  let w = 0, h = 0, t = 0, id = 0, vivo = false;

  function medir() {
    const r = cv.getBoundingClientRect();
    const dpr = Math.min(devicePixelRatio || 1, 2);
    w = Math.max(1, Math.round(r.width));
    h = Math.max(1, Math.round(r.height));
    cv.width = Math.round(w * dpr);
    cv.height = Math.round(h * dpr);
    cx.setTransform(dpr, 0, 0, dpr, 0, 0);
  }

  const CAPAS = [
    { amp: .16, largo: 1.35, vel: .00028, y: .60, color: "rgba(58,36,120,.55)", grosor: 1.4 },
    { amp: .11, largo: 1.90, vel: .00041, y: .68, color: "rgba(35,21,80,.75)",  grosor: 1.2 },
    { amp: .07, largo: 2.60, vel: .00062, y: .76, color: "rgba(255,226,75,.10)", grosor: 1   }
  ];

  function pintar(ahora) {
    if (!vivo) return;
    t = ahora;
    cx.clearRect(0, 0, w, h);
    CAPAS.forEach(c => {
      cx.beginPath();
      /* De a 6 píxeles y no de a 1: a 1 son mil puntos por curva por
         cuadro y la diferencia visual es cero en una curva tan suave. */
      for (let x = 0; x <= w; x += 6) {
        const k = x / w * Math.PI * 2 * c.largo + t * c.vel;
        const y = h * c.y + Math.sin(k) * h * c.amp + Math.sin(k * 1.7) * h * c.amp * .3;
        x === 0 ? cx.moveTo(x, y) : cx.lineTo(x, y);
      }
      cx.strokeStyle = c.color;
      cx.lineWidth = c.grosor;
      cx.stroke();
    });
    id = requestAnimationFrame(pintar);
  }

  const arrancar = () => { if (vivo) return; vivo = true; id = requestAnimationFrame(pintar); };
  const parar = () => { vivo = false; cancelAnimationFrame(id); };

  medir();
  addEventListener("resize", () => { medir(); }, { passive: true });
  enPantalla(cv, arrancar, parar);
})();

/* ─── 2. el QR ────────────────────────────────────────────────────
   No es un QR de verdad y no pretende serlo: es el DIBUJO de un QR,
   para que la maqueta se lea de un vistazo como lo que es. Uno real
   necesitaría una librería de 20 KB para una imagen decorativa que
   nadie va a escanear desde una landing.

   El patrón sale de una semilla fija, así que el mismo QR sale igual
   en cada carga: un QR que cambia de forma cada vez que recargás la
   página es de las cosas que hacen dudar de todo lo demás. */
function dibujarQR(cv, { celdas = 25, semilla = 7, avance = 1 } = {}) {
  const cx = cv.getContext("2d");
  if (!cx) return;
  const lado = cv.width, paso = lado / celdas;
  cx.clearRect(0, 0, lado, lado);
  cx.fillStyle = "#120A2C";

  /* Congruencial lineal: dos líneas, determinista, suficiente para que
     el ojo lea "ruido". */
  let s = semilla;
  const azar = () => (s = (s * 1103515245 + 12345) % 2147483648) / 2147483648;

  const ojo = (cf, cc) => {
    for (let f = 0; f < 7; f++) for (let c = 0; c < 7; c++) {
      const borde = f === 0 || f === 6 || c === 0 || c === 6;
      const centro = f >= 2 && f <= 4 && c >= 2 && c <= 4;
      if (borde || centro) cx.fillRect((cc + c) * paso, (cf + f) * paso, paso, paso);
    }
  };

  const dentroDeOjo = (f, c) =>
    (f < 8 && c < 8) || (f < 8 && c >= celdas - 8) || (f >= celdas - 8 && c < 8);

  const total = celdas * celdas;
  let hechas = 0;
  for (let f = 0; f < celdas; f++) {
    for (let c = 0; c < celdas; c++) {
      const r = azar();
      if (dentroDeOjo(f, c)) continue;
      /* `avance` de 0 a 1 es cuánto del QR ya se dibujó: así el mismo
         código sirve para la animación de armado y para el estado
         final, sin dos caminos que se puedan desincronizar. */
      if (hechas++ / total > avance) continue;
      if (r > .52) cx.fillRect(c * paso, f * paso, paso, paso);
    }
  }
  if (avance > .7) { ojo(0, 0); ojo(0, celdas - 7); ojo(celdas - 7, 0); }
}

/* El QR del hero se arma solo la primera vez que se ve. */
(function qrHero(){
  const cv = document.getElementById("qrHero");
  if (!cv) return;
  if (QUIETO) { dibujarQR(cv); return; }

  let corrio = false, id = 0;
  const arrancar = () => {
    if (corrio) return;
    corrio = true;
    const desde = performance.now(), dura = 900;
    const paso = ahora => {
      const p = Math.min(1, (ahora - desde) / dura);
      dibujarQR(cv, { avance: p });
      if (p < 1) id = requestAnimationFrame(paso);
    };
    id = requestAnimationFrame(paso);
  };
  dibujarQR(cv, { avance: 0 });
  enPantalla(cv, arrancar, () => cancelAnimationFrame(id));
})();

/* ─── 3. la puerta ────────────────────────────────────────────────
   Mientras el botón está apretado entra una persona cada 750 ms. Se
   sostiene con puntero (mouse, dedo y lápiz en un solo juego de
   eventos) y con teclado, porque un botón que sólo responde al mouse
   deja afuera a quien navega con tabulador.

   El conteo sube y baja del mismo lugar que la lista: si el número y
   los nombres salieran de dos contadores distintos, en algún momento
   dirían cosas distintas y esa es justo la desconfianza que la
   maqueta tiene que evitar. */
(function puerta(){
  const btn = document.getElementById("puertaBtn");
  const cartel = document.getElementById("ptaCartel");
  const num = document.getElementById("ptaNum");
  const log = document.getElementById("ptaLog");
  const qr = document.getElementById("qrPuerta");
  if (!btn || !cartel || !num || !log || !qr) return;

  const GENTE = [
    ["Camila Rojas", "General"], ["Mateo Áñez", "General"],
    ["Valeria Suárez", "VIP"],   ["Joaquín Melgar", "General"],
    ["Antonella Áñez", "General"], ["Bruno Céspedes", "VIP"],
    ["Fabiana Roca", "General"], ["Ignacio Vaca", "General"]
  ];

  let i = 0, adentro = 406, reloj = 0, apretado = false;

  dibujarQR(qr, { semilla: 31, celdas: 21 });

  const hora = () => {
    /* Una hora inventada y estable: la real diría "14:20" en una
       maqueta de una puerta de boliche y eso se nota. */
    const m = (40 + i) % 60, h = 23 + Math.floor((40 + i) / 60);
    return `${String(h % 24).padStart(2, "0")}:${String(m).padStart(2, "0")}`;
  };

  function entra() {
    const [nombre, tipo] = GENTE[i % GENTE.length];
    /* Uno de cada siete llega con una entrada ya usada. Sin eso la
       maqueta muestra un sistema que siempre dice que sí, que es
       justamente lo que un control de puerta NO es. */
    const repetida = i > 0 && i % 7 === 0;
    i++;

    if (!repetida) {
      adentro++;
      num.textContent = adentro;
    }
    cartel.textContent = repetida ? "Ya entró · no pasa" : "Válida · pasá";
    cartel.dataset.tipo = repetida ? "repetida" : "ok";
    cartel.dataset.on = "1";

    dibujarQR(qr, { semilla: 31 + i * 13, celdas: 21 });

    const li = document.createElement("li");
    li.innerHTML = `<span>${nombre} · ${tipo}</span><span>${hora()}</span>`;
    log.prepend(li);
    while (log.children.length > 3) log.lastElementChild.remove();
  }

  function abrir() {
    if (apretado) return;
    apretado = true;
    btn.dataset.on = "1";
    entra();
    reloj = setInterval(entra, 750);
  }
  function cerrar() {
    if (!apretado) return;
    apretado = false;
    btn.dataset.on = "0";
    clearInterval(reloj);
    setTimeout(() => { if (!apretado) cartel.dataset.on = "0"; }, 700);
  }

  if (QUIETO) {
    /* Sin movimiento el botón sigue sirviendo: cada toque deja entrar
       a una persona. La función se entiende igual, sin nada latiendo. */
    btn.addEventListener("click", entra);
    return;
  }

  btn.addEventListener("pointerdown", ev => { ev.preventDefault(); abrir(); });
  ["pointerup", "pointerleave", "pointercancel"].forEach(e =>
    btn.addEventListener(e, cerrar));
  btn.addEventListener("keydown", ev => {
    if (ev.key === " " || ev.key === "Enter") { ev.preventDefault(); abrir(); }
  });
  btn.addEventListener("keyup", cerrar);
  btn.addEventListener("blur", cerrar);
})();

/* ─── 4. el panel ─────────────────────────────────────────────────
   La fase General se llena, se agota y abre Puerta; mientras tanto a
   un relacionador le entra una venta. Corre una sola vez por visita:
   en bucle sería un cartel de neón al lado de un párrafo. */
(function panel(){
  const barra = document.getElementById("faseBarra");
  const est = document.getElementById("faseEst");
  const lista = document.getElementById("rrppLista");
  const caja = document.getElementById("fases");
  if (!barra || !est || !lista || !caja) return;

  const fin = () => {
    barra.style.width = "100%";
    est.textContent = "agotada";
    est.dataset.est = "agotada";
    const tercera = document.querySelector('.fase[data-fase="2"]');
    if (tercera) {
      tercera.classList.remove("apagada");
      const e3 = tercera.querySelector(".fase-est");
      if (e3) { e3.textContent = "abierta"; e3.dataset.est = "abierta"; }
    }
  };

  if (QUIETO) { fin(); return; }

  let corrio = false;
  const relojes = [];
  const arrancar = () => {
    if (corrio) return;
    corrio = true;
    est.dataset.est = "vendiendo";

    [[400, 58], [1100, 79], [1900, 94]].forEach(([ms, pct]) =>
      relojes.push(setTimeout(() => { barra.style.width = pct + "%"; }, ms)));

    /* La venta que se acredita sola: el número sube y la fila se
       enciende un momento. Es la respuesta visual a "¿y cómo sé que
       la venta quedó a nombre del que la trajo?". */
    relojes.push(setTimeout(() => {
      const li = lista.querySelector('li[data-r="1"]');
      if (!li) return;
      const n = li.querySelector(".rrpp-n");
      if (n) n.textContent = Number(n.textContent) + 1;
      li.dataset.nueva = "1";
      relojes.push(setTimeout(() => { li.dataset.nueva = "0"; }, 1400));
    }, 1500));

    relojes.push(setTimeout(fin, 2700));
  };

  enPantalla(caja, arrancar, () => {});
})();
