/* ══════════════════════════════════════════════════════════════════
   TICKETAZO — las dos páginas comerciales

   Un archivo para /organizadores y /presentacion. Lo que hace:
   1. pone el contacto en todos los botones desde UN solo lugar,
   2. hace aparecer las secciones al llegar,
   3. y en el deck, mueve el índice y la barra de progreso.
   ══════════════════════════════════════════════════════════════════ */

/* ⚠ LO ÚNICO QUE HAY QUE CAMBIAR ACÁ.
   `wa` va sin +, sin espacios y sin guiones: es lo que pide wa.me.
   Si queda vacío, los botones de WhatsApp se esconden solos en vez de
   mandar a un número que no existe — un botón roto en una presentación
   comercial cuesta más que un botón de menos. */
const CONTACTO = {
  wa: "59170000000",                 // ← reemplazar por el número real
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
