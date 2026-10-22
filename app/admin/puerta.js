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
const ESCANEO_MS = 4000;   // tope del escaneo con señal; después decide la lista local

/* Cada cuánto se le pasa el cuadro a jsQR. A 60fps es trabajo tirado —
   nadie mueve un QR tan rápido — y el teléfono se calienta antes de la
   una de la mañana. */
const LECTURA_MS = 120;

/* Cuánto queda el cartel antes de volver a mostrar la cámara. */
const CARTEL_MS = 3800;
/* El recibo de una mesa se LEE: tipo, lo que incluye, nombre, carnet y
   correo, que el guardia compara contra el carnet en la mano. En 3,8 s no
   se lee eso. Se saca antes tocándolo, como cualquier cartel. */
const CARTEL_RECIBO_MS = 12000;

/* El recibo de una mesa (0108) lleva un código que empieza con MESA. Los
   de las entradas salen de un alfabeto sin vocales, así que nunca empiezan
   así: con mirar el código ya se sabe que no es una entrada, con señal o
   sin ella. El QR es el mismo EVT:<evento>:<code>. */
const esRecibo = code => /^MESA/.test(String(code || ""));

/* Cuánto dura el botón de deshacer. Corto a propósito: deshacer sirve para
   el error que se acaba de cometer y se vio. Una lista de ingresos con un
   botón de deshacer al lado de cada uno es otra cosa — es una puerta
   trasera para entrar dos veces con la misma manilla, y no se pide permiso
   para usarla porque el permiso ya está dado. */
const VENTANA_DESHACER_MS = 20000;

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
  filtro: false,                      // ver el bloque "modo filtro"
  deshacer: null,                     // solo el ÚLTIMO ingreso, y por poco
  /* Lo de trabajar sin señal (ver el bloque "la puerta sin señal"). */
  padron: null,       // la lista bajada, tal cual la devolvió la base
  ix: null,           // code -> entrada, para no recorrer la lista por QR
  rx: null,           // code -> recibo de mesa (0108), aparte de las entradas
  cola: [],           // ingresos hechos a ciegas, pendientes de subir
  conflictos: [],     // los que al subir resultaron ya usados por otra puerta
  red: true,          // lo que sabemos de la conexión por cómo fue la última llamada
  guardado: true,     // false si el navegador rechaza localStorage
  bajando: false,
  sincronizando: false,
  tPadron: null,
  tDeshacer: null,
  tConteo: null,
  tSondeo: null,
  sondeando: false,   // un sondeo a la vez (ver sondear())
  intentoPadron: 0,   // cuándo arrancó la última bajada del padrón, con o sin éxito
  sesion: false,      // la base contestó que no con un error de sesión (ver la barra)
  reanudar: false,    // la cámara estaba prendida cuando se ocultó la pestaña
};

/* ── el sonido ──────────────────────────────────────────────────
   Un oscilador y dos tonos. Sube el que pasa, baja el que no: la
   dirección se reconoce sin aprenderla, que es de lo que se trata a las
   dos de la mañana con la música encima. Nada de archivos ni de CDN —
   un mp3 que no cargó es un portero que cree que el escáner no leyó.

   AudioContext no arranca sin un gesto del usuario. No se fuerza: se
   crea en el primer toque sobre la puerta (ver dibujar()) y si el
   navegador igual lo rechaza, la puerta sigue andando muda. */
let audio = null;

function despertarAudio() {
  try {
    const AC = window.AudioContext || window.webkitAudioContext;
    if (!AC) return;
    audio = audio || new AC();
    /* `!== "running"` y no `=== "suspended"`: iPhone lo deja en
       "interrupted" después de una llamada o de bloquear la pantalla, y
       con la comparación vieja ya no se despertaba en toda la noche. */
    if (audio.state !== "running") {
      const p = audio.resume();
      if (p && p.catch) p.catch(() => {});
    }
  } catch { /* sin audio se trabaja igual */ }
}

/* Sube el que pasa, baja el que no, y el de deshacer es plano y corto: no
   es ni una cosa ni la otra, es "ya está, se revirtió". */
const TONOS = {
  pasa:   { onda: "sine",     a: 760, b: 1240, quiebre: 0.085, largo: 0.20, vol: 0.28 },
  no:     { onda: "square",   a: 320, b:  170, quiebre: 0.160, largo: 0.42, vol: 0.34 },
  neutro: { onda: "triangle", a: 520, b:  520, quiebre: 0.070, largo: 0.14, vol: 0.22 },
};

function sonar(cual) {
  try {
    if (!audio) return;
    const t = TONOS[cual] || TONOS.no;
    const t0 = audio.currentTime;
    const g = audio.createGain();
    const o = audio.createOscillator();
    o.type = t.onda;
    o.connect(g); g.connect(audio.destination);
    o.frequency.setValueAtTime(t.a, t0);
    o.frequency.setValueAtTime(t.b, t0 + t.quiebre);
    /* Rampas exponenciales y no un on/off: un cuadrado que empieza y
       termina de golpe hace un "click" que tapa el tono. */
    g.gain.setValueAtTime(0.0001, t0);
    g.gain.exponentialRampToValueAtTime(t.vol, t0 + 0.012);
    g.gain.exponentialRampToValueAtTime(0.0001, t0 + t.largo);
    o.start(t0); o.stop(t0 + t.largo + 0.02);
  } catch { /* idem */ }
}

/* ── el payload ─────────────────────────────────────────────────
   `EVT:<evento>:<code>`, el mismo de Bowie y BurTown, así que el
   escáner de allá lee estas entradas y viceversa.

   Si el evento no es el activo se rechaza acá, sin llamar a la base: es
   una entrada de otra noche y no hay nada que preguntar. Preguntarlo
   igual sería una llamada por cada QR viejo que alguien tenga guardado
   en el teléfono, y todas con la misma respuesta. Y "de otro evento", no
   "de otra noche": el 30/10 y el 31/10 hay dos o tres eventos la MISMA
   noche, y un portero que lee "otra fecha" sobre una entrada de hoy
   discute con el cliente en vez de mandarlo a la otra puerta. */
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
  valida:      { cls: "pasa",   titulo: "PASA" },
  usada:       { cls: "no",     titulo: "YA ENTRÓ" },
  anulada:     { cls: "no",     titulo: "ANULADA" },
  no_existe:   { cls: "no",     titulo: "NO EXISTE" },
  /* El "no existe" de la lista del teléfono. Sin señal no se sabe si el
     código es trucho o si lo compraron después de la última bajada: la
     venta online sigue abierta durante la fiesta. En rojo, el portero
     rechaza a alguien que pagó; en ámbar y con un sonido neutro, mira el
     motivo y pide el correo de compra. */
  fuera_lista: { cls: "ambar",  titulo: "NO ESTÁ EN LA LISTA", tono: "neutro" },
  otro_evento: { cls: "no",     titulo: "OTRO EVENTO" },
  ajeno:       { cls: "no",     titulo: "NO ES UNA ENTRADA" },
  error:       { cls: "no",     titulo: "NO SE PUDO" },
  /* Ni verde ni rojo: un recibo no deja pasar a nadie (para entrar se usa
     una entrada) y tampoco es un rechazo. Azul, distinto de todo lo demás,
     para que nadie lo lea como PASA de lejos. */
  recibo_mesa: { cls: "recibo", titulo: "RECIBO DE MESA" },
  /* Ni verde ni rojo: deshacer no es dejar pasar ni rechazar. En verde
     leería como "pasá" justo cuando se le está sacando el ingreso. */
  devuelta:    { cls: "neutro", titulo: "DEVUELTA" },
};

/* La hora de Bolivia y no la del teléfono: un teléfono que vino de afuera
   con otra zona diría que la lista es "de las 03:10" cuando acá son las
   23:10, y el portero calcula mal de cuándo es lo que tiene. Un Android
   viejo sin la base de zonas tira RangeError: ahí vale la del teléfono. */
const hora = t => {
  if (!t) return "";
  const d = new Date(t);
  if (isNaN(d)) return "";
  const f = { hour: "2-digit", minute: "2-digit", hour12: false };
  try { return d.toLocaleTimeString("es-BO", { ...f, timeZone: "America/La_Paz" }); }
  catch { return d.toLocaleTimeString("es-BO", f); }
};

/* ── la pantalla ────────────────────────────────────────────────── */

/* Tope de la lista de eventos. Es una consulta de cincuenta filas: con
   señal vuelve en menos de un segundo, y si a los cuatro no volvió es que
   no va a volver. Sin tope, un wifi sin salida a internet dejaba la puerta
   en "Buscando el evento…" para siempre. */
const EVENTOS_MS = 4000;

/* La lista de eventos guardada en el teléfono, por cliente: es lo único
   que le faltaba a la puerta para abrir sin señal (el padrón y la cola ya
   estaban guardados). Por cliente y no fija, para que un operador que
   cambió de cliente no vea sin señal los eventos del anterior. Empieza con
   "puerta:", así que «Salir» la borra junto con el padrón. */
const llaveEventos = () => {
  const yo = window.ADMIN.S && window.ADMIN.S.yo;
  return `puerta:eventos:${(yo && yo.organizador_id) || "-"}`;
};

async function pantalla() {
  apagar();                     // por si se vuelve a entrar sin recargar
  const gen = P.gen;

  /* Si la puerta ya está dibujada (vuelve de otra app) se deja a la vista
     mientras se pregunta: el campo de a mano sigue andando contra el mismo
     evento, y la fila no mira un "Buscando…" por una consulta de rutina. */
  if (!document.getElementById("puerta"))
    $("#main").innerHTML = `<p class="cargando">Buscando el evento…</p>`;

  /* Se acota del lado del servidor: PostgREST corta en 1000 filas sin
     avisar y un organizador con años de historia dejaría al portero sin
     el evento de esta noche. Un borrador no se puede comprar, así que
     no puede haber nadie en su puerta. */
  let lista = null, falla = null;
  const tope = new AbortController();
  const reloj = setTimeout(() => tope.abort(), EVENTOS_MS);
  try {
    const { data, error, status } = await sb.from("eventos")
      .select("id,nombre,fecha,estado")
      .in("estado", ["publicado", "cerrado"])
      .order("fecha", { ascending: false })
      .limit(50)
      .abortSignal(tope.signal);
    if (error) falla = { msg: error.message, status, code: error.code };
    else lista = data || [];
  } catch (err) {
    falla = { msg: (err && err.message) || "sin conexión", status: 0 };
  } finally {
    clearTimeout(reloj);
  }
  if (gen !== P.gen) return;    // se cambió de pestaña mientras cargaba

  if (falla) {
    /* Sin señal la lista de eventos es lo de menos: el padrón y la cola
       están guardados en el teléfono y alcanzan para seguir escaneando.
       Antes acá se pintaba el error y se salía ANTES de cargar la lista
       local y la cámara: bloquear el teléfono sin señal era perder la
       puerta entera. Ahora se sigue con los eventos que ya se conocían —
       los de memoria si la pestaña nunca se cerró, los guardados si no. */
    const red = esFallaDeRed(falla.msg, falla.status);
    if (red) P.red = false; else P.sesion = true;
    const conocidos = P.eventos.length ? P.eventos : (leerJSON(llaveEventos()) || []);
    if (!conocidos.length) {
      $("#main").innerHTML = red
        ? `<p class="error">No se pudieron cargar los eventos: ${esc(falla.msg)}</p>
           <p class="ayuda">Conectate una vez con señal: después la puerta abre aunque no haya.</p>`
        : `<p class="error">${esc(MOTIVO_SESION)}</p>
           <div class="acciones"><button type="button" class="btn primario" id="pReentrar">Volver a entrar</button></div>`;
      const b = $("#pReentrar");
      if (b) b.onclick = reentrar;
      return;
    }
    lista = conocidos;
  } else {
    P.red = true;
    P.sesion = false;
    guardarJSON(llaveEventos(), lista);
  }

  P.eventos = lista;
  if (!P.eventos.length) {
    $("#main").innerHTML = `<p class="vacio">No hay ningún evento a la venta.
      Cuando el organizador publique uno, la puerta abre acá.</p>`;
    return;
  }
  if (!P.evento || !P.eventos.some(e => e.id === P.evento.id))
    P.evento = elegirEvento(P.eventos);

  dibujar();
  /* Primero lo guardado y después la red: si el portero abre la puerta
     ya sin señal, tiene la lista de la última vez desde el primer QR en
     vez de una pantalla vacía esperando una llamada que no va a volver. */
  cargarPadronLocal();
  arrancarCamara();
  sincronizar({ callado: true });
  bajarPadron({ callado: true });
}

/* El de esta noche es el primero que todavía no pasó. La lista viene
   descendente, así que el más cercano es el último de los que quedan
   adelante; si ya pasaron todos, el más reciente. El portero puede
   cambiarlo, pero abrir en el evento equivocado y no darse cuenta es
   una noche entera de entradas quemadas contra la fecha que no era.

   "Hoy" se corre ocho horas para atrás: la noche de un evento termina a
   la mañana del día siguiente. Con la fecha pelada, una recarga a las
   02:00 del sábado daba por pasado el evento del viernes y abría en el
   próximo que el cliente ya hubiera publicado. Hasta las 08:00 sigue
   siendo la noche anterior. */
function elegirEvento(lista) {
  const hoy = new Date(Date.now() - 8 * 3600 * 1000)
    .toLocaleDateString("en-CA");   // AAAA-MM-DD local
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

      <div class="puerta-estado" id="pEstado" data-on="0" aria-live="polite"></div>

      <div class="puerta-conteo" id="pConteo" aria-live="polite"></div>

      <button type="button" class="puerta-filtro" id="pFiltro" aria-pressed="false">
        <span class="puerta-filtro-luz" aria-hidden="true"></span>
        <span class="puerta-filtro-txt">
          <b>Modo filtro</b>
          <em id="pFiltroPie">Apagado. El escaneo deja entrar y consume la entrada.</em>
        </span>
      </button>

      <div class="puerta-visor">
        <video id="pVideo" playsinline muted autoplay></video>
        <div class="puerta-mira" aria-hidden="true"></div>
        <div class="puerta-camara" id="pCamara"></div>
        <div class="puerta-cartel" id="pCartel" role="status" aria-live="assertive"></div>
      </div>

      <div class="puerta-deshacer" id="pDeshacer"></div>

      <form class="puerta-mano" id="pFormMano" autocomplete="off">
        <label>
          <span>Código a mano</span>
          <input id="pCodigo" inputmode="latin" autocapitalize="characters"
                 autocorrect="off" spellcheck="false" maxlength="64"
                 placeholder="Ej. 7KMQ3BFHD2XW">
        </label>
        <button class="btn primario" id="pBuscar">Buscar</button>
      </form>
      <p class="ayuda">El QR se lee solo. El código a mano es para cuando la
        pantalla del cliente no ilumina o el QR está roto.</p>

      <div class="acciones">
        <button type="button" class="btn plano chico" id="pBitacora">Ver la bitácora</button>
      </div>
      <p class="ayuda">Ahí queda escrito cada ingreso, cada deshacer y cada
        rechazo, con la hora. Es lo que se mira cuando alguien discute si pasó
        o no pasó.</p>
    </div>`;

  $("#pEvento").onchange = e => {
    P.evento = P.eventos.find(x => x.id === e.target.value) || P.evento;
    P.ultimo = { code: null, visto: 0 };     // otro evento, otro rebote
    /* El deshacer pendiente es de una entrada del evento anterior:
       descheckin_entrada la buscaría en el nuevo y no la encontraría. */
    soltarDeshacer();
    ocultarCartel();
    /* El padrón y la cola son POR evento: seguir con los del anterior
       dejaría al portero decidiendo la puerta de hoy contra la lista de
       la semana pasada. */
    cargarPadronLocal();
    P.conflictos = [];
    refrescarConteo();
    sincronizar({ callado: true });
    bajarPadron({ callado: true });
  };

  armarRelojes();

  /* El sonido se despierta con el primer toque en cualquier lado de la
     puerta. Antes sólo con Modo filtro, Buscar o Reintentar: un portero
     que escaneaba con la cámara toda la noche no tocaba ninguno y la
     puerta quedaba muda. pointerup y no pointerdown: para el navegador
     un dedo que BAJA todavía no es un gesto (puede ser el comienzo de un
     scroll) y no deja arrancar el audio; recién cuando sube. No es
     `once`: iPhone vuelve a dormir el audio al bloquear la pantalla, y
     despertarAudio() no hace nada si ya está sonando. */
  const puerta = $("#puerta");
  puerta.addEventListener("pointerup", despertarAudio, { passive: true });
  puerta.addEventListener("keydown", despertarAudio, { passive: true });

  /* En el teléfono el cartel tapa la pantalla entera, y lo que tapa la
     pantalla entera se tiene que poder sacar: la fila avanza más rápido
     que los 3,8 segundos que dura solo, y abajo está la cámara. En
     escritorio el cartel solo tapa el visor y el toque no molesta. */
  $("#pCartel").onclick = () => ocultarCartel();

  $("#pFiltro").onclick = () => { despertarAudio(); cambiarFiltro(!P.filtro); };
  pintarFiltro();
  refrescarConteo();

  /* La cámara se apaga ANTES de irse. La bitácora reemplaza el #main
     entero, así que el <video> se queda huérfano pero el stream sigue
     abierto: la batería del teléfono de la puerta se va igual y la luz de
     la cámara queda prendida toda la noche sin que nadie sepa por qué.
     Al volver, `pantalla()` la enciende de nuevo. */
  $("#pBitacora").onclick = () => {
    const ev = P.evento.id;
    apagar();
    window.ADMIN.bitacora(ev, { volver: () => pantalla(), volverTxt: "Puerta" });
  };

  $("#pFormMano").onsubmit = ev => {
    ev.preventDefault();
    despertarAudio();
    const crudo = $("#pCodigo").value;
    $("#pCodigo").value = "";
    /* Si pegaron el QR entero, se lee como lo leería la cámara: una
       entrada de otro evento es OTRO EVENTO, no un NO EXISTE. */
    const d = leerPayload(crudo);
    if (d && d.evento !== String(P.evento.id).toLowerCase())
      return mostrarCartel({ resultado: "otro_evento", code: d.code });
    const code = d ? d.code : limpiarCodigo(crudo);
    if (!code) return;
    /* A mano no pasa por el antirrebote: si alguien tipea el mismo
       código dos veces es porque quiere preguntar de nuevo. Sí marca el
       último visto, para que la cámara no lo vuelva a disparar sola. */
    resolver(code, { aMano: true });
  };

  P.video  = $("#pVideo");
  P.lienzo = document.createElement("canvas");
  P.ctx    = P.lienzo.getContext("2d", { willReadFrequently: true });
}

/* El código como lo tipea o lo pega el portero, llevado a la forma en que
   está guardado. El ticket y el correo lo muestran como «#7KMQ3BFHD2XW»,
   así que el # se copia; un espacio o un guion de más también. Cualquiera
   de esos daba NO EXISTE sobre una entrada buena, que es el peor error de
   una puerta: el que pagó se queda afuera discutiendo. Los códigos son
   sólo letras y números (los de entrada y los MESA… del recibo), así que
   todo lo demás es ruido. Un payload EVT:… roto (le falta un pedazo del
   uuid) también se pela: lo que vale es lo que viene después de los dos
   puntos. */
function limpiarCodigo(txt) {
  return String(txt || "").trim()
    .replace(/^EVT:[^:]*:/i, "")
    .toUpperCase()
    .replace(/[^0-9A-Z]/g, "");
}

/* Los relojes de la puerta. Viven aparte de dibujar() porque al volver a
   primer plano sin señal se rearman sin redibujar nada (ver reanudar()). */
function armarRelojes() {
  /* Una puerta grande tiene dos teléfonos. Actualizar el número solo con
     los ingresos de ESTE escáner lo deja contando la mitad de la noche y
     nadie se entera, porque un número que sube parece un número que
     anda. Una vez por minuto es barato y alcanza para lo que se usa:
     saber si falta mucha gente. */
  clearInterval(P.tConteo);
  P.tConteo = setInterval(refrescarConteo, 60000);

  /* El padrón se refresca mientras HAY señal, que es cuando no hace
     falta. Es todo el truco: lo que se baja ahora es lo que se va a
     usar en el corte que todavía no pasó. De paso reintenta la cola. */
  clearInterval(P.tPadron);
  P.tPadron = setInterval(() => {
    sincronizar({ callado: true });
    bajarPadron({ callado: true });
  }, PADRON_MS);

  /* Mientras se está "sin señal", cada tanto se pregunta si volvió (ver
     sondear()). Corre siempre y no hace nada mientras hay red: prenderlo
     y apagarlo con cada caída es una carrera más que cuidar. */
  clearInterval(P.tSondeo);
  P.tSondeo = setInterval(sondear, SONDEO_MS);
}

/* Volver a primer plano SIN señal con la puerta ya armada. pantalla()
   empieza apagando y redibujando todo, y sin red eso es arriesgar la
   pantalla que funcionaba por una lista de eventos que no va a llegar.
   Acá se prende de nuevo lo que apagar() apagó —cámara, relojes, la marca
   del filtro— sobre el mismo HTML, con el padrón y la cola que ya están
   en memoria. */
function reanudar() {
  P.video = $("#pVideo");
  if (!P.video || !P.evento) return pantalla();
  armarRelojes();
  pintarFiltro();
  pintarEstado();
  refrescarConteo();
  arrancarCamara();
}

/* ── la cámara ──────────────────────────────────────────────────
   Todo lo que puede salir mal acá termina en el mismo lugar: un cartel
   que dice qué pasó y el campo de a mano, que ya está abajo. No hay
   pantalla de error que tape el trabajo. */
async function arrancarCamara() {
  const gen = P.gen;
  const caja = $("#pCamara");
  if (!caja) return;

  /* Antes que la cámara, la pantalla prendida: también hace falta con la
     cámara rota, para el código a mano. */
  pedirPantalla(gen);

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

/* ── la pantalla prendida ───────────────────────────────────────
   Un teléfono se bloquea solo a los 30 o 60 segundos, y en una puerta
   eso es lo normal: entre una tanda y la otra nadie toca la pantalla.
   Al bloquearse se apaga la cámara (ver el visibilitychange de abajo) y,
   sin señal, desbloquearlo era arriesgar la puerta entera. Con el
   candado de pantalla el teléfono no se bloquea mientras la puerta esté
   a la vista.

   El navegador lo suelta solo cuando la pestaña se oculta, así que se
   vuelve a pedir al volver. Sin la API (Safari viejo, Firefox) o sin
   permiso (modo ahorro de batería) no pasa nada: el teléfono se bloquea
   como antes y el checklist dice de ponerlo en «Nunca». */
let candado = null;

async function pedirPantalla(gen) {
  try {
    if (!navigator.wakeLock || document.hidden) return;
    if (candado && !candado.released) return;
    const c = await navigator.wakeLock.request("screen");
    /* Si mientras se pedía se fueron de la puerta, no queda el teléfono
       de la oficina con la pantalla prendida para siempre. */
    if (gen !== undefined && gen !== P.gen) { c.release().catch(() => {}); return; }
    candado = c;
    c.addEventListener("release", () => { if (candado === c) candado = null; });
  } catch { /* sin candado se trabaja igual */ }
}

function soltarPantalla() {
  const c = candado;
  candado = null;
  if (c && !c.released) c.release().catch(() => {});
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
    /* Sin señal ni se intenta: la llamada tarda su timeout entero y la
       fila espera mirando la pantalla congelada. Con la lista bajada se
       decide en el acto. */
    if (!hayRed()) return terminarLocal(code, aMano);

    /* La única diferencia entre dejar entrar y filtrar es CUÁL función se
       llama. marcar_filtro_entrada() no tiene un update adentro: la
       entrada queda como estaba y la persona ve el mismo cartel que una
       falsa. Elegirla acá y no en dos caminos separados es lo que
       garantiza que el filtro tenga el mismo antirrebote, el mismo
       cartel y el mismo sonido que el resto. */
    const fn = P.filtro ? "marcar_filtro_entrada" : "validar_entrada";
    /* Cuatro segundos y se decide con la lista local. Sin este tope, con
       una barra de señal el fetch espera el timeout del navegador (medio
       minuto o más) y la fila mira una pantalla congelada. Un 5xx es lo
       mismo que un corte: la base no contestó que no, no contestó. */
    const tope = new AbortController();   // AbortSignal.timeout() falta en Android viejos
    const reloj = setTimeout(() => tope.abort(), ESCANEO_MS);
    const { data, error, status } = await sb.rpc(fn,
      { p_evento: P.evento.id, p_code: code }).abortSignal(tope.signal);
    clearTimeout(reloj);   // si tiró, el abort tardío cae sobre un fetch ya cerrado: inocuo
    if (error) {
      /* Un error de red se trata como el corte que es; uno de permisos o
         de datos NO, porque ahí la base contestó y contestó que no. Dejar
         entrar por local ante un "Sin permiso" sería abrir la puerta
         justamente cuando la base la está cerrando. */
      if (esFallaDeRed(error.message, status)) {
        P.red = false; return terminarLocal(code, aMano);
      }
      /* "permission denied for function validar_entrada" en inglés no le
         dice nada a un portero. Casi siempre es la sesión: alguien tocó
         «Salir» con la misma cuenta en otro aparato, o se venció. Se dice
         en castellano qué hacer, en el cartel y en la barra de arriba. */
      if (esDeSesion(error.message, status, error.code)) {
        marcarSesion();
        mostrarCartel({ resultado: "error", code, motivo: MOTIVO_SESION });
        return;
      }
      mostrarCartel({ resultado: "error", code, motivo: error.message });
      return;
    }
    P.red = true;
    if (P.sesion) { P.sesion = false; pintarEstado(); }
    mostrarCartel(data || { resultado: "no_existe", code });
    anotarEnPadron(code, data);
    /* El recibo que se acaba de presentar con señal queda presentado
       también en la lista de este teléfono: si la señal se corta antes del
       próximo refresco, el segundo que lo muestre ve "ya se presentó". */
    if (data && data.resultado === "recibo_mesa" && data.presentado_at && P.rx) {
      const r = P.rx.get(code);
      if (r && !r.p) { r.p = data.presentado_at; guardarJSON(llavePadron(P.evento.id), P.padron); }
    }
    /* El deshacer se arma solo cuando ESTE escaneo consumió la entrada.
       Con filtro no hay nada que deshacer, y sobre una 'usada' el botón
       devolvería un ingreso que hizo otro. */
    if (!P.filtro && data && data.resultado === "valida") {
      armarDeshacer(data);
      refrescarConteo();       // solo cuando ENTRÓ alguien: el número cambió
    }
    if (aMano) $("#pCodigo") && $("#pCodigo").focus();
  } catch (err) {
    /* Sin señal la puerta no puede preguntar, pero sí puede decidir con
       la lista que se bajó antes. Sólo cuando no hay ninguna se muestra
       el cartel de "no se pudo": la entrada puede estar perfecta y el
       portero tiene que saber que el problema es el wifi y no el ticket. */
    P.red = false;
    terminarLocal(code, aMano, (err && err.message) || "sin conexión");
  } finally {
    /* La ventana del rebote se cuenta desde que VOLVIÓ la respuesta. Si
       la base tardó dos segundos, contarla desde antes la deja casi
       vencida y el mismo QR dispara de nuevo. */
    P.ultimo.visto = Date.now();
    P.ocupado = false;
  }
}

/* ══ la puerta sin señal ══════════════════════════════════════════
   En un boliche el wifi anda. En una feria, en una carpa o en un predio
   con mil teléfonos peleando la misma antena, no: se cae por tandas de
   diez minutos. Sin esto la fila se detiene entera, porque el portero
   no tiene NADA — ni la lista, ni el nombre, ni forma de saber si el
   código que está mirando existe.

   La idea es una sola: bajarse la lista ANTES, mientras hay señal, y
   decidir contra esa copia cuando no la hay.

   ── lo que esto NO puede hacer ──────────────────────────────
   Dos teléfonos sin conexión no se ven entre ellos. Los dos pueden
   dejar pasar el mismo código y los dos van a mostrar verde. Eso no
   tiene solución sin señal. Lo que sí se hace es DETECTARLO: cada
   ingreso hecho a ciegas se guarda con su hora y se sube después, y el
   que escaneó primero se queda con el ingreso. Los duplicados vuelven
   como conflicto, con nombre y hora, para que el organizador sepa
   exactamente cuántas manillas entraron dos veces en vez de
   descubrirlo en la planilla del día siguiente.

   ── por qué el estado local se pisa con el del servidor ─────
   Cuando vuelve la señal se sube la cola y se baja el padrón de nuevo.
   Lo que diga el servidor manda: es el único que vio a los dos
   teléfonos. Un local que se creyera la verdad dejaría a un portero
   mostrando "PASA" sobre una entrada que el otro ya consumió.

   ── por qué localStorage y no IndexedDB ─────────────────────
   El padrón de una feria de 20.000 entradas son ~1,4 MB con estas
   claves de una letra, y el límite es 5 MB. Se escribe entero una vez
   cada cinco minutos, no en cada escaneo — lo que sí se escribe en cada
   escaneo es la cola, que son unas decenas de bytes. IndexedDB traería
   una capa asíncrona entera para el mismo resultado. Si el navegador lo
   rechaza (modo privado, cuota llena), se dice en la barra en vez de
   fallar en silencio: un portero que cree tener respaldo y no lo tiene
   está peor que uno que sabe que no lo tiene.                       */

/* Cada cuánto se refresca el padrón mientras hay señal. Cinco minutos
   es el peor caso de desactualización si la conexión se corta justo
   después: cinco minutos de ingresos hechos por el OTRO teléfono que
   este no conoce. Más seguido no sirve —la ventana la fija el corte, no
   el refresco— y en una feria de 20.000 entradas es 1,4 MB por antena. */
const PADRON_MS = 5 * 60 * 1000;

/* Tope de una bajada del padrón. Es un "no te quedes colgado", no un
   "apurate": la lista de LÜMEN pesa ~110 KB y con la antena cargada
   tarda 10 a 15 s en bajar. Un tope de escaneo (4 s) la cortaría cada
   vez y la puerta no se actualizaría nunca. */
const PADRON_TOPE_MS = 30000;

/* Cada cuánto se pregunta si volvió la señal mientras se está "sin
   señal", y cuánto se espera la respuesta. Antes la única vuelta era el
   evento "online" del navegador, que no llega nunca cuando el corte fue
   un escaneo lento: el teléfono nunca se desconectó. Una sola respuesta
   de más de 4 s dejaba la puerta decidiendo a ciegas hasta el próximo
   refresco, cinco minutos sin ver a las otras puertas. */
const SONDEO_MS = 15000;
const TANTEO_MS = 3000;

/* Un sondeo exitoso baja de nuevo la lista, pero no más de una vez por
   minuto: con una antena que va y viene, cada vuelta pediría los 110 KB
   de LÜMEN y la bajada misma ahogaría a los escaneos. */
const PADRON_SONDEO_MS = 60000;

/* De a cuánto se sube la cola. Tiene que coincidir con el tope de
   sincronizar_puerta(): más que esto y la base rechaza la tanda entera. */
const TANDA = 500;

const llavePadron = id => `puerta:padron:${id}`;
const llaveCola   = id => `puerta:cola:${id}`;

function leerJSON(k) {
  try { const t = localStorage.getItem(k); return t ? JSON.parse(t) : null; }
  catch { return null; }
}

function guardarJSON(k, v) {
  try { localStorage.setItem(k, JSON.stringify(v)); return true; }
  catch { return false; }
}

/* `navigator.onLine` miente para arriba: dice true con el wifi del
   boliche conectado pero sin salida a internet. Nunca miente para
   abajo. Por eso se usa para decidir "ni intentes", y la caída real se
   detecta cuando la llamada falla — ahí se marca sin señal y la barra
   lo dice, sin esperar a que el navegador se dé cuenta. */
function hayRed() { return navigator.onLine !== false && P.red !== false; }

/* Una pregunta corta a la base para saber si hay con quién hablar:
   conteo_puerta, que es de lectura, liviana y ya se pide una vez por
   minuto. Devuelve "ok", "sesion" (contestó, pero que no) o "red". */
async function tantear() {
  if (!P.evento) return "red";
  const tope = new AbortController();
  const reloj = setTimeout(() => tope.abort(), TANTEO_MS);
  try {
    const { error, status } = await sb.rpc("conteo_puerta", { p_evento: P.evento.id })
      .abortSignal(tope.signal);
    if (!error) return "ok";
    return esFallaDeRed(error.message, status) ? "red" : "sesion";
  } catch {
    return "red";
  } finally {
    clearTimeout(reloj);
  }
}

/* El sondeo de "¿volvió la señal?". Sólo pregunta mientras P.red es false
   y el navegador no dice que está desconectado (ahí ni se intenta: el
   evento "online" avisa solo). Uno a la vez: con una respuesta lenta, el
   siguiente tic encontraría al anterior todavía en vuelo. */
async function sondear() {
  if (P.red !== false || navigator.onLine === false || P.sondeando) return;
  if (!P.evento || !document.getElementById("puerta")) return;
  P.sondeando = true;
  const gen = P.gen;
  try {
    const r = await tantear();
    if (gen !== P.gen || r === "red") return;
    /* Contestó. Si contestó que no (sesión), igual HAY red: decidir con la
       lista local cuando la base está diciendo que no sería abrir la
       puerta justo cuando la están cerrando (ver resolver()). */
    P.red = true;
    if (r === "sesion") { marcarSesion(); return; }
    P.sesion = false;
    pintarEstado();
    /* Primero lo que se escaneó a ciegas, después la lista: al revés, la
       lista nueva llega sin esos ingresos y los vuelve a dar por libres
       hasta la próxima bajada. sincronizar() ya baja el padrón cuando
       subió algo; si no había cola, se baja acá. */
    const habiaCola = P.cola.length > 0;
    await sincronizar({ callado: true });   // con cola: sube, baja la lista y cuenta
    if (!habiaCola) {
      if (Date.now() - P.intentoPadron > PADRON_SONDEO_MS)
        await bajarPadron({ callado: true });
      refrescarConteo();
    }
    pintarEstado();
  } finally {
    P.sondeando = false;
  }
}

function indexar(padron) {
  const ix = new Map();
  ((padron && padron.entradas) || []).forEach(e => ix.set(e.c, e));
  return ix;
}

/* Los recibos de mesa van en su propia lista del padrón (0108) y en su
   propio índice: si estuvieran en `entradas`, una puerta con el JavaScript
   viejo les daría PASA. */
function indexarRecibos(padron) {
  const rx = new Map();
  ((padron && padron.recibos) || []).forEach(r => rx.set(r.c, r));
  return rx;
}

/* Lee del teléfono lo que haya guardado de ESTE evento. Se llama antes
   de pedir nada a la red: si el portero abre la puerta ya sin señal,
   tiene la lista de la última vez y puede trabajar desde el primer QR. */
function cargarPadronLocal() {
  const id = P.evento && P.evento.id;
  if (!id) return;
  P.padron = leerJSON(llavePadron(id));
  P.ix = indexar(P.padron);
  P.rx = indexarRecibos(P.padron);
  P.cola = leerJSON(llaveCola(id)) || [];
  pintarEstado();
}

async function bajarPadron({ callado } = {}) {
  const id = P.evento && P.evento.id;
  if (!id || navigator.onLine === false || P.bajando) return;
  P.bajando = true;
  P.intentoPadron = Date.now();
  const gen = P.gen;
  /* Con tope: una bajada colgada dejaba `bajando` en true hasta recargar,
     y con eso no se refrescaba más la lista en toda la noche. */
  const tope = new AbortController();
  const reloj = setTimeout(() => tope.abort(), PADRON_TOPE_MS);
  try {
    const { data, error, status } = await sb.rpc("padron_puerta", { p_evento: id })
      .abortSignal(tope.signal);
    if (gen !== P.gen) return;
    if (error) throw falla(error, status);
    if (!data || !data.ok) throw falla({ message: "respuesta inesperada" }, 200);

    P.red = true;
    P.sesion = false;
    P.padron = data;
    P.ix = indexar(data);
    P.rx = indexarRecibos(data);
    /* Los ingresos que todavía no se subieron se vuelven a aplicar
       sobre el padrón recién bajado. Sin esto, el portero escanea sin
       señal, el padrón se refresca en un respiro de conexión antes de
       que la cola llegue a subirse, y el mismo QR vuelve a dar verde.
       Lo mismo con un recibo presentado sin señal: si no, el segundo
       que lo muestre no ve "ya se presentó". */
    P.cola.forEach(i => {
      const r = P.rx.get(i.code);
      if (r) { if (!r.p) r.p = i.at; return; }
      const e = P.ix.get(i.code);
      if (e && e.e === "valida") { e.e = "usada"; e.u = i.at; }
    });
    P.guardado = guardarJSON(llavePadron(id), data);
    if (!callado && data.truncado)
      avisar(`El evento tiene ${data.total} entradas y sin señal solo se ` +
             `pueden usar las primeras 20.000.`);
  } catch (err) {
    /* Que no se pueda bajar el padrón no es un error que interrumpa: se
       sigue con el que había. La barra dice de cuándo es. */
    anotarFalla(err);
  } finally {
    clearTimeout(reloj);
    P.bajando = false;
    pintarEstado();
  }
}

/* La decisión sin señal. Mismo vocabulario que validar_entrada() para
   que el cartel, el sonido y el modo filtro no tengan que saber de
   dónde vino la respuesta. */
function resolverLocal(code) {
  if (!P.padron || !P.ix) {
    return { resultado: "error", code,
             motivo: "Sin señal y sin lista guardada. Conectate una vez para bajarla." };
  }
  if (esRecibo(code)) return reciboLocal(code);
  const e = P.ix.get(code);
  if (!e) return { resultado: "no_existe", code, offline: true };

  /* tn/td solo vienen en las manillas de una mesa (0107): el titular y su
     carnet ENMASCARADO. El completo no viaja al padrón, que queda guardado
     en este teléfono. */
  const ficha = { code, cliente: e.n, tipo: e.t, offline: true,
                  titular: e.tn || null, titular_ci: e.td || null };
  /* 'usada' y 'anulada' son los dos estados que puede tener acá una
     entrada que no sirve, y el cartel ya sabe dibujar los dos con su
     motivo. Se pasa el estado tal cual: traducirlo sería inventar un
     vocabulario paralelo al de validar_entrada(). */
  if (e.e !== "valida") return { ...ficha, resultado: e.e, used_at: e.u };

  /* Con filtro puesto no se toca nada, igual que marcar_filtro_entrada:
     la entrada tiene que seguir sirviendo en la otra puerta. */
  if (P.filtro) return { ...ficha, resultado: "valida" };

  const at = new Date().toISOString();
  e.e = "usada";
  e.u = at;
  P.cola.push({ code, at });
  const id = P.evento.id;
  /* La cola se guarda en cada escaneo y el padrón no: si al teléfono se
     le acaba la batería, perder la lista es bajarla de nuevo y perder
     la cola es no saber quién entró. */
  P.guardado = guardarJSON(llaveCola(id), P.cola);
  guardarJSON(llavePadron(id), P.padron);
  pintarEstado();
  return { ...ficha, resultado: "valida" };
}

/* El recibo de una mesa sin señal (0108). La misma ficha que devuelve la
   base en línea (recibo_puerta): tipo, incluye, nombre, carnet completo y
   correo, que el padrón trae a propósito para esto. Nunca toca una
   entrada. La primera vez anota la presentación —en el padrón y en la
   cola, que la sube con los ingresos— para que el próximo que lo muestre
   vea "ya se presentó", acá y en las otras puertas cuando suba. */
function reciboLocal(code) {
  /* Una lista bajada antes de 0108 no trae recibos: no es que el código
     no exista, es que este teléfono no lo puede saber. */
  if (!Array.isArray(P.padron.recibos)) {
    return { resultado: "error", code,
             motivo: "Es el recibo de una mesa y la lista guardada es vieja. Conectate para bajarla de nuevo." };
  }
  const r = P.rx && P.rx.get(code);
  if (!r) return { resultado: "no_existe", code, offline: true };
  const ficha = {
    resultado: "recibo_mesa", recibo: true, code, offline: true,
    estado: r.e, tipo: r.t, incluye: r.i, entradas_incluidas: r.k,
    cliente: r.n, titular: r.n, titular_ci: r.d, email: r.m,
    presentado_at: r.p || null, ya_presentado: !!r.p,
  };
  /* Con filtro no se anota nada, igual que marcar_filtro_entrada. */
  if (r.e !== "valida" || r.p || P.filtro) return ficha;

  const at = new Date().toISOString();
  r.p = at;
  P.cola.push({ code, at });
  const id = P.evento.id;
  P.guardado = guardarJSON(llaveCola(id), P.cola);
  guardarJSON(llavePadron(id), P.padron);
  pintarEstado();
  return { ...ficha, presentado_at: at };
}

/* Lo que la base acaba de contestar con señal, anotado en la lista del
   teléfono. Sin esto, la lista sólo se enteraba de un ingreso en la
   próxima bajada: entra X a las 23:41 con señal, se corta a las 23:43, y
   a las 23:44 la captura reenviada del mismo QR da PASA contra una lista
   que todavía tiene a X como válida.

   Sólo se anota lo que dejó de servir (usada, anulada), nunca una vuelta
   a 'valida': con Modo filtro la base contesta el estado sin tocarlo, y
   si el código está en la cola de este teléfono, para la base todavía es
   válido aunque acá ya haya entrado. */
function anotarEnPadron(code, d) {
  if (!d || !d.estado || d.estado === "valida" || !P.ix || !P.evento) return;
  const e = P.ix.get(code);
  if (!e || e.e === d.estado) return;
  e.e = d.estado;
  e.u = d.used_at || e.u || null;
  guardarJSON(llavePadron(P.evento.id), P.padron);
}

/* Sube la cola y vuelve a bajar el padrón. Se llama al volver la señal,
   al entrar a la pantalla y cada vez que se refresca el padrón. */
async function sincronizar({ callado } = {}) {
  const id = P.evento && P.evento.id;
  if (!id || P.sincronizando || navigator.onLine === false || !P.cola.length) return;
  P.sincronizando = true;
  pintarEstado();

  let aplicados = 0, conflictos = [];
  try {
    while (P.cola.length) {
      const tanda = P.cola.slice(0, TANDA);
      /* Sin tope a propósito: si se cortara una tanda que la base ya
         aplicó, al reintentarla volvería entera como "ya entró por otra
         puerta", que es falso. */
      const { data, error, status } = await sb.rpc("sincronizar_puerta",
        { p_evento: id, p_ingresos: tanda });
      if (error) throw falla(error, status);
      if (!data || !data.ok) throw falla({ message: "respuesta inesperada" }, 200);

      aplicados += Number(data.aplicados || 0);
      /* Un recibo de mesa vuelve como 'recibo_mesa' (0108): se anotó su
         presentación, no es un ingreso y no es un conflicto. */
      (data.detalle || []).forEach(d => {
        if (d.resultado !== "valida" && d.resultado !== "recibo_mesa")
          conflictos.push({ code: d.code, resultado: d.resultado, used_at: d.used_at });
      });

      /* Se saca de la cola SOLO lo que se confirmó. Si la llamada
         siguiente falla, lo que queda sigue guardado y se reintenta;
         vaciar la cola entera de entrada es cómo se pierden los
         ingresos de media noche por un corte a mitad de la subida. */
      P.cola = P.cola.slice(tanda.length);
      P.guardado = guardarJSON(llaveCola(id), P.cola);
      pintarEstado();
    }
    P.red = true;
    P.sesion = false;
    P.conflictos = conflictos;
    await bajarPadron({ callado: true });
    refrescarConteo();

    if (!callado && (aplicados || conflictos.length))
      avisar(conflictos.length
        ? `Se subieron ${aplicados} ingresos. ${conflictos.length} no se pudieron: ` +
          `ya habían entrado por otra puerta.`
        : `Se subieron ${aplicados} ingresos hechos sin señal.`);
  } catch (err) {
    anotarFalla(err);
    if (!callado) avisar("No se pudo subir lo de la puerta: " +
                         ((err && err.message) || "sin conexión") +
                         ". Queda guardado y se reintenta solo.");
  } finally {
    P.sincronizando = false;
    pintarEstado();
  }
}

/* ── la barra de estado ─────────────────────────────────────────
   Lo único que el portero necesita saber de todo esto son tres cosas, y
   ninguna es técnica: si está trabajando a ciegas, de cuándo es la
   lista que tiene, y cuántos ingresos le faltan subir. Va arriba del
   conteo porque cuando está sin señal es lo primero que hay que ver, y
   desaparece del todo cuando no hay nada que decir: una barra verde
   permanente que dice "conectado" es una barra que se deja de mirar. */

/* La sesión cerrada. No dice «tocá Salir»: Salir borra la lista del
   teléfono y, si quedan ingresos sin subir, pregunta si se pierden —justo
   lo que no hay que hacer acá—. «Volver a entrar» (ver reentrar()) cierra
   sólo la sesión y deja la cola guardada, que sube sola al volver. */
const MOTIVO_SESION = "Se cerró la sesión. Tocá «Volver a entrar» y entrá con tu usuario: " +
                      "lo escaneado no se pierde.";

function marcarSesion() {
  P.sesion = true;
  pintarEstado();
}

/* Cerrar la sesión de ESTE teléfono y recargar, sin pasar por limpiarPuerta()
   de admin.js: el padrón y la cola quedan donde están, y al entrar de nuevo
   pantalla() los levanta y sube la cola. Antes de cerrar se pregunta si la
   base contesta: sin señal el login no anda (dice "clave incorrecta"), y
   cerrar la sesión ahí deja al portero sin puerta hasta que vuelva la red.
   Si contesta bien, la sesión se recuperó sola y no hay nada que cerrar. */
async function reentrar() {
  /* Sin evento elegido (la puerta ni llegó a abrir) no hay con qué
     tantear, pero tampoco hace falta: lo que llevó acá fue una respuesta
     de la base, así que había red hace un instante. */
  const r = navigator.onLine === false ? "red" : P.evento ? await tantear() : "sesion";
  if (r === "red") {
    avisar("Sin señal no se puede volver a entrar. Esperá a tener señal: " +
           "lo escaneado queda guardado en el teléfono.");
    return;
  }
  if (r === "ok") {
    P.red = true;
    P.sesion = false;
    pintarEstado();
    avisar("La sesión volvió a andar. Seguí escaneando.");
    return;
  }
  apagar();
  try { await sb.auth.signOut({ scope: "local" }); } catch { /* se recarga igual */ }
  location.reload();
}

function pintarEstado() {
  const caja = $("#pEstado");
  if (!caja) return;

  /* Lo que espera subir son ingresos y, aparte, recibos de mesa que se
     presentaron sin señal: llamarlos "ingresos" sería contar gente que no
     entró. */
  const pendRec = P.cola.filter(i => esRecibo(i.code)).length;
  const pend = P.cola.length - pendRec;
  const conectado = hayRed();
  const conf = (P.conflictos || []).length;

  caja.dataset.sesion = P.sesion ? "1" : "0";
  if (conectado && !P.sesion && !pend && !pendRec && !conf && P.guardado !== false) {
    caja.dataset.on = "0";
    caja.innerHTML = "";
    return;
  }

  const partes = [];
  if (!conectado) {
    const desde = P.padron && P.padron.generado_at
      ? `Lista de las ${hora(P.padron.generado_at)}` : "Sin lista guardada";
    partes.push(`<b>Sin señal.</b> ${esc(desde)}` +
      (P.padron ? ` · ${Number(P.padron.total || 0)} entradas` : ""));
  }
  if (pend)
    partes.push(`${pend} ingreso${pend === 1 ? "" : "s"} por subir` +
                (P.sincronizando ? " (subiendo…)" : ""));
  if (pendRec)
    partes.push(`${pendRec} recibo${pendRec === 1 ? "" : "s"} de mesa por subir`);
  if (P.guardado === false)
    partes.push(`<b>El teléfono no deja guardar</b> — si se cierra la ` +
                `pestaña se pierde lo que no se haya subido.`);
  if (conf)
    partes.push(`${conf} entrada${conf === 1 ? "" : "s"} ya había entrado por ` +
                `otra puerta: <button type="button" class="puerta-link" ` +
                `id="pVerConflictos">ver cuáles</button>`);

  /* La sesión va primero, sola y en rojo (ver .puerta-estado[data-sesion]):
     es lo único de esta barra que frena la puerta, y lo demás —cuántos
     faltan subir— no se arregla hasta que no se arregle esto. */
  const sesion = P.sesion
    ? `<span class="puerta-sesion"><b>${esc(MOTIVO_SESION)}</b>` +
      `<button type="button" class="btn plano chico" id="pReentrar">Volver a entrar</button></span>`
    : "";

  caja.dataset.on = "1";
  caja.dataset.mal = conectado ? "0" : "1";
  caja.innerHTML = sesion + partes.join(" · ");

  const r = $("#pReentrar");
  if (r) r.onclick = reentrar;

  const b = $("#pVerConflictos");
  if (b) b.onclick = () => {
    const l = (P.conflictos || []).map(c =>
      `#${c.code}${c.used_at ? " — entró a las " + hora(c.used_at) : ""}`).join("\n");
    alert("Entradas que se escanearon sin señal pero ya habían entrado:\n\n" + l);
  };
}

/* El conteo cuando no hay a quién preguntarle. Sale del padrón, que es
   lo mismo que está usando el escáner para decidir: si dijeran cosas
   distintas, una de las dos estaría mintiendo. */
function conteoLocal() {
  const caja = $("#pConteo");
  if (!caja) return;
  if (!P.padron) {
    caja.dataset.on = "0";
    caja.innerHTML = `<span class="puerta-conteo-pie">Sin señal y sin lista guardada.</span>`;
    return;
  }
  const lista = P.padron.entradas || [];
  const emitidas = lista.filter(e => e.e !== "anulada").length;
  const usadas = lista.filter(e => e.e === "usada").length;
  caja.dataset.on = "1";
  caja.innerHTML = `
    <span class="puerta-conteo-num">${usadas}<i>/ ${emitidas}</i></span>
    <span class="puerta-conteo-pie">
      <b>${emitidas - usadas === 0 ? "no falta nadie" : `faltan ${emitidas - usadas}`}</b>
      · contado sin señal
    </span>`;
}

/* Deshacer sin señal: solo lo que todavía no se subió. Un ingreso que
   ya viajó no se puede devolver desde acá —eso es descheckin_entrada y
   necesita la base—, y fingir que se pudo dejaría la entrada figurando
   libre en este teléfono y usada en el servidor. */
function deshacerLocal(code) {
  const i = P.cola.findIndex(x => x.code === code);
  if (i < 0) return null;
  P.cola.splice(i, 1);
  const e = P.ix && P.ix.get(code);
  if (e) { e.e = "valida"; e.u = null; }
  const id = P.evento.id;
  P.guardado = guardarJSON(llaveCola(id), P.cola);
  guardarJSON(llavePadron(id), P.padron);
  pintarEstado();
  return { resultado: "devuelta", code, cliente: e && e.n, tipo: e && e.t, offline: true };
}

/* El navegador avisa de la vuelta antes de que nadie escanee. Es el
   momento exacto para subir la cola: si se esperara al próximo QR, una
   puerta que se vació a las tres de la mañana no sube nada hasta que
   alguien toque la pantalla. */
addEventListener("online", () => {
  P.red = true;
  pintarEstado();
  if (document.getElementById("puerta")) {
    sincronizar();
    bajarPadron({ callado: true });
    refrescarConteo();
  }
});
addEventListener("offline", () => { P.red = false; pintarEstado(); });

/* Decide con la lista guardada y termina como termina un escaneo
   normal: cartel, sonido, deshacer y conteo. Compartido por los tres
   caminos que llevan acá —sin señal de entrada, error de red devuelto y
   excepción— para que ninguno se quede sin el deshacer o sin el
   antirrebote, que es exactamente cómo se rompen estas cosas. */
function terminarLocal(code, aMano, motivo) {
  /* La barra se repinta acá y no sólo cuando algo entra a la cola: el
     escaneo que acaba de descubrir el corte tiene que dejar dicho "Sin
     señal" aunque haya sido un YA ENTRÓ o un NO ESTÁ EN LA LISTA. */
  pintarEstado();
  const r = resolverLocal(code);
  if (r.resultado === "error" && motivo) r.motivo = motivo;
  mostrarCartel(r);
  if (!P.filtro && r.resultado === "valida") {
    armarDeshacer(r);
    refrescarConteo();
  }
  if (aMano) $("#pCodigo") && $("#pCodigo").focus();
}

/* Un fallo de red que supabase-js devuelve como `error` en vez de
   tirarlo. El mensaje es del navegador y cambia entre uno y otro, así
   que se buscan las formas conocidas y nada más: cualquier otra cosa es
   una respuesta de la base y se muestra tal cual. */
function esDeRed(msg) {
  return /failed to fetch|networkerror|load failed|network request failed|timeout|timed out|abort/i
    .test(String(msg || ""));
}

/* "La base no contestó": un error de red, un tope vencido o un 5xx (la
   base no dijo que no, no dijo nada). status 0 es como supabase-js marca
   un fetch que ni salió. */
function esFallaDeRed(msg, status) {
  return esDeRed(msg) || status === 0 || (status >= 500 && status < 600);
}

/* "La base contestó que no a ESTA sesión": token vencido o revocado (un
   «Salir» en otro aparato con la misma cuenta), la cuenta dada de baja,
   o la llamada saliendo sin sesión (anon). Ver la barra de estado. */
function esDeSesion(msg, status, code) {
  return status === 401 || status === 403 || code === "42501" ||
         /^PGRST30/.test(String(code || "")) ||
         /jwt|permission denied|sin permiso|not authorized|unauthorized/i.test(String(msg || ""));
}

/* El error de una llamada con lo que hace falta para clasificarlo: el
   `throw new Error(msg)` de antes perdía el status, y sin status un 401
   y un 503 eran lo mismo. */
function falla(error, status) {
  return Object.assign(new Error((error && error.message) || "sin conexión"),
                       { status, code: error && error.code });
}

/* Qué se hace cuando falla la bajada del padrón o la subida de la cola.
   Antes era siempre P.red = false: un «Salir» en otro teléfono o una
   cuenta que cambió de cliente se veían como "Sin señal", y desde ahí el
   teléfono decidía con una lista vieja y no subía lo que escaneaba, con
   señal de sobra y sin que nadie supiera por qué. Ahora sólo lo que es
   de red marca sin señal; cualquier otra respuesta es la base diciendo
   que no, y eso se dice como lo que es. */
function anotarFalla(err) {
  const status = err && err.status;
  const msg = (err && err.message) || "";
  if (esFallaDeRed(msg, status === undefined ? 0 : status)) P.red = false;
  else marcarSesion();
}

/* ══ el conteo ════════════════════════════════════════════════════
   Un número grande y una línea abajo. Sin tabla y sin gráfico: esto se
   mira de reojo entre dos escaneos, con el teléfono a la altura de la
   cintura, y cualquier cosa que haya que leer no se va a leer.

   conteo_puerta() es una función aparte de resumen_evento() porque esa
   exige puede_editar() y el portero no lo cumple. El desglose por tipo
   viene en el jsonb y acá se resume a una sola línea — el que falta
   entrar por tipo importa para saber si lo que falta es una mesa de
   veinte o tres generales sueltas. */
async function refrescarConteo() {
  const caja = $("#pConteo");
  if (!caja || !P.evento) return;
  /* Sin señal el número sale de la misma lista con la que el escáner
     está decidiendo. Que salieran de dos lados distintos es cómo la
     pantalla termina diciendo que faltan veinte cuando ya entraron. */
  if (!hayRed()) return conteoLocal();
  const gen = P.gen;

  const { data, error } = await sb.rpc("conteo_puerta", { p_evento: P.evento.id });
  if (gen !== P.gen || !document.getElementById("pConteo")) return;

  /* Que el conteo falle no puede tapar el escáner: dejar entrar gente es
     lo que hay que hacer, saber cuántos van es lo que estaría bueno. */
  if (error || !data || data.emitidas === undefined) {
    caja.dataset.on = "0";
    caja.innerHTML = `<span class="puerta-conteo-pie">No se pudo traer el conteo${
      error ? ": " + esc(error.message) : "."}</span>`;
    return;
  }

  const faltan = Number(data.faltan || 0);
  const ritmo = Number(data.ultima_media_hora || 0);

  /* El desglose por tipo viene en `data.tipos` y acá NO se dibuja. Se
     probó y son seis renglones de texto chico: deja de ser un número que
     se mira de reojo y pasa a ser algo que hay que leer, que es
     justamente lo que en una puerta no se hace. Vive en la función
     porque el que cierra la noche lo necesita; esta pantalla no. */
  caja.dataset.on = "1";
  caja.innerHTML = `
    <span class="puerta-conteo-num">${Number(data.usadas || 0)}<i>/ ${
      Number(data.emitidas || 0)}</i></span>
    <span class="puerta-conteo-pie">
      <b>${faltan === 0 ? "no falta nadie" : `faltan ${faltan}`}</b>
      ${ritmo ? ` · ${ritmo} en la última media hora` : ""}
    </span>`;
}

/* ══ modo filtro ══════════════════════════════════════════════════
   Un interruptor que tiñe la PANTALLA ENTERA, no un tilde en un rincón.
   Es lo único que importa de este modo: mientras está puesto no entra
   nadie, y un portero que se olvidó de que lo tenía prendido cree que
   está dejando pasar gente mientras la manda de vuelta a la calle. Por
   eso el color se lo come todo — la barra de arriba también — y el pie
   del interruptor dice en castellano qué va a pasar con el próximo
   escaneo.

   Lo que se le muestra al rechazado es EXACTAMENTE el cartel de una
   entrada falsa: el mismo título, el mismo rojo, ningún nombre. Si el
   cartel dijera "estás en la lista pero hoy no entrás", la discusión
   pasa de ser con el ticket a ser con el portero. Lo que el portero sí
   necesita saber —si la entrada era buena— va acá arriba, en el pie del
   interruptor, del lado de la pantalla que mira él y no el otro.

   Y no consume: marcar_filtro_entrada() no tiene un solo update. La
   entrada queda válida y sirve más tarde o en otra puerta. */
function cambiarFiltro(on) {
  P.filtro = !!on;
  /* El deshacer NO se cancela al prender el filtro. El caso real es
     justamente ese: dejaste entrar a alguien de más, te diste cuenta y
     cerraste la puerta. Cancelarlo acá te saca la única forma de
     arreglar lo que acabás de ver. */
  pintarFiltro();
  ocultarCartel();
}

function pintarFiltro() {
  const b = $("#pFiltro"), caja = $("#puerta");
  if (!b || !caja) return;
  b.setAttribute("aria-pressed", P.filtro ? "true" : "false");
  caja.dataset.filtro = P.filtro ? "1" : "0";
  /* En el body también: la barra de arriba es parte de "la pantalla
     entera". apagar() lo limpia, para no dejar el resto del panel
     pintado de naranja cuando el portero se va a otra pestaña. */
  document.body.dataset.filtro = P.filtro ? "1" : "0";
  $("#pFiltroPie").textContent = P.filtro
    ? "Puesto. Nadie pasa y ninguna entrada se consume."
    : "Apagado. El escaneo deja entrar y consume la entrada.";
}

/* Lo que el rechazado no ve. Va en el pie del interruptor y no en el
   cartel, que es lo que se da vuelta para mostrar. */
function pieFiltro(r) {
  const pie = $("#pFiltroPie");
  if (!pie) return;
  const quien = r.cliente ? ` · ${r.cliente}` : "";
  const que = r.resultado === "no_existe" ? "ese código no existe"
            : r.resultado === "otro_evento" ? "es de otro evento"
            : r.resultado === "ajeno" ? "ese QR no es una entrada"
            : r.resultado === "recibo_mesa" ? "es el recibo de una mesa, no una entrada"
            : r.resultado === "usada" ? "ya había entrado"
            : r.resultado === "anulada" ? "estaba anulada"
            : "seguía válida, no se consumió";
  pie.textContent = `Rechazado ${r.code ? "#" + r.code : ""} — ${que}${quien}`;
}

/* ══ deshacer el último ingreso ═══════════════════════════════════
   Solo el último, y solo por unos segundos. La tentación es una lista
   de los ingresos de la noche con un botón al lado de cada uno: sería
   más cómodo y sería una puerta trasera — con eso, cualquiera que
   agarre el teléfono devuelve una entrada de hace dos horas y esa
   manilla entra por segunda vez, sin que quede rastro de que hubo una
   decisión. Un botón que vence solo no se puede usar para eso.

   Vive debajo del visor y no adentro del cartel: el cartel dura cuatro
   segundos porque la fila sigue avanzando, y el que se equivocó tarda
   más que eso en darse cuenta. */
function armarDeshacer(d) {
  const caja = $("#pDeshacer");
  if (!caja) return;
  P.deshacer = { code: d.code, hasta: Date.now() + VENTANA_DESHACER_MS };
  caja.dataset.on = "1";
  caja.innerHTML = `
    <span class="puerta-deshacer-txt">Dejaste entrar a
      <b>${esc(d.titular ? `la mesa de ${d.titular}` : (d.cliente || "#" + d.code))}</b></span>
    <button type="button" class="btn plano chico" id="pBtnDeshacer">
      Deshacer <span id="pDeshacerSeg"></span></button>`;
  $("#pBtnDeshacer").onclick = correrDeshacer;
  clearInterval(P.tDeshacer);
  /* Se repinta solo el contador y no la tira entera: reescribir el
     innerHTML cuatro veces por segundo le saca el foco al botón y lo
     vuelve inclickeable justo mientras se lo está apretando. */
  P.tDeshacer = setInterval(latirDeshacer, 250);
  latirDeshacer();
}

function latirDeshacer() {
  if (!P.deshacer) return soltarDeshacer();
  const restan = Math.ceil((P.deshacer.hasta - Date.now()) / 1000);
  if (restan <= 0) return soltarDeshacer();
  const s = $("#pDeshacerSeg");
  if (s) s.textContent = `· ${restan}s`;
}

function soltarDeshacer() {
  clearInterval(P.tDeshacer);
  P.tDeshacer = null;
  P.deshacer = null;
  const caja = $("#pDeshacer");
  if (caja) { caja.dataset.on = "0"; caja.innerHTML = ""; }
}

async function correrDeshacer() {
  if (!P.deshacer || P.ocupado) return;
  const code = P.deshacer.code;
  P.ocupado = true;
  try {
    /* Si el ingreso todavía está en la cola, deshacerlo es sacarlo de
       ahí: nunca llegó a la base, así que pedirle que lo revierta sería
       pedirle que revierta algo que no sabe que pasó. */
    const local = deshacerLocal(code);
    if (local) {
      soltarDeshacer();
      P.ultimo = { code: null, visto: 0 };
      refrescarConteo();
      mostrarCartel(local);
      return;
    }
    if (!hayRed()) {
      avisar("Ese ingreso ya se subió y sin señal no se puede deshacer. " +
             "Volvé a intentar cuando haya conexión.");
      return;
    }
    const { data, error } = await sb.rpc("descheckin_entrada",
      { p_evento: P.evento.id, p_code: code });
    if (error) { avisar("No se pudo deshacer: " + error.message); return; }
    soltarDeshacer();
    /* La lista del teléfono la tenía como usada desde el escaneo (ver
       anotarEnPadron()). Si no se devuelve también acá, un corte de señal
       justo después la rechaza como YA ENTRÓ cuando la base ya la liberó. */
    const e = P.ix && P.ix.get(code);
    if (data && data.resultado === "valida" && e && e.e === "usada") {
      e.e = "valida"; e.u = null;
      guardarJSON(llavePadron(P.evento.id), P.padron);
    }
    /* La entrada volvió a 'valida', así que tiene que poder escanearse
       de nuevo YA: si el rebote la sigue tapando, el portero la pasa
       por la cámara, no pasa nada, y cree que deshacer la rompió. */
    P.ultimo = { code: null, visto: 0 };
    refrescarConteo();         // uno menos adentro
    const d = data || {};
    mostrarCartel(d.resultado === "valida"
      ? { resultado: "devuelta", code, cliente: d.cliente, tipo: d.tipo }
      : (data || { resultado: "error", code }));
  } catch (err) {
    avisar("No se pudo deshacer: " + ((err && err.message) || "sin conexión"));
  } finally {
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

  /* Con filtro puesto TODO lo que se rechaza se ve igual, venga de la
     base o de un QR que ni se llegó a preguntar. Si "OTRO EVENTO" y "NO
     EXISTE" se distinguieran, el rechazado sabría cuál de las dos le
     tocó — y de ahí a saber que el problema es la lista y no su ticket
     hay un paso. El error de red queda afuera: eso no es un rechazo,
     es la puerta que no pudo decidir, y ahí el portero tiene que ver
     la verdad. */
  if (P.filtro && r.resultado !== "error" && r.resultado !== "devuelta") {
    pieFiltro(r);
    r = { resultado: "no_existe", code: r.code };
  }

  /* El recibo de una mesa (0108) tiene su propio cartel. */
  if (r.resultado === "recibo_mesa") return cartelRecibo(caja, r);

  /* Sin señal, "no está en la lista" no es "no existe" (ver CARTELES). */
  const fueraDeLista = r.resultado === "no_existe" && r.offline;
  const c = fueraDeLista ? CARTELES.fuera_lista
          : (CARTELES[r.resultado] || CARTELES.error);

  const detalle = [];
  if (r.cliente) detalle.push(`<strong>${esc(r.cliente)}</strong>`);
  if (r.tipo)    detalle.push(esc(r.tipo));
  /* La entrada de una mesa: a nombre de quién está la mesa (0107) y, desde
     0108, el tipo ya dice "Entrada · Mesa VIP". El portero compara el
     nombre y el carnet con el que le muestran: en línea llega el carnet
     completo; sin señal, los últimos cuatro. */
  const mesa = r.titular
    ? `Mesa a nombre de <b>${esc(r.titular)}</b>${r.titular_ci ? ` · CI ${esc(r.titular_ci)}` : ""}`
    : "";

  let motivo = "";
  if (r.resultado === "usada")
    motivo = `Entró a las ${esc(hora(r.used_at)) || "—"}.`;
  else if (r.resultado === "anulada")
    motivo = "La dieron de baja. No pasa.";
  else if (fueraDeLista)
    motivo = `Lista del teléfono de las ${
      esc(hora(P.padron && P.padron.generado_at)) || "—"}. ` +
      "Si compró recién, esperá señal o pedí el correo de compra.";
  else if (r.resultado === "no_existe")
    motivo = "Ese código no existe en este evento.";
  else if (r.resultado === "otro_evento")
    motivo = "Esta entrada es de otro evento.";
  else if (r.resultado === "ajeno")
    motivo = "Ese QR no es una entrada.";
  else if (r.resultado === "error")
    motivo = esc(r.motivo || "Probá de nuevo.");
  else if (r.resultado === "devuelta")
    motivo = "El ingreso se deshizo. La entrada vuelve a servir.";

  /* La marca de "sin señal" va en el cartel y no sólo en la barra de
     arriba. El portero mira el cartel: es lo único que mira. Un verde
     idéntico al de siempre lo deja sin saber que este ingreso todavía
     no está confirmado del otro lado y que, si otra puerta escaneó el
     mismo código, uno de los dos va a resultar duplicado. */
  caja.className = `puerta-cartel ${c.cls}`;
  caja.dataset.on = "1";
  caja.innerHTML = `
    <span class="puerta-titulo">${c.titulo}</span>
    ${r.offline ? `<span class="puerta-sinsenal">sin señal</span>` : ""}
    ${detalle.length ? `<span class="puerta-quien">${detalle.join(" · ")}</span>` : ""}
    ${mesa ? `<span class="puerta-mesa">${mesa}</span>` : ""}
    ${motivo ? `<span class="puerta-motivo">${motivo}</span>` : ""}
    ${r.code ? `<span class="puerta-code">#${esc(r.code)}</span>` : ""}`;

  sonar(c.tono || c.cls);
  clearTimeout(P.tCartel);
  P.tCartel = setTimeout(ocultarCartel, CARTEL_MS);
}

/* El cartel del recibo. Lo que el dueño pidió que vea el guardia: tipo de
   mesa, lo que incluye, nombre, carnet y correo. Arriba, en grande, que NO
   es una entrada: el que lo muestra tiene que entrar con una. Si ya se
   había mostrado, la hora va antes que todo lo demás: es lo que delata una
   captura reenviada. Una mesa anulada sale en rojo: no hay mesa. */
function cartelRecibo(caja, r) {
  const anulada = r.estado === "anulada";
  const inc = Number(r.entradas_incluidas || 0);
  const ent = r.entradas && typeof r.entradas === "object" ? r.entradas : null;
  const lineaEntradas = inc === 0 ? "Sin entradas incluidas"
    : `${inc} entrada${inc === 1 ? "" : "s"} incluida${inc === 1 ? "" : "s"}` +
      (ent ? ` · ${Number(ent.usadas || 0)} ya entr${Number(ent.usadas) === 1 ? "ó" : "aron"}` : "");

  caja.className = `puerta-cartel ${anulada ? "no" : "recibo"}`;
  caja.dataset.on = "1";
  caja.innerHTML = `
    <span class="puerta-titulo">${anulada ? "MESA ANULADA" : "RECIBO DE MESA"}</span>
    ${r.offline ? `<span class="puerta-sinsenal">sin señal</span>` : ""}
    <span class="puerta-motivo"><b>${anulada ? "Esta reserva se anuló. No hay mesa."
      : "No da ingreso. Para entrar se usa una entrada."}</b></span>
    ${!anulada && r.ya_presentado
      ? `<span class="puerta-presentado">Ya se presentó a las ${esc(hora(r.presentado_at)) || "—"}</span>` : ""}
    <span class="puerta-quien">${esc(r.tipo || "Mesa")}</span>
    <span class="puerta-motivo">${r.incluye ? `Incluye: ${esc(r.incluye)} · ` : ""}${esc(lineaEntradas)}</span>
    <span class="puerta-mesa">A nombre de <b>${esc(r.titular || "—")}</b>${
      r.titular_ci ? ` · CI ${esc(r.titular_ci)}` : ""}${r.email ? `<br>${esc(r.email)}` : ""}</span>
    ${r.code ? `<span class="puerta-code">#${esc(r.code)}</span>` : ""}`;

  sonar(anulada ? "no" : "neutro");
  clearTimeout(P.tCartel);
  P.tCartel = setTimeout(ocultarCartel, CARTEL_RECIBO_MS);
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
  clearInterval(P.tConteo); P.tConteo = null;
  clearInterval(P.tPadron); P.tPadron = null;
  clearInterval(P.tSondeo); P.tSondeo = null;
  soltarDeshacer();
  soltarPantalla();
  if (P.stream) { P.stream.getTracks().forEach(t => t.stop()); P.stream = null; }
  if (P.video) { P.video.srcObject = null; P.video = null; }
  P.ocupado = false;
  P.ultimo = { code: null, visto: 0 };
  /* El naranja del filtro es de esta pantalla. Sin esto, irse a
     "Eventos" deja el panel entero teñido y el interruptor —que vive
     acá— fuera de alcance para apagarlo. P.filtro no se toca: al volver
     a la puerta el modo sigue como estaba, que es lo que el portero
     dejó puesto. */
  delete document.body.dataset.filtro;
}

/* Un teléfono bloqueado con la pantalla prendida y la cámara comiendo
   batería toda la noche. Al volver se reanuda sola.

   Cómo se reanuda depende de la señal. Con red, pantalla() de cero: trae
   los eventos de nuevo y, si no puede, sigue con los que conoce. Sin red,
   reanudar() sobre la pantalla que ya estaba: es el momento exacto en que
   antes se perdía la puerta (desbloquear el teléfono en el corte) y ahí no
   se arriesga nada por una consulta que no va a volver. */
document.addEventListener("visibilitychange", () => {
  if (document.hidden) {
    if (!P.stream) return;
    const habia = !!P.video && document.body.contains(P.video);
    apagar();
    if (habia) P.reanudar = true;
    return;
  }
  const armada = !!document.getElementById("puerta");
  if (P.reanudar) {
    P.reanudar = false;
    if (armada) return (!hayRed() && P.evento) ? reanudar() : pantalla();
  }
  /* Sin cámara (permiso negado, a mano) no hubo nada que reanudar, pero
     el candado de pantalla se soltó igual al ocultarse. */
  if (armada) pedirPantalla(P.gen);
});

window.PUERTA = { pantalla, apagar };
})();
