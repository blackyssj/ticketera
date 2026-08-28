/* ══════════════════════════════════════════════════════════════════
   La puerta: escanear entradas en la fila.

   Vive aparte de admin.js porque no se parece a ninguna otra pantalla.
   Las demás son formularios y listas: se cargan, se leen, se guardan.
   Ésta enciende una cámara, corre un bucle de video a ~8 lecturas por
   segundo y tiene su propia máquina de estados — la cámara prendida, la
   llamada en vuelo, el último código, la ventana de deshacer. Metida
   adentro de admin.js todo eso convive con el CRUD de eventos y el
   primer bug es una cámara que queda prendida al cambiar de pestaña.

   Igual que admin.js: acá NO hay seguridad. Los permisos los pone la
   base — validar_entrada(), marcar_filtro_entrada() y
   descheckin_entrada() exigen `es_portero() or puede_editar()` adentro,
   y `entradas` no tiene update para authenticated. Lo de acá es
   ergonomía de puerta.

   ── las tres cosas que en una puerta no son opcionales ──

   1. ANTIRREBOTE. jsQR sobre el video lee el mismo QR veinte veces por
      segundo. Eso tiene que llamar a la base UNA vez: el primer escaneo
      consume la entrada y los diecinueve siguientes contestarían
      'usada'. El portero vería rojo en una entrada que acaba de dejar
      pasar, y a los tres minutos deja de mirar la pantalla.

   2. LA CÁMARA FALLA. Sin permiso, sin cámara, o en un navegador que no
      la da. La fila no espera a que alguien resuelva un permiso: la
      pantalla lo dice y el campo para tipear el código está siempre,
      no aparece recién cuando algo se rompe.

   3. SE VE DE LEJOS Y SIN LEER. Verde grande que pasa, rojo grande que
      no. El nombre y el motivo abajo, para el que quiera mirar. Y un
      sonido corto distinto para cada uno: en una puerta con música el
      portero no mira la pantalla en cada escaneo.
   ══════════════════════════════════════════════════════════════════ */
(() => {
"use strict";

const { sb, avisar, esc } = window.ADMIN;
const $ = s => document.querySelector(s);

/* La ventana del antirrebote se REINICIA con cada avistaje, no se cuenta
   desde la llamada. Con un plazo fijo desde la llamada, un QR apoyado en
   el mostrador dispara de nuevo apenas vence y vuelve a hacer la cuenta
   que este número existe para evitar. Reiniciándola, un código que sigue
   frente a la cámara nunca se repite: recién se vuelve a poder escanear
   cuando desapareció del cuadro por este tiempo. */
const REBOTE_MS = 2500;

/* Cada cuánto se le pasa el cuadro a jsQR. A 60fps es trabajo tirado —
   nadie mueve un QR tan rápido — y el teléfono se calienta antes de la
   una de la mañana. */
const LECTURA_MS = 120;

/* Cuánto queda el cartel antes de volver a mostrar la cámara. */
const CARTEL_MS = 3800;

const P = {
  gen: 0,             // invalida bucles viejos (ver apagar())
  eventos: [],
  evento: null,
  stream: null,
  video: null,
  lienzo: null,
  ctx: null,
  raf: null,
  tLectura: 0,
  ultimo: { code: null, visto: 0 },   // el antirrebote
  ocupado: false,                     // una llamada a la base a la vez
  tCartel: null,
};

/* ── el sonido ──────────────────────────────────────────────────
   Un oscilador y dos tonos. Sube el que pasa, baja el que no: la
   dirección se reconoce sin aprenderla, que es de lo que se trata a las
   dos de la mañana con la música encima. Nada de archivos ni de CDN —
   un mp3 que no cargó es un portero que cree que el escáner no leyó.

   AudioContext no arranca sin un gesto del usuario. No se fuerza: se
   crea en el primer clic (encender la cámara, mandar un código) y si el
   navegador igual lo rechaza, la puerta sigue andando muda. */
let audio = null;

function despertarAudio() {
  try {
    const AC = window.AudioContext || window.webkitAudioContext;
    if (!AC) return;
    audio = audio || new AC();
    if (audio.state === "suspended") audio.resume();
  } catch { /* sin audio se trabaja igual */ }
}

function sonar(pasa) {
  try {
    if (!audio) return;
    const t0 = audio.currentTime;
    const largo = pasa ? 0.20 : 0.42;
    const g = audio.createGain();
    const o = audio.createOscillator();
    o.type = pasa ? "sine" : "square";
    o.connect(g); g.connect(audio.destination);
    if (pasa) { o.frequency.setValueAtTime(760, t0);
                o.frequency.setValueAtTime(1240, t0 + 0.085); }
    else      { o.frequency.setValueAtTime(320, t0);
                o.frequency.setValueAtTime(170, t0 + 0.16); }
    /* Rampas exponenciales y no un on/off: un cuadrado que empieza y
       termina de golpe hace un "click" que tapa el tono. */
    g.gain.setValueAtTime(0.0001, t0);
    g.gain.exponentialRampToValueAtTime(pasa ? 0.28 : 0.34, t0 + 0.012);
    g.gain.exponentialRampToValueAtTime(0.0001, t0 + largo);
    o.start(t0); o.stop(t0 + largo + 0.02);
  } catch { /* idem */ }
}

/* ── el payload ─────────────────────────────────────────────────
   `EVT:<evento>:<code>`, el mismo de Bowie y BurTown, así que el
   escáner de allá lee estas entradas y viceversa.

   Si el evento no es el activo se rechaza acá, sin llamar a la base: es
   una entrada de otra noche y no hay nada que preguntar. Preguntarlo
   igual sería una llamada por cada QR viejo que alguien tenga guardado
   en el teléfono, y todas con la misma respuesta. */
const RE_PAYLOAD = /^EVT:([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}):([0-9A-Z]{4,32})$/i;

function leerPayload(txt) {
  const m = RE_PAYLOAD.exec(String(txt || "").trim());
  return m ? { evento: m[1].toLowerCase(), code: m[2].toUpperCase() } : null;
}

/* ── los carteles ───────────────────────────────────────────────
   El título es lo único que se lee de lejos, así que dice qué hacer y
   no qué pasó: "PASA" y "NO PASA", no "válida" y "usada". El motivo va
   abajo, en chico, para la discusión de los treinta segundos siguientes.

   `usada` y `anulada` no comparten cartel a propósito: una existió y
   alguien la dio de baja —hay a quién llamar— y la otra ya entró. Son
   dos conversaciones distintas. */
const CARTELES = {
  valida:      { cls: "pasa", titulo: "PASA" },
  usada:       { cls: "no",   titulo: "YA ENTRÓ" },
  anulada:     { cls: "no",   titulo: "ANULADA" },
  no_existe:   { cls: "no",   titulo: "NO EXISTE" },
  otro_evento: { cls: "no",   titulo: "OTRA NOCHE" },
  ajeno:       { cls: "no",   titulo: "NO ES UNA ENTRADA" },
  error:       { cls: "no",   titulo: "NO SE PUDO" },
};

const hora = t => {
  if (!t) return "";
  const d = new Date(t);
  return isNaN(d) ? "" : d.toLocaleTimeString("es-BO",
    { hour: "2-digit", minute: "2-digit", hour12: false });
};

/* ── la pantalla ────────────────────────────────────────────────── */
async function pantalla() {
  apagar();                     // por si se vuelve a entrar sin recargar
  const gen = P.gen;

  $("#main").innerHTML = `<p class="cargando">Buscando el evento…</p>`;

  /* Se acota del lado del servidor: PostgREST corta en 1000 filas sin
     avisar y un organizador con años de historia dejaría al portero sin
     el evento de esta noche. Un borrador no se puede comprar, así que
     no puede haber nadie en su puerta. */
  const { data, error } = await sb.from("eventos")
    .select("id,nombre,fecha,estado")
    .in("estado", ["publicado", "cerrado"])
    .order("fecha", { ascending: false })
    .limit(50);
  if (gen !== P.gen) return;    // se cambió de pestaña mientras cargaba

  if (error) {
    $("#main").innerHTML = `<p class="error">No se pudieron cargar los eventos: ${esc(error.message)}</p>`;
    return;
  }
  P.eventos = data || [];
  if (!P.eventos.length) {
    $("#main").innerHTML = `<p class="vacio">No hay ningún evento a la venta.
      Cuando el organizador publique uno, la puerta abre acá.</p>`;
    return;
  }
  if (!P.evento || !P.eventos.some(e => e.id === P.evento.id))
    P.evento = elegirEvento(P.eventos);

  dibujar();
  arrancarCamara();
}

/* El de esta noche es el primero que todavía no pasó. La lista viene
   descendente, así que el más cercano es el último de los que quedan
   adelante; si ya pasaron todos, el más reciente. El portero puede
   cambiarlo, pero abrir en el evento equivocado y no darse cuenta es
   una noche entera de entradas quemadas contra la fecha que no era. */
function elegirEvento(lista) {
  const hoy = new Date().toLocaleDateString("en-CA");   // AAAA-MM-DD local
  const adelante = lista.filter(e => e.fecha >= hoy);
  return adelante.length ? adelante[adelante.length - 1] : lista[0];
}

function dibujar() {
  $("#main").innerHTML = `
    <div class="puerta" id="puerta">
      <div class="puerta-cab">
        <h2>Puerta</h2>
        <label class="puerta-evento">
          <span>Evento</span>
          <select id="pEvento">${P.eventos.map(e =>
            `<option value="${e.id}"${e.id === P.evento.id ? " selected" : ""}
              >${esc(e.nombre)} · ${esc(e.fecha)}</option>`).join("")}</select>
        </label>
      </div>

      <div class="puerta-visor">
        <video id="pVideo" playsinline muted autoplay></video>
        <div class="puerta-mira" aria-hidden="true"></div>
        <div class="puerta-camara" id="pCamara"></div>
        <div class="puerta-cartel" id="pCartel" role="status" aria-live="assertive"></div>
      </div>

      <form class="puerta-mano" id="pFormMano" autocomplete="off">
        <label>
          <span>Código a mano</span>
          <input id="pCodigo" inputmode="latin" autocapitalize="characters"
                 autocorrect="off" spellcheck="false" maxlength="32"
                 placeholder="Ej. 7KMQ3BFHD2XW">
        </label>
        <button class="btn primario" id="pBuscar">Buscar</button>
      </form>
      <p class="ayuda">El QR se lee solo. El código a mano es para cuando la
        pantalla del cliente no ilumina o el QR está roto.</p>
    </div>`;

  $("#pEvento").onchange = e => {
    P.evento = P.eventos.find(x => x.id === e.target.value) || P.evento;
    P.ultimo = { code: null, visto: 0 };     // otro evento, otro rebote
    ocultarCartel();
  };

  $("#pFormMano").onsubmit = ev => {
    ev.preventDefault();
    despertarAudio();
    const code = $("#pCodigo").value.trim().toUpperCase();
    if (!code) return;
    $("#pCodigo").value = "";
    /* A mano no pasa por el antirrebote: si alguien tipea el mismo
       código dos veces es porque quiere preguntar de nuevo. Sí marca el
       último visto, para que la cámara no lo vuelva a disparar sola. */
    resolver(code, { aMano: true });
  };

  P.video  = $("#pVideo");
  P.lienzo = document.createElement("canvas");
  P.ctx    = P.lienzo.getContext("2d", { willReadFrequently: true });
}

/* ── la cámara ──────────────────────────────────────────────────
   Todo lo que puede salir mal acá termina en el mismo lugar: un cartel
   que dice qué pasó y el campo de a mano, que ya está abajo. No hay
   pantalla de error que tape el trabajo. */
async function arrancarCamara() {
  const gen = P.gen;
  const caja = $("#pCamara");
  if (!caja) return;

  if (!window.jsQR) return fallaCamara(
    "No cargó el lector de QR (jsQR). Revisá la conexión y recargá.");

  /* getUserMedia no existe fuera de contexto seguro. Pasa de verdad: el
     teléfono conectado al wifi del boliche abriendo http://192.168.x.x
     no tiene cámara y el navegador no dice por qué. */
  if (!navigator.mediaDevices || !navigator.mediaDevices.getUserMedia)
    return fallaCamara(window.isSecureContext === false
      ? "La cámara solo funciona sobre https. Abrí el panel con la dirección https y volvé a entrar."
      : "Este navegador no da acceso a la cámara.");

  caja.innerHTML = `<p class="puerta-aviso">Pidiendo la cámara…</p>`;
  caja.dataset.on = "1";

  let stream;
  try {
    /* `ideal` y no `exact`: con exact, un teléfono sin cámara trasera
       tira OverconstrainedError y se queda sin ninguna, cuando la
       frontal alcanza para leer un QR. */
    stream = await navigator.mediaDevices.getUserMedia({
      audio: false,
      video: { facingMode: { ideal: "environment" },
               width:  { ideal: 1280 },
               height: { ideal: 720 } },
    });
  } catch (err) {
    return fallaCamara(motivoCamara(err));
  }
  if (gen !== P.gen) { stream.getTracks().forEach(t => t.stop()); return; }

  P.stream = stream;
  P.video.srcObject = stream;
  try { await P.video.play(); } catch { /* autoplay: el muted ya lo cubre */ }
  if (gen !== P.gen) return apagar();

  caja.dataset.on = "0";
  caja.innerHTML = "";
  P.tLectura = 0;
  P.raf = requestAnimationFrame(() => bucle(gen));
}

function motivoCamara(err) {
  const n = err && err.name;
  if (n === "NotAllowedError" || n === "SecurityError")
    return "Falta el permiso de la cámara. Dáselo desde el candado de la barra de direcciones y tocá «Reintentar».";
  if (n === "NotFoundError" || n === "DevicesNotFoundError")
    return "Este equipo no tiene cámara.";
  if (n === "NotReadableError" || n === "TrackStartError")
    return "La cámara está ocupada por otra aplicación. Cerrala y tocá «Reintentar».";
  if (n === "OverconstrainedError")
    return "No hay una cámara que sirva en este equipo.";
  return (err && err.message) || "No se pudo abrir la cámara.";
}

/* No es una pantalla de error: es la pantalla normal sin cámara. El
   campo de a mano sigue abajo y funciona igual, así que la fila avanza
   mientras alguien se pelea con el permiso. */
function fallaCamara(txt) {
  const caja = $("#pCamara");
  if (!caja) return;
  caja.dataset.on = "1";
  caja.innerHTML = `
    <p class="puerta-aviso">${esc(txt)}</p>
    <p class="puerta-aviso tenue">Mientras tanto, escribí el código abajo: hace exactamente lo mismo.</p>
    <button type="button" class="btn plano chico" id="pReintentar">Reintentar</button>`;
  const b = $("#pReintentar");
  if (b) b.onclick = () => { despertarAudio(); arrancarCamara(); };
  const inp = $("#pCodigo");
  if (inp) inp.focus();
}

/* ── el bucle ───────────────────────────────────────────────────
   `gen` es lo que evita dos bucles vivos. Cambiar de pestaña reemplaza
   el #main entero: el <video> queda huérfano y el bucle seguiría
   corriendo contra un nodo suelto, con la cámara prendida y el led
   encendido en un teléfono que alguien dejó sobre la barra. Cada vuelta
   comprueba las dos cosas — su generación y que el nodo siga en la
   página — y se apaga solo. Así admin.js no necesita saber que existe
   una cámara que apagar. */
function bucle(gen) {
  if (gen !== P.gen) return;
  if (!P.video || !document.body.contains(P.video)) return apagar();
  P.raf = requestAnimationFrame(() => bucle(gen));

  const ahora = performance.now();
  if (ahora - P.tLectura < LECTURA_MS) return;
  P.tLectura = ahora;

  const v = P.video;
  if (v.readyState < 2 || !v.videoWidth) return;

  /* Se le pasa a jsQR el cuadrado del centro, que es donde está la mira.
     Analizar los 1280×720 enteros cuesta el doble y encima encuentra el
     QR del que está atrás en la fila. */
  const lado = Math.min(v.videoWidth, v.videoHeight);
  const dest = Math.min(lado, 640);
  if (P.lienzo.width !== dest) { P.lienzo.width = dest; P.lienzo.height = dest; }
  P.ctx.drawImage(v, (v.videoWidth - lado) / 2, (v.videoHeight - lado) / 2,
                  lado, lado, 0, 0, dest, dest);

  let img;
  try { img = P.ctx.getImageData(0, 0, dest, dest); }
  catch { return; }            // canvas manchado: no debería pasar, no se cae

  /* dontInvert: el QR de la entrada es negro sobre blanco (ticket.js
     dibuja la caja en #fff). Probar también el invertido duplica el
     costo de cada cuadro para leer un QR que no emitimos. */
  const r = window.jsQR(img.data, dest, dest, { inversionAttempts: "dontInvert" });
  if (r && r.data) mirar(r.data);
}

/* ── el antirrebote ─────────────────────────────────────────────
   Dos candados, y hacen falta los dos. `ocupado` es el duro: mientras
   hay una llamada en vuelo no sale ninguna otra, así que ni un bug de
   tiempos puede consumir dos veces. `ultimo` es el que hace que un QR
   quieto frente a la cámara sea UNA llamada y no una cada dos segundos:
   la ventana se corre con cada avistaje, así que el código recién se
   vuelve a poder leer cuando salió del cuadro. */
function mirar(payload) {
  if (P.ocupado) return;

  const d = leerPayload(payload);
  const clave = d ? d.code : "?" + payload;
  const ahora = Date.now();
  const repetido = P.ultimo.code === clave && ahora - P.ultimo.visto < REBOTE_MS;
  P.ultimo.code = clave;
  P.ultimo.visto = ahora;
  if (repetido) return;

  if (!d) return mostrarCartel({ resultado: "ajeno" });
  if (d.evento !== String(P.evento.id).toLowerCase())
    return mostrarCartel({ resultado: "otro_evento", code: d.code });

  resolver(d.code, {});
}

/* ── la llamada ─────────────────────────────────────────────────
   Un solo camino para la cámara y para el teclado: misma función de la
   base, mismo cartel, mismo sonido. Dos caminos es cómo uno de los dos
   se queda sin el antirrebote o sin el conteo. */
async function resolver(code, { aMano }) {
  if (P.ocupado) return;
  P.ocupado = true;
  P.ultimo.code = code;
  P.ultimo.visto = Date.now();

  try {
    const { data, error } = await sb.rpc("validar_entrada",
      { p_evento: P.evento.id, p_code: code });
    if (error) {
      mostrarCartel({ resultado: "error", code, motivo: error.message });
      return;
    }
    mostrarCartel(data || { resultado: "no_existe", code });
    if (aMano) $("#pCodigo") && $("#pCodigo").focus();
  } catch (err) {
    /* Sin señal la puerta no puede decidir. Se dice así, no con un
       cartel rojo de "no existe": la entrada puede estar perfecta y el
       portero tiene que saber que el problema es el wifi. */
    mostrarCartel({ resultado: "error", code,
                    motivo: (err && err.message) || "sin conexión" });
  } finally {
    /* La ventana del rebote se cuenta desde que VOLVIÓ la respuesta. Si
       la base tardó dos segundos, contarla desde antes la deja casi
       vencida y el mismo QR dispara de nuevo. */
    P.ultimo.visto = Date.now();
    P.ocupado = false;
  }
}

/* ── el cartel ──────────────────────────────────────────────────
   Tapa la cámara mientras dura, pero el bucle sigue corriendo abajo: si
   llega el siguiente de la fila, el cartel se reemplaza y no hay que
   esperar a que se vaya. */
function mostrarCartel(r) {
  const caja = $("#pCartel");
  if (!caja) return;
  const c = CARTELES[r.resultado] || CARTELES.error;
  const pasa = c.cls === "pasa";

  const detalle = [];
  if (r.cliente) detalle.push(`<strong>${esc(r.cliente)}</strong>`);
  if (r.tipo)    detalle.push(esc(r.tipo));

  let motivo = "";
  if (r.resultado === "usada")
    motivo = `Entró a las ${esc(hora(r.used_at)) || "—"}.`;
  else if (r.resultado === "anulada")
    motivo = "La dieron de baja. No pasa.";
  else if (r.resultado === "no_existe")
    motivo = "Ese código no existe en este evento.";
  else if (r.resultado === "otro_evento")
    motivo = "Es de otra fecha, no de este evento.";
  else if (r.resultado === "ajeno")
    motivo = "Ese QR no es una entrada.";
  else if (r.resultado === "error")
    motivo = esc(r.motivo || "Probá de nuevo.");

  caja.className = `puerta-cartel ${c.cls}`;
  caja.dataset.on = "1";
  caja.innerHTML = `
    <span class="puerta-titulo">${c.titulo}</span>
    ${detalle.length ? `<span class="puerta-quien">${detalle.join(" · ")}</span>` : ""}
    ${motivo ? `<span class="puerta-motivo">${motivo}</span>` : ""}
    ${r.code ? `<span class="puerta-code">#${esc(r.code)}</span>` : ""}`;

  sonar(pasa);
  clearTimeout(P.tCartel);
  P.tCartel = setTimeout(ocultarCartel, CARTEL_MS);
}

function ocultarCartel() {
  clearTimeout(P.tCartel);
  const caja = $("#pCartel");
  if (caja) { caja.dataset.on = "0"; caja.innerHTML = ""; }
}

/* Apaga TODO: bucle, cámara y relojes. Subir `gen` invalida cualquier
   bucle que ya esté encolado en el requestAnimationFrame siguiente. */
function apagar() {
  P.gen++;
  if (P.raf) { cancelAnimationFrame(P.raf); P.raf = null; }
  clearTimeout(P.tCartel);
  if (P.stream) { P.stream.getTracks().forEach(t => t.stop()); P.stream = null; }
  if (P.video) { P.video.srcObject = null; P.video = null; }
  P.ocupado = false;
  P.ultimo = { code: null, visto: 0 };
}

/* Un teléfono bloqueado con la pantalla prendida y la cámara comiendo
   batería toda la noche. Al volver se reanuda sola. */
document.addEventListener("visibilitychange", () => {
  if (document.hidden && P.stream) {
    const habia = !!P.video && document.body.contains(P.video);
    apagar();
    if (habia) P.reanudar = true;
  } else if (!document.hidden && P.reanudar) {
    P.reanudar = false;
    if (document.getElementById("puerta")) pantalla();
  }
});

window.PUERTA = { pantalla, apagar };
})();
