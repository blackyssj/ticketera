/* ══════════════════════════════════════════════════════════════════
   TICKETAZO · la portada

   La puerta de entrada: qué hay a la venta y un link a cada evento. Habla
   con una sola Edge Function (`eventos`) y con nada más — sin sesión, sin
   supabase-js y sin escribir una línea en la base. Todo lo que se pinta
   acá ya vino filtrado por la función, que es la que decide qué puede ver
   el público.

   `fetch` pelado y no el cliente de supabase, como en orden.js: es un GET
   sin autenticación, y traer 40 kB de SDK por CDN para eso retrasaría lo
   único que importa en la primera pantalla — los flyers.

   La página se arma en dos zonas y cuáles aparecen depende de CUÁNTOS
   eventos hay, porque una cartelera de uno y una de veinte no son la misma
   página con distinta cantidad de tarjetas:

     1 evento  → una entrada sola a tamaño de afiche. Sin grilla: una
                 cuadrícula de un elemento se lee como una que no cargó.
     2 a 4     → la más próxima grande y el resto en la grilla.
     5 o más   → carrusel con las cinco más próximas y la grilla completa
                 debajo. Recién ahí "lo destacado" separa algo de algo.
   ══════════════════════════════════════════════════════════════════ */
(() => {
"use strict";

const CFG = window.CONFIG || {};
const $ = s => document.querySelector(s);
const esc = s => String(s ?? "").replace(/[&<>"']/g, c =>
  ({ "&":"&amp;", "<":"&lt;", ">":"&gt;", '"':"&quot;", "'":"&#39;" }[c]));

const bs = n => Number(n).toLocaleString("es-BO") + " Bs";

/* Una sola pregunta al sistema operativo y de ella cuelga todo el
   movimiento de la página: la entrada de las tarjetas, la transición al
   abrir un evento y hasta si el carrusel se desliza o salta. La consulta
   es en vivo (no una foto al cargar) porque en el teléfono el ahorro de
   batería puede prenderla mientras la página está abierta. */
const quieto = window.matchMedia("(prefers-reduced-motion: reduce)");

/* Los dos sellos que puede llevar un afiche. `abierta` no lleva ninguno:
   un cartel que dice "hay entradas" en todas las tarjetas no informa nada,
   sólo le quita fuerza al que sí importa. */
const SELLOS = {
  ultimas:  { clase: "sello-pocas",   txt: "Últimas entradas" },
  agotado:  { clase: "sello-agotado", txt: "Agotado" },
};

const MESES = ["enero","febrero","marzo","abril","mayo","junio","julio",
               "agosto","septiembre","octubre","noviembre","diciembre"];

function pedirCartelera() {
  return fetch(`${CFG.SUPABASE_URL}/functions/v1/eventos`, {
    headers: { Authorization: `Bearer ${CFG.SUPABASE_ANON_KEY}` },
  }).then(r => r.json());
}

/* ── el afiche ──
   El flyer manda: es la imagen que el organizador ya publicó en redes y por
   la que la gente reconoce la fiesta antes de leer una palabra. Por eso
   ocupa la tarjeta entera y todo lo demás es el talón.

   Debajo del flyer va SIEMPRE un papel dibujado, y no como respaldo teórico:
   es lo que se ve mientras la imagen viaja por el 4G de un teléfono, y lo
   que queda si la imagen no llega nunca. Sin flyer cargado ese papel es el
   afiche entero, con el nombre a tamaño de cartel — un evento recién creado
   no puede verse como una tarjeta rota, porque el que llega no sabe que le
   falta la imagen: ve una ticketera que no funciona.

   `prioridad` la traen las primeras de la página: son las que decide el
   navegador antes de saber qué hay más abajo. */
function afiche(e, prioridad) {
  const s = SELLOS[e.venta];
  const sello = s ? `<span class="sello ${s.clase}">${esc(s.txt)}</span>` : "";

  /* El día en grande es el ancla gráfica del papel. Es un dato, no un
     adorno: sin flyer, la fecha es lo único que este evento tiene para
     mostrar de lejos.

     El papel nombra al evento SIEMPRE, tenga flyer o no. Con flyer queda
     tapado por la imagen y no se ve nunca — salvo en los dos momentos en
     que hace falta: mientras el PNG viaja por el 4G, y si no llega. Antes
     esos dos momentos dejaban un rectángulo rayado sin una palabra, y en la
     entrada grande —donde el día no se dibuja— un rectángulo entero vacío.
     Un evento anónimo justo cuando lo único que se puede hacer es leer.

     Tapado sigue estando en el árbol de accesibilidad, así que cuando hay
     imagen el papel se marca como decoración: el `alt` y el talón ya dicen
     el nombre, y no hace falta oírlo tres veces. */
  const papel = `<div class="papel"${e.flyer_url ? ' aria-hidden="true"' : ""}>
      <span class="papel-dia" aria-hidden="true">${esc(e.dia)}</span>
      <h3 class="papel-nombre">${esc(e.nombre)}</h3>
      <span class="papel-org">${esc(e.organizador_nombre)}</span>
    </div>`;

  /* width/height con la proporción del recorte (4:5): el hueco queda
     reservado antes de que baje un solo byte y la grilla no salta cuando
     las imágenes van llegando de a una. */
  const img = e.flyer_url
    ? `<img src="${esc(e.flyer_url)}" alt="Flyer de ${esc(e.nombre)}"
            width="800" height="1000"
            loading="${prioridad ? "eager" : "lazy"}" decoding="async"
            ${prioridad ? 'fetchpriority="high"' : ""}>`
    : "";

  return `<div class="afiche">${papel}${img}${sello}</div>`;
}

const perf = `<div class="perf" aria-hidden="true"><i class="p1"></i><i class="p2"></i></div>`;

/* ── la tarjeta de la grilla ──
   Tres renglones en el talón y ni uno más. Es la diferencia con la
   convención local, donde la tarjeta es el flyer y un botón que dice "ver
   más": ahí hay que abrir el evento para saber qué día es. Acá la fecha se
   lee sin abrir nada, y sigue siendo el flyer el que ocupa la tarjeta.

   El nombre se repite en el talón sólo cuando arriba hay una imagen. Sin
   flyer ya está en el papel, cuatro veces más grande, y repetirlo sesenta
   píxeles más abajo es un tartamudeo, no una jerarquía. */
function tarjeta(e, i) {
  const conFlyer = !!e.flyer_url;
  return `<a class="evento${e.venta === "agotado" ? " agotado" : ""}" href="${esc(e.url)}">
    ${afiche(e, i < 2)}
    ${perf}
    <div class="talon">
      <div class="cuando"><span>${esc(e.fecha_txt)}</span>
        <i class="flecha" aria-hidden="true"></i></div>
      ${conFlyer ? `<h3 class="nombre">${esc(e.nombre)}</h3>` : ""}
      <div class="pie-talon">
        <span class="donde">${esc(e.lugar)}</span>
        ${e.desde != null ? `<span class="desde">desde <b>${esc(bs(e.desde))}</b></span>` : ""}
      </div>
    </div>
  </a>`;
}

/* ── la entrada grande ──
   La misma pieza que la tarjeta, en horizontal y con el talón completo: el
   flyer a un lado, la perforación al medio y del otro lado lo que en una
   entrada de papel va impreso en el talón. Con un solo evento en venta es
   lo único que hay en la página, así que tiene que aguantar sola.

   Vale la misma regla del nombre que en la tarjeta chica, y acá se nota
   más: sin flyer, el papel ya grita RED CIRCLE a media pieza de distancia
   y repetirlo en el talón deja el mismo nombre dos veces en la misma
   entrada, en dos tamaños, a veinte centímetros. Con el organizador pasa
   igual: lo que el papel ya dice, el talón no lo repite. */
function destacado(e, i) {
  return `<a class="destacado${e.venta === "agotado" ? " agotado" : ""}" href="${esc(e.url)}">
    ${afiche(e, i === 0)}
    ${perf}
    <div class="talon">
      <span class="cuando">${esc(e.dia_semana)} · ${esc(e.hora)}</span>
      <div class="fechon"><b>${esc(e.dia)}</b><span>${esc(MESES[Number(e.fecha.slice(5, 7)) - 1] || e.mes)}</span></div>
      ${e.flyer_url ? `<h3 class="nombre">${esc(e.nombre)}</h3>` : ""}
      <p class="donde">${esc(e.lugar)}</p>
      <div class="pie-talon">
        ${e.flyer_url ? `<span class="quien">${esc(e.organizador_nombre)}</span>` : ""}
        ${e.desde != null ? `<span class="desde">desde <b>${esc(bs(e.desde))}</b></span>` : ""}
      </div>
      <span class="ver" aria-hidden="true">Ver entradas<i class="flecha"></i></span>
    </div>
  </a>`;
}

/* El separador de mes aparece SÓLO si la cartelera cruza más de uno. Con
   todo en septiembre, un rótulo que dice "septiembre" arriba de todo no
   separa nada: es una línea que hay que leer y descartar. */
function conMeses(lista) {
  const clave = e => e.fecha.slice(0, 7);
  const unico = new Set(lista.map(clave)).size < 2;
  let ultimo = null;
  return lista.map((e, i) => {
    const html = tarjeta(e, i);
    if (unico || clave(e) === ultimo) return html;
    ultimo = clave(e);
    const anio = e.fecha.slice(0, 4);
    const mes = MESES[Number(e.fecha.slice(5, 7)) - 1];
    const hoy = String(new Date().getFullYear());
    return `<h3 class="mes">${esc(mes)}${anio === hoy ? "" : " " + esc(anio)}</h3>` + html;
  }).join("");
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

/* ── que una imagen rota no rompa la tarjeta, y que la buena se note ──
   El papel ya está dibujado debajo, así que alcanza con sacar la imagen que
   no llegó: la tarjeta queda como la de un evento sin flyer, que es un
   estado que la página sabe dibujar bien.

   La que sí llega se marca, y el CSS la hace aparecer. Un flyer pesa un par
   de megas y en 4G tarda; sin esto el afiche salta de golpe cuando termina
   de bajar, y ese salto es lo que hace que la portada parezca rota el
   segundo anterior. Se revisa `complete` para los dos casos ya resueltos
   antes de que llegáramos a escuchar: el 404 cacheado (naturalWidth 0) y la
   imagen que ya estaba en memoria del que vuelve con el botón "atrás". */
function vigilarImagenes(zona) {
  zona.querySelectorAll("img").forEach(img => {
    const caer   = () => { img.remove(); };
    const llegar = () => { img.classList.add("cargada"); };
    img.addEventListener("error", caer, { once: true });
    img.addEventListener("load", llegar, { once: true });
    if (img.complete) (img.naturalWidth === 0 ? caer : llegar)();
  });
}

/* ── la entrada de las tarjetas ──
   Se revelan al entrar en pantalla y no todas juntas al cargar: con veinte
   eventos, animar los veinte de una es pagar veinte animaciones para ver
   tres. El escalonado se calcula por TANDA (la posición dentro de las que
   entran en este mismo momento) y no por posición en la lista: con el
   índice global, la tarjeta 20 esperaría un segundo entero después de
   aparecer, que se siente como que la página se colgó. */
const observador = "IntersectionObserver" in window
  ? new IntersectionObserver((entradas, obs) => {
      let n = 0;
      entradas.forEach(x => {
        if (!x.isIntersecting) return;
        x.target.style.setProperty("--i", Math.min(n++, 6));
        x.target.classList.add("vista");
        obs.unobserve(x.target);
      });
    }, { rootMargin: "0px 0px -6% 0px", threshold: 0.02 })
  : null;

function revelar(zona) {
  const piezas = zona.querySelectorAll(".evento");
  /* Sin IntersectionObserver no hay entrada escalonada, hay cartelera: se
     muestran y listo. Una animación es un lujo; ver los eventos, no. */
  if (!observador) { piezas.forEach(p => p.classList.add("vista")); return; }
  piezas.forEach(p => observador.observe(p));
}

/* ── el carrusel ──
   Se desplaza con el dedo y se engancha solo (scroll-snap): el navegador ya
   sabe hacer eso mejor que cualquier JavaScript, así que acá sólo viven los
   botones, la cuenta y el estado de los extremos. Nada avanza solo: en una
   cartelera, un carrusel que se mueve cada cinco segundos se lleva de la
   pantalla justo el evento que la persona estaba mirando. */
function cablearRail(cuantos) {
  const rail = $("#rail"), mando = $("#railMando");
  if (cuantos < 2) return;              // con una sola no hay a dónde ir
  mando.hidden = false;

  const ant = $("#railAnt"), sig = $("#railSig"), cuenta = $("#railCuenta");
  const slides = () => Array.from(rail.children);
  const sangria = () => parseFloat(getComputedStyle(rail).paddingInlineStart) || 0;

  const actual = () => {
    const x = rail.scrollLeft + sangria();
    let mejor = 0, min = Infinity;
    slides().forEach((s, i) => {
      const d = Math.abs(s.offsetLeft - x);
      if (d < min) { min = d; mejor = i; }
    });
    return mejor;
  };

  const ir = i => {
    const s = slides()[Math.max(0, Math.min(slides().length - 1, i))];
    if (!s) return;
    rail.scrollTo({ left: s.offsetLeft - sangria(),
                    behavior: quieto.matches ? "auto" : "smooth" });
  };

  const dosDig = n => String(n).padStart(2, "0");
  let pedido = false;
  const refrescar = () => {
    pedido = false;
    const i = actual();
    cuenta.textContent = `${dosDig(i + 1)} / ${dosDig(cuantos)}`;
    /* Deshabilitados de verdad y no sólo apagados: un botón que no lleva a
       ningún lado y aun así se puede pulsar enseña a desconfiar del resto. */
    ant.disabled = rail.scrollLeft <= 2;
    sig.disabled = rail.scrollLeft >= rail.scrollWidth - rail.clientWidth - 2;
  };

  ant.onclick = () => ir(actual() - 1);
  sig.onclick = () => ir(actual() + 1);
  /* rAF y no un temporizador: el scroll dispara decenas de veces por
     segundo y recalcular posiciones en cada una es lo que hace que un
     carrusel se sienta pesado justo mientras se lo está arrastrando. */
  rail.addEventListener("scroll", () => {
    if (pedido) return;
    pedido = true;
    requestAnimationFrame(refrescar);
  }, { passive: true });
  window.addEventListener("resize", refrescar);
  refrescar();
}

/* ── abrir un evento ──
   La tarjeta se despega y la página se va con ella. Dura menos que un
   parpadeo a propósito: una transición de salida que se nota es una demora
   disfrazada, y lo que la persona quiere es la página de compra.

   Todo el manejo está lleno de puertas de salida porque acá una animación
   que falla no arruina un efecto, deja a alguien sin poder comprar: si es
   un clic con Cmd/Ctrl (abrir en otra pestaña), con el botón del medio, o
   si la persona pidió menos movimiento, no se toca nada y el link es un
   link. Y el `setTimeout` navega pase lo que pase con la animación. */
function cablearSalida() {
  document.addEventListener("click", ev => {
    if (ev.defaultPrevented || ev.button !== 0) return;
    if (ev.metaKey || ev.ctrlKey || ev.shiftKey || ev.altKey) return;
    if (quieto.matches) return;
    const a = ev.target.closest("a.evento, a.destacado");
    if (!a || !a.href) return;
    ev.preventDefault();
    a.classList.add("saliendo");
    document.body.classList.add("yendo");
    setTimeout(() => { location.href = a.href; }, 190);
  });

  /* Al volver con el botón "atrás", el navegador puede devolver la página
     tal cual quedó — o sea, a medio desvanecer. Sin esto, la cartelera
     vuelve en gris y parece rota. */
  window.addEventListener("pageshow", () => {
    document.body.classList.remove("yendo");
    document.querySelectorAll(".saliendo").forEach(n => n.classList.remove("saliendo"));
  });
}

function contar(n) {
  $("#rotuloCuenta").textContent = n === 1 ? "1 evento" : `${n} eventos`;
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

  /* Cuánto se destaca depende de cuánto hay, porque destacar la mitad de la
     cartelera no es destacar nada. Hasta cinco eventos sube uno solo —el más
     próximo— y el resto va a la grilla. De seis para arriba se arma el
     carrusel, y nunca con más de un tercio de lo que está en venta (tope
     cinco): el carrusel es una vidriera, no el catálogo.

     Ahí sí la grilla repite todo, incluido lo que ya salió arriba. No es un
     descuido: son dos cosas distintas y se leen distinto. Arriba está lo que
     pasa primero; abajo está todo, que es lo que hace que se pueda ir a
     buscar un evento puntual sin tener que pasar el carrusel. */
  const muchos = eventos.length >= 6;
  const arriba = eventos.slice(0, muchos ? Math.min(5, Math.ceil(eventos.length / 3)) : 1);
  const abajo  = muchos ? eventos : eventos.slice(1);

  const rail = $("#rail");
  rail.innerHTML = arriba.map(destacado).join("");
  rail.classList.toggle("solo", arriba.length === 1);
  vigilarImagenes(rail);
  $("#proximos").hidden = false;
  cablearRail(arriba.length);

  if (!abajo.length) {
    /* Un solo evento: la grilla entera se va. Una cuadrícula con un elemento
       —o peor, con el mismo que acaba de aparecer arriba en grande— se lee
       como una página a la que le falta algo. */
    $("#cartelera").hidden = true;
    return;
  }

  $("#rotuloTxt").textContent = muchos ? "Toda la cartelera" : "También a la venta";
  contar(abajo.length);
  grilla.innerHTML = conMeses(abajo);
  vigilarImagenes(grilla);
  revelar(grilla);
}

cablearSalida();
pintar();
})();
