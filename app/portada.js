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

   Y de seis para arriba aparecen además el buscador y los filtros por mes,
   porque a partir de ahí la cartelera deja de recorrerse de un vistazo y
   pasa a recorrerse a dedo. El umbral es uno solo (MUCHOS) y manda las tres
   decisiones: son la misma idea vista tres veces.
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

/* El umbral de "cartelera larga", una sola vez y para las tres decisiones
   que en realidad son la misma: el carrusel de arriba, las dos columnas del
   teléfono y el buscador. Una cartelera de veinte no es una de tres con más
   tarjetas — y hasta cinco, un buscador es un control que hay que leer para
   decidir no usarlo. */
const MUCHOS = 6;

/* Buscar como se escribe en un teléfono. Nadie tipea "Aniversario" con
   mayúscula ni "San Martín" con la tilde cuando está buscando una fiesta con
   el pulgar. NFD separa cada letra de su acento y el rango borra los acentos
   sueltos, así "san martin" encuentra "Av. San Martín". */
const plano = s => String(s ?? "").normalize("NFD")
  .replace(/[\u0300-\u036f]/g, "").toLowerCase();

/* Hoy en La Paz (UTC-4, sin horario de verano), calculado igual que en la
   Edge Function que arma la cartelera. Con la fecha local del aparato, un
   teléfono con la zona horaria en otro país diría "mañana" en el evento de
   esta noche — y eso es alguien que se queda afuera. */
const hoyLaPaz = () => new Date(Date.now() - 4 * 3600 * 1000).toISOString().slice(0, 10);

/* ── hoy y mañana, con palabras ──
   "SÁB 5 SEP" obliga a saber qué día es hoy para saber si el evento sirve.
   Es la cuenta que hace todo el mundo parado frente a una cartelera y la
   única que la página puede hacer por vos.
   Dos días y ni uno más: "en 3 días" ya no es una palabra, es otra cuenta.
   Las dos fechas se comparan a mediodía UTC —no en horas— porque lo que se
   mide son días de calendario: entre las 23:00 de hoy y la 01:00 de mañana
   hay dos horas y un día de diferencia, y lo que importa es el día. */
function cerca(fecha) {
  const a = Date.parse(`${hoyLaPaz()}T12:00:00Z`);
  const b = Date.parse(`${fecha}T12:00:00Z`);
  if (isNaN(a) || isNaN(b)) return null;
  const d = Math.round((b - a) / 86400000);
  return d === 0 ? "Hoy" : d === 1 ? "Mañana" : null;
}

/* Con `?demo=1` la cartelera sale de un archivo y no de la base. Es para
   mostrar la ticketera llena en una reunión: con un solo evento a la venta,
   la portada es honesta pero no muestra lo que la ticketera es.

   El parámetro es explícito y no un modo guardado: nadie llega acá sin el
   link, y el que lo tiene sabe qué está mirando. Y nunca escribe nada — la
   alternativa, meter eventos falsos en la base, los pondría delante de la
   gente que ahora mismo está comprando de verdad. */
const DEMO = new URLSearchParams(location.search).get("demo") === "1";

function pedirCartelera() {
  if (DEMO) {
    return Promise.resolve({ ok: true, eventos: window.DEMO_CARTELERA || [] });
  }
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
  /* El color del papel lo trae sólo la cartelera de demostración, donde no
     hay flyers: nueve carteles del mismo violeta se leen como un error de
     carga. En la cartelera real el color lo pone la imagen. */
  const tinta = e.papel
    ? ` style="--papel-a:${esc(e.papel[0])};--papel-b:${esc(e.papel[1])}"`
    : "";
  const papel = `<div class="papel"${tinta}${e.flyer_url ? ' aria-hidden="true"' : ""}>
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

/* El precio de la tarjeta. "desde 0 Bs" no es un precio, es una resta mal
   hecha: un evento gratis tiene que decir que es gratis. Y no lleva "desde"
   —lo que no cuesta nada no tiene un mínimo del que partir— así que la
   palabra cambia y la etiqueta también, con el fluor de la marca: en una
   cartelera, el único evento sin costo es el que más rápido se mira. */
function precio(e) {
  if (e.desde == null) return "";
  if (Number(e.desde) === 0) return `<span class="desde gratis"><b>Gratis</b></span>`;
  return `<span class="desde">desde <b>${esc(bs(e.desde))}</b></span>`;
}

const perf = `<div class="perf" aria-hidden="true"><i class="p1"></i><i class="p2"></i></div>`;

/* ── la tarjeta de la grilla ──
   Tres renglones en el talón y ni uno más. Es la diferencia con la
   convención local, donde la tarjeta es el flyer y un botón que dice "ver
   más": ahí hay que abrir el evento para saber qué día es. Acá la fecha se
   lee sin abrir nada, y sigue siendo el flyer el que ocupa la tarjeta.

   El nombre se repite en el talón sólo cuando arriba hay una imagen. Sin
   flyer ya está en el papel, cuatro veces más grande, y repetirlo sesenta
   píxeles más abajo es un tartamudeo, no una jerarquía.

   La fecha se arma acá con las mismas partes que la función usa para su
   `fecha_txt` —da la misma cadena— y no con `fecha_txt` mismo, para poder
   marcar la hora aparte. En una tarjeta de 134px (dos columnas en un
   teléfono chico) el renglón entero no entra y se cortaba justo en la hora:
   "SÁB 12 SEP · 2…". Marcada, el CSS la saca a ese ancho y queda la fecha
   completa, que es la que decide si el evento te sirve; la hora está a un
   toque de distancia y casi siempre impresa en el flyer. */
/* Y cuando el evento es hoy o mañana, la fecha se dice con la palabra y no
   con el número: ahí el renglón deja de ser un dato para verificar y pasa a
   ser un aviso. Sellado en fluor, como la calcomanía del afiche — es lo que
   más rápido cambia de toda la pieza. */
function cuandoTxt(e) {
  const ya = cerca(e.fecha);
  return ya ? `<b class="ya">${esc(ya)}</b>`
            : `${esc(e.dia_semana)} ${esc(e.dia)} ${esc(e.mes)}`;
}

function tarjeta(e, i) {
  const conFlyer = !!e.flyer_url;
  return `<a class="evento${e.venta === "agotado" ? " agotado" : ""}" href="${esc(e.url)}">
    ${afiche(e, i < 2)}
    ${perf}
    <div class="talon">
      <div class="cuando"><span>${cuandoTxt(e)}<i class="hora"> · ${esc(e.hora)}</i></span>
        <i class="flecha" aria-hidden="true"></i></div>
      ${conFlyer ? `<h3 class="nombre">${esc(e.nombre)}</h3>` : ""}
      <div class="pie-talon">
        <span class="donde">${esc(e.lugar)}</span>
        ${precio(e)}
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
   igual: lo que el papel ya dice, el talón no lo repite.

   La última fila es la que cambió de idea con el primer flyer real adentro.
   Un flyer boliviano imprime la fecha, la hora y el lugar en una banda
   abajo — o sea que el talón, tal como estaba, transcribía la banda del
   afiche a cuatro centímetros de distancia y encima en cuerpo de titular.
   Lo único que el flyer nunca dice es cuánto sale, y eso estaba escrito en
   11,5px gris al lado del organizador: el dato que todo el mundo pregunta
   primero, más chico que cualquier otra cosa de la pieza.

   Así que el precio se muda a la fila de la acción, al lado de la manera de
   entrar, que es donde en una entrada de papel se imprime lo que se pagó.
   La fecha sigue siendo el número grande y no se lo cede: es la convención
   del talón, y el que compra guarda la entrada por la fecha. */
function destacado(e, i) {
  /* Acá el día del mes ya está en el `fechon`, así que lo que reemplaza la
     palabra no es la fecha entera sino el día de la semana: "HOY · 22:00"
     arriba del 5 en fluor, que es la misma información contada dos veces
     bien — primero para decidir, después para guardar. */
  const ya = cerca(e.fecha);
  return `<a class="destacado${e.venta === "agotado" ? " agotado" : ""}" href="${esc(e.url)}">
    ${afiche(e, i === 0)}
    ${perf}
    <div class="talon">
      <span class="cuando">${ya ? `<b class="ya">${esc(ya)}</b>` : esc(e.dia_semana)} · ${esc(e.hora)}</span>
      <div class="fechon"><b>${esc(e.dia)}</b><span>${esc(MESES[Number(e.fecha.slice(5, 7)) - 1] || e.mes)}</span></div>
      ${e.flyer_url ? `<h3 class="nombre">${esc(e.nombre)}</h3>` : ""}
      <p class="donde">${esc(e.lugar)}</p>
      ${e.flyer_url ? `<span class="quien">${esc(e.organizador_nombre)}</span>` : ""}
      <div class="accion">
        <span class="ver" aria-hidden="true">Ver entradas<i class="flecha"></i></span>
        ${precio(e)}
      </div>
    </div>
  </a>`;
}

const claveMes = e => e.fecha.slice(0, 7);

/* El rótulo del mes, con el año sólo cuando NO es este. "diciembre" y
   "diciembre 2027" en la misma cartelera es la diferencia entre la fiesta
   de este fin de año y la del que viene. */
function rotuloMes(clave) {
  const mes = MESES[Number(clave.slice(5, 7)) - 1] || clave;
  const anio = clave.slice(0, 4);
  return anio === String(new Date().getFullYear()) ? mes : `${mes} ${anio}`;
}

/* Los separadores de mes se dibujan TODOS y después se decide cuál se ve.
   Antes la decisión se tomaba acá, al armar el HTML, y con el buscador eso
   dejó de alcanzar: filtrando por "bowie" pueden quedar dos eventos de
   octubre colgando de una cabecera de septiembre que se quedó dibujada, o
   un "septiembre" solo arriba de todo separando una cosa de nada.
   Nacen ocultos para que no parpadeen antes de que `acomodarMeses` opine. */
function conMeses(lista) {
  let ultimo = null;
  return lista.map((e, i) => {
    const clave = claveMes(e);
    let cabeza = "";
    if (clave !== ultimo) {
      ultimo = clave;
      cabeza = `<h3 class="mes" data-mes="${esc(clave)}" hidden>${esc(rotuloMes(clave))}</h3>`;
    }
    return cabeza + tarjeta(e, i);
  }).join("");
}

/* Un rótulo de mes sólo separa si hay algo del otro lado. Con todo lo que
   se ve en septiembre —porque la cartelera es corta, o porque el filtro
   dejó un mes solo— la palabra "septiembre" arriba de todo es una línea que
   hay que leer y descartar. Es la misma regla de siempre, ahora aplicada a
   lo que quedó a la vista y no a lo que se dibujó. */
function acomodarMeses(zona, visibles) {
  const cruza = visibles.size > 1;
  zona.querySelectorAll(".mes").forEach(h => {
    h.hidden = !cruza || !visibles.has(h.dataset.mes);
  });
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
let entrego = false;   // ¿el observer llegó a entregar alguna vez?

const observador = "IntersectionObserver" in window
  ? new IntersectionObserver((entradas, obs) => {
      entrego = true;
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

  /* Y la misma regla vale cuando el observer existe pero no entrega. Pasa:
     una pestaña abierta en segundo plano no dispara IntersectionObserver, y
     como las tarjetas nacen invisibles, la cartelera queda en blanco hasta
     que alguien la mire — que es justo cuando ya la dio por rota. A segundo
     y medio sin una sola entrega, se muestran todas. */
  setTimeout(() => {
    if (!entrego) piezas.forEach(p => p.classList.add("vista"));
  }, 1500);
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

/* La cuenta del rótulo. Con un filtro puesto dice de cuántos: "3 de 14
   eventos". Sin el total, un "3 eventos" después de tipear se lee como una
   cartelera que se achicó sola, y no como una búsqueda que encontró tres. */
function contar(n, total) {
  $("#rotuloCuenta").textContent = total
    ? `${n} de ${total} eventos`
    : (n === 1 ? "1 evento" : `${n} eventos`);
}

/* ── la puerta a "mis entradas" ──
   Aparece sólo si hay algo del otro lado, y por eso la barra la trae oculta.
   El localStorage lo escribe otra página: puede tener basura de una versión
   vieja, de otra pestaña o de nadie, así que se lee sin confiar. Un
   JSON.parse que explota acá dejaría la portada entera sin pintar —y hasta
   `localStorage` mismo tira en el modo privado de Safari—, así que el
   try/catch envuelve las dos cosas y la respuesta de la duda es cero. */
function comprasGuardadas() {
  try {
    const x = JSON.parse(localStorage.getItem("ticketazo.compras") || "[]");
    return Array.isArray(x) ? x.length : 0;
  } catch { return 0; }
}

function abrirPuerta() {
  const n = comprasGuardadas();
  if (!n) return;
  $("#misCuenta").textContent = String(n);
  $("#misEntradas").hidden = false;
  /* La barra avisa que ahora tiene dos cosas: en el tramo angosto donde la
     ciudad y el acceso no entran juntos, el CSS calla la ciudad. Sin compras
     guardadas esta clase no se pone nunca y la barra queda como estaba. */
  $(".barra-in").classList.add("con-mis");
}

/* ── buscar y filtrar ──
   Sólo con la cartelera larga (MUCHOS). Y no repinta la grilla: esconde y
   muestra las tarjetas que ya están. Repintar con innerHTML en cada tecla
   volvería a crear los <img>, y con flyers de verdad eso es la cartelera
   entera parpadeando mientras se escribe — el navegador los tiene en caché,
   pero un elemento nuevo arranca vacío igual. Esconder es instantáneo y
   además conserva las que ya se revelaron.

   Nada de "buscar" con un botón: son veinte eventos en memoria, filtrar es
   comparar veinte cadenas, y hacerle apretar Enter a alguien para eso es
   pedirle una ceremonia por un trabajo que ya está hecho. */
function cablearFiltros(lista, grilla) {
  const campo = $("#busca"), borrar = $("#buscaX");
  const meses = $("#meses"), vacio = $("#sinNada");
  const piezas = Array.from(grilla.querySelectorAll(".evento"));

  /* El índice se arma una vez. Normalizar tres campos de veinte eventos en
     cada tecla es hacer sesenta veces el mismo trabajo por letra tipeada.
     Van los tres que alguien usa para buscar una fiesta: cómo se llama,
     quién la hace y dónde es. En Santa Cruz el lugar es la mitad de lo que
     dice qué clase de noche es, así que "equipetrol" tiene que encontrar. */
  const indice = lista.map(e =>
    plano(`${e.nombre} ${e.organizador_nombre} ${e.lugar}`));

  /* Los meses salen de la cartelera, en el orden en que llegan —que ya es
     cronológico— y no de un calendario: un botón "noviembre" sin nada
     detrás es una puerta a un cuarto vacío. */
  const claves = [];
  lista.forEach(e => {
    const k = claveMes(e);
    if (claves.indexOf(k) < 0) claves.push(k);
  });

  meses.innerHTML =
    `<button type="button" class="chip activo" data-mes="" aria-pressed="true">Todos</button>` +
    claves.map(k => `<button type="button" class="chip" data-mes="${esc(k)}"` +
      ` aria-pressed="false">${esc(rotuloMes(k))}</button>`).join("");
  /* Con un mes solo, los filtros serían "Todos" y "septiembre": dos botones
     que llevan al mismo lugar. La misma regla que el corte de mes. */
  if (claves.length < 2) meses.hidden = true;

  let texto = "", mes = "";

  const aplicar = () => {
    const visibles = new Set();
    let n = 0;
    lista.forEach((e, i) => {
      const pasa = (!texto || indice[i].indexOf(texto) >= 0)
                && (!mes || claveMes(e) === mes);
      piezas[i].hidden = !pasa;
      if (pasa) { n++; visibles.add(claveMes(e)); }
    });
    acomodarMeses(grilla, visibles);
    vacio.hidden = n > 0;
    borrar.hidden = !texto;
    contar(n, (texto || mes) ? lista.length : 0);
  };

  campo.addEventListener("input", () => {
    texto = plano(campo.value.trim());
    aplicar();
  });
  /* Devolver el foco al campo y no dejarlo en un botón que se acaba de
     esconder: sin esto el foco se cae al <body> y el teclado del teléfono
     se cierra justo cuando la persona iba a escribir de nuevo. */
  borrar.addEventListener("click", () => {
    campo.value = ""; texto = ""; campo.focus(); aplicar();
  });

  meses.addEventListener("click", ev => {
    const b = ev.target.closest(".chip");
    if (!b) return;
    mes = b.dataset.mes;
    meses.querySelectorAll(".chip").forEach(c => {
      const puesto = c === b;
      c.classList.toggle("activo", puesto);
      c.setAttribute("aria-pressed", puesto ? "true" : "false");
    });
    aplicar();
  });

  /* El botón del cartel vacío limpia LAS DOS COSAS. Es el único lugar de la
     página donde alguien está mirando una pared en blanco, y ahí un botón
     que deshace la mitad del filtro la deja igual de vacía. */
  $("#sinNadaBtn").addEventListener("click", () => {
    campo.value = ""; texto = ""; mes = "";
    meses.querySelectorAll(".chip").forEach((c, i) => {
      c.classList.toggle("activo", i === 0);
      c.setAttribute("aria-pressed", i === 0 ? "true" : "false");
    });
    aplicar();
    campo.focus();
  });

  $("#filtros").hidden = false;
  aplicar();
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
  const muchos = eventos.length >= MUCHOS;
  const arriba = eventos.slice(0, muchos ? Math.min(5, Math.ceil(eventos.length / 3)) : 1);
  const abajo  = muchos ? eventos : eventos.slice(1);

  const rail = $("#rail");
  rail.innerHTML = arriba.map(destacado).join("");
  rail.classList.toggle("solo", arriba.length === 1);
  /* Con un solo evento en venta, "Lo próximo" no separa nada de nada: no hay
     un "después" con el que contraste. Es un renglón que hay que leer y
     descartar, y en el teléfono son 40px que le come al afiche justo en la
     primera pantalla — que es donde casi todos llegan, por WhatsApp. Se
     calla, no se borra: el h2 sigue en el árbol para quien navega la página
     por encabezados. */
  $("#proximosRotulo").classList.toggle("muda", eventos.length === 1);
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
  /* Con la cartelera larga, en el teléfono la grilla pasa a dos columnas.
     Con una sola, veinte eventos son doce mil píxeles de scroll: no se
     recorre, se sufre. Se usa el mismo umbral que decide el carrusel porque
     es la misma idea — una cartelera de veinte no es una de tres con más
     tarjetas—, y con pocas el afiche se merece el ancho entero del teléfono
     (el CSS ignora la clase de 540px para arriba). */
  grilla.classList.toggle("densa", muchos);
  grilla.innerHTML = conMeses(abajo);
  /* Los cortes de mes nacen ocultos, así que alguien tiene que decidir
     cuáles se ven aunque nunca haya un filtro. Con la cartelera corta esto
     es todo lo que corre; con la larga, `cablearFiltros` vuelve a opinar en
     cada tecla sobre lo que quedó a la vista. */
  acomodarMeses(grilla, new Set(abajo.map(claveMes)));
  vigilarImagenes(grilla);
  revelar(grilla);
  if (muchos) cablearFiltros(abajo, grilla);
}

cablearSalida();
abrirPuerta();
pintar();
})();
