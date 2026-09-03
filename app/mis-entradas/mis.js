/* ══════════════════════════════════════════════════════════════════
   MIS ENTRADAS — la lista de compras de esta persona.

   Dos fuentes, una lista:
     · lo LOCAL: localStorage, clave `ticketazo.compras`. La llena quien
       compra (al pagar) y orden.js (cuando alguien abre el link de una
       compra que este aparato todavía no tenía guardada). Esta página sólo
       LEE esa lista, salvo por una escritura propia: sacar una compra
       cuando alguien toca "Quitar".
     · la CUENTA: Cuenta.misCompras() (cuenta.js → mis_compras() en la
       base), sólo con sesión. Trae la fecha real del evento y el nombre
       del organizador, así que cuando una compra está en las dos, manda
       la del servidor.

   Se deduplica por id (el uuid de la orden). Lo local que NO está en la
   cuenta se marca "sólo en este teléfono" y ofrece "Guardar en mi cuenta".
   Lo del servidor no se copia al localStorage: esa clave la escriben la
   compra y orden.js, y que esta página también la escribiera sería un
   tercer dueño para el mismo dato.

   El contrato de cada elemento local:
     { id, evento, org, slug, fecha, lugar, entradas, guardada }
   `fecha` debería ser un ISO con año y huso (así la escribe quien acaba de
   comprar, y así la reconstruye orden.js a partir de `fecha_txt`). Pero la
   clave es de otro proceso y puede llegar vacía, vieja o rota, así que acá
   nada se da por sentado: si `JSON.parse` falla, o un campo no es el que
   se espera, la página cae al estado vacío o al mejor dato disponible —
   nunca a un error en pantalla. Y si la cuenta no contesta (sin red, sesión
   vencida), la lista local se pinta igual: la red no puede esconder una
   entrada que ya está en el aparato. */
(() => {
"use strict";

const KEY = "ticketazo.compras";
const Cuenta = window.Cuenta || null;
const $ = s => document.querySelector(s);
const esc = s => String(s ?? "").replace(/[&<>"']/g, c =>
  ({ "&":"&amp;", "<":"&lt;", ">":"&gt;", '"':"&quot;", "'":"&#39;" }[c]));
/* La misma forma de correo que exige la función `cuenta`: con forma de
   correo alcanza, no hay SMTP para comprobar más. */
const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/;

/* ── leer / guardar ──
   Un solo lugar toca la clave, y siempre con try/catch: un navegador con
   el storage bloqueado (modo privado agresivo, política de la empresa) no
   tiene por qué dejar esta página en blanco, sólo sin memoria. */
function leer() {
  try {
    const l = JSON.parse(localStorage.getItem(KEY) || "[]");
    return Array.isArray(l) ? l.filter(c => c && typeof c.id === "string") : [];
  } catch { return []; }
}
function guardar(lista) {
  try { localStorage.setItem(KEY, JSON.stringify(lista)); } catch { /* no persiste, no rompe */ }
}

/* ── la fecha sin año ──
   Misma idea que la reconstrucción de app.js para el botón de calendario:
   `fecha_txt` ("SÁB 12 SEP · 21:00") no trae año porque nunca hizo falta
   para mostrarlo. Cuando `fecha` ya es un ISO de verdad (el camino normal,
   hoy) `new Date` la entiende sola y no se llega ni a intentar esto; el
   regex es la red por si algún registro viejo o corrupto sólo trae el
   texto. Se prueban este año y el que viene y gana el que caiga en el día
   de semana que el propio texto declara — adivinar el año a ciegas puede
   mandar un evento de septiembre a la lista de "ya pasaron" en enero. */
const MES_TXT = ["ENE","FEB","MAR","ABR","MAY","JUN","JUL","AGO","SEP","OCT","NOV","DIC"];
const DIA_TXT = ["DOM","LUN","MAR","MIÉ","JUE","VIE","SÁB"];
const diaBoliviano = d => new Date(d.getTime() - 4 * 3600e3).getUTCDay();

function fechaDesdeTexto(txt) {
  txt = String(txt || "").toUpperCase();
  const md = txt.match(/(\d{1,2})\s+([A-ZÁÉÍÓÚÑ]{3})/);
  const mes = md ? MES_TXT.indexOf(md[2]) : -1;
  if (mes < 0) return null;
  const hm = txt.match(/(\d{1,2}):(\d{2})/);
  const semana = (txt.match(/^([A-ZÁÉÍÓÚÑ]{3})/) || [])[1];
  const p2 = n => String(n).padStart(2, "0");
  const anio = new Date().getFullYear();
  const cand = [0, 1]
    .map(n => new Date(`${anio + n}-${p2(mes + 1)}-${p2(md[1])}` +
                       `T${hm ? p2(hm[1]) : "21"}:${hm ? hm[2] : "00"}:00-04:00`))
    .filter(d => !isNaN(d.getTime()));
  return cand.find(d => DIA_TXT[diaBoliviano(d)] === semana)
      || cand.find(d => d.getTime() > Date.now() - 864e5)
      || null;
}

function fechaDe(c) {
  if (!c || !c.fecha) return null;
  const directa = new Date(c.fecha);
  if (!isNaN(directa.getTime())) return directa;
  return fechaDesdeTexto(c.fecha);
}

/* "SÁB 12 SEP · 21:00": el mismo formato que ya usa orden.js, para que la
   fecha de una entrada se lea igual en todo el sitio. Se arma con
   Intl + America/La_Paz y no con getDay()/getHours(), que contestan según
   el reloj de quien mira la página — y esta lista la puede abrir alguien
   de visita, con el teléfono en otro huso. */
const DIA_ES = ["DOM","LUN","MAR","MIÉ","JUE","VIE","SÁB"];
const MES_ES = ["ENE","FEB","MAR","ABR","MAY","JUN","JUL","AGO","SEP","OCT","NOV","DIC"];
const DIA_EN = ["Sun","Mon","Tue","Wed","Thu","Fri","Sat"];
const MES_EN = ["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"];

function partesBolivia(d) {
  return new Intl.DateTimeFormat("en-US", {
    timeZone: "America/La_Paz", weekday: "short", day: "numeric",
    month: "short", hour: "2-digit", minute: "2-digit", hour12: false,
  }).formatToParts(d).reduce((o, p) => (o[p.type] = p.value, o), {});
}
function formatearFecha(d) {
  const p = partesBolivia(d);
  const dia = DIA_ES[DIA_EN.indexOf(p.weekday)] ?? p.weekday;
  const mes = MES_ES[MES_EN.indexOf(p.month)] ?? p.month;
  const hora = p.hour === "24" ? "00" : p.hour;
  return `${dia} ${p.day} ${mes} · ${hora}:${p.minute}`;
}
function diaGrande(d) {
  return new Intl.DateTimeFormat("en-US", { timeZone: "America/La_Paz", day: "numeric" }).format(d);
}

/* ── lo que manda el servidor, a la forma de la lista ──
   mis_compras() devuelve {id, evento, organizador, org, slug, lugar,
   fecha (YYYY-MM-DD), hora_inicio (HH:MM), entradas, pagada_at}. Se arma
   el ISO en -04:00 —la hora del evento es hora de Bolivia— y se guarda el
   nombre del organizador aparte del slug: la tarjeta prefiere el nombre,
   pero `org` sigue siendo el slug, que es lo que dice el contrato local. */
function desdeServidor(r) {
  let fecha = null;
  if (r.fecha) {
    const d = new Date(`${r.fecha}T${String(r.hora_inicio || "21:00").slice(0, 5)}:00-04:00`);
    if (!isNaN(d.getTime())) fecha = d.toISOString();
  }
  return {
    id: String(r.id),
    evento: r.evento || "Entrada",
    organizador: r.organizador || "",
    org: r.org || "", slug: r.slug || "",
    fecha,
    lugar: r.lugar || "",
    entradas: Number(r.entradas) || 0,
    guardada: Date.parse(r.pagada_at) || 0,
    enCuenta: true,
  };
}

/* ── la tarjeta ──
   La misma entrada troquelada de la portada (.evento → .afiche/.papel →
   .perf → .talon): esta lista nunca tiene flyer, así que el papel —que en
   la cartelera es el respaldo para cuando la imagen no llegó— es acá la
   única superficie, y por eso el nombre va SIEMPRE ahí y no se repite en
   el talón (la misma regla que ya usan tarjeta() y destacado() en
   portada.js). El talón cambia el precio por la cantidad de entradas, que
   es el dato que importa en esta lista, y cierra con botones en vez de
   ser el link entero: "Ver entrada" abre el link de siempre; "Quitar" sólo
   saca la fila de este teléfono (y no existe para lo que está en la
   cuenta: volvería a aparecer al recargar); "Guardar en mi cuenta" aparece
   con sesión en lo que todavía es sólo local.

   `c.enCuenta`: true (vino del servidor), false (local, con sesión abierta
   y no está en la cuenta), undefined (sin sesión: no hay nada que decir). */
function tarjetaCompra(c, pasada) {
  const d = fechaDe(c);
  const cuando = d ? formatearFecha(d) : "Fecha a confirmar";
  const diaTxt = d ? diaGrande(d) : "—";
  const n = Number(c.entradas) || 0;
  const cant = n > 0 ? `${n} ${n === 1 ? "entrada" : "entradas"}` : "sin entradas vigentes";
  const etq = c.enCuenta === true  ? `<span class="etq">En tu cuenta</span>`
            : c.enCuenta === false ? `<span class="etq local">Sólo en este teléfono</span>` : "";
  const quien = c.organizador || c.org;
  return `<article class="evento compra${pasada ? " pasada" : ""}">
    <div class="afiche">
      <div class="papel">
        <span class="papel-dia" aria-hidden="true">${esc(diaTxt)}</span>
        <h3 class="papel-nombre">${esc(c.evento || "Entrada")}</h3>
        ${quien ? `<span class="papel-org">${esc(quien)}</span>` : ""}
      </div>
    </div>
    <div class="perf" aria-hidden="true"><i class="p1"></i><i class="p2"></i></div>
    <div class="talon">
      <div class="cuando"><span>${esc(cuando)}</span>${etq}</div>
      <div class="pie-talon">
        <span class="donde">${esc(c.lugar || "Lugar a confirmar")}</span>
        <span class="cant">${esc(cant)}</span>
      </div>
      <div class="accion">
        <a class="ver" href="/orden/?id=${encodeURIComponent(c.id)}">Ver entrada<i class="flecha" aria-hidden="true"></i></a>
        ${c.enCuenta === true ? "" : `<button type="button" class="quitar" data-quitar="${esc(c.id)}">Quitar</button>`}
      </div>
      ${c.enCuenta === false ? `<button type="button" class="vincular" data-vincular="${esc(c.id)}">Guardar en mi cuenta</button>` : ""}
    </div>
  </article>`;
}

/* El cartel de "no hay nada" reusa el mismo componente que la cartelera
   vacía o caída (`.cartel`, en portada.css): un talón en blanco no puede
   parecer una página rota. Dice las tres cosas que pide el spec — dónde
   se guardan, qué pasa si compró en otro aparato, y a dónde ir. Con sesión
   la historia es otra: la cuenta está vacía, y lo que compre con la sesión
   abierta va a caer acá solo. */
function cartelVacio(conSesion) {
  if (conSesion) return `<div class="cartel">
    <h3>Todavía no tenés entradas en tu cuenta</h3>
    <p>Cuando compres con la sesión abierta quedan guardadas acá solas, y
       las ves desde cualquier teléfono. Si tenés el link de una compra
       anterior, abrilo: desde ahí la podés guardar en tu cuenta.</p>
    <a class="btn" href="/">Ver la cartelera</a>
  </div>`;
  return `<div class="cartel">
    <h3>Todavía no tenés entradas acá</h3>
    <p>Se guardan en este teléfono cuando comprás. Si compraste desde otro
       dispositivo, no las vas a ver acá — pero tenés el link que te quedó
       después de pagar, y ese sigue sirviendo siempre.</p>
    <a class="btn" href="/">Ver la cartelera</a>
  </div>`;
}

/* ── pintar la lista ──
   Próximas primero (la que sigue, antes), pasadas después (la más
   reciente arriba: es la que alguien más probablemente vino a revisar).
   Una compra sin fecha reconocible cae del lado de "próxima" — esconder
   una entrada que ya se pagó por no poder leerle la fecha es peor que
   dejarla arriba sin ordenar bien. */
function pintarLista(compras, conSesion, cargando) {
  const ahora = Date.now();
  const enriquecidas = compras.map(c => {
    const d = fechaDe(c);
    return { c, d, pasada: !!d && d.getTime() < ahora };
  });

  const proximas = enriquecidas.filter(x => !x.pasada)
    .sort((a, b) => (a.d ? a.d.getTime() : Infinity) - (b.d ? b.d.getTime() : Infinity));
  const pasadas = enriquecidas.filter(x => x.pasada)
    .sort((a, b) => b.d.getTime() - a.d.getTime());

  /* Con la cuenta todavía contestando y nada local, el cartel de "no tenés
     nada" mentiría un segundo: se espera la respuesta antes de decirlo. */
  $("#seccionVacio").hidden = compras.length > 0 || cargando === true;
  if (!compras.length && !cargando) $("#carrilVacio").innerHTML = cartelVacio(conSesion);

  $("#seccionProximas").hidden = !proximas.length;
  $("#grillaProximas").innerHTML = proximas.map(x => tarjetaCompra(x.c, false)).join("");

  $("#seccionPasadas").hidden = !pasadas.length;
  $("#grillaPasadas").innerHTML = pasadas.map(x => tarjetaCompra(x.c, true)).join("");
}

/* ── la cabecera según haya sesión ──
   El renglón "Tu cuenta · correo · Salir" o el formulario, nunca los dos.
   La bajada y el aviso cambian con él: sin cuenta, lo que hay es de este
   navegador; con cuenta, lo de la cuenta viaja y lo local todavía no. */
function pintarCabecera(s) {
  $("#cuentaCab").hidden = !s;
  $("#entrar").hidden = !!s;
  if (s) {
    $("#cuentaMail").textContent = s.user.email || "tu cuenta";
    $("#bajada").textContent =
      "Tus compras: las de tu cuenta, que te siguen a cualquier teléfono, y las de este aparato.";
    $("#aviso").textContent =
      "Lo que está en tu cuenta lo ves desde cualquier teléfono. Lo que está sólo en " +
      "este teléfono se pierde si borrás los datos del sitio: tocá «Guardar en mi cuenta».";
  } else {
    $("#bajada").textContent =
      "Las compras que hiciste desde este teléfono, guardadas acá para volver a verlas sin buscar el correo.";
    $("#aviso").textContent =
      "Se guardan en este navegador, no en una cuenta: si borrás los datos del sitio o " +
      "cambiás de teléfono, se pierden. Lo que nunca se pierde es el link de cada entrada.";
  }
}

function estado(texto, tipo) {
  const sec = $("#seccionEstado"), p = $("#cuentaEstado");
  sec.hidden = !texto;
  if (!texto) { p.innerHTML = ""; return; }
  p.dataset.tipo = tipo || "";
  p.innerHTML = esc(texto) +
    (tipo === "error" ? ` <button type="button" id="btnReintentar">Reintentar</button>` : "");
  if (tipo === "error") $("#btnReintentar").onclick = () => pintar();
}

/* ── pintar todo ──
   Sin sesión: la lista local y listo, como siempre. Con sesión: la local
   YA, y arriba "buscando"; cuando llega la cuenta se vuelve a pintar con
   las dos mezcladas. Si la cuenta falla, la local se queda y el error va
   en el renglón de estado, no en lugar de las tarjetas.

   `serie` es para el caso de dos pintadas cruzadas (salir mientras la
   cuenta todavía está contestando): la respuesta vieja no pisa la pantalla
   nueva. */
let serie = 0;
async function pintar() {
  const mia = ++serie;
  const locales = leer();
  const s = Cuenta ? Cuenta.sesion() : null;
  pintarCabecera(s);

  if (!s) { estado(""); pintarLista(locales, false); return; }

  estado("Buscando las compras de tu cuenta…");
  pintarLista(locales.map(c => ({ ...c, enCuenta: false })), true, true);

  let remotas;
  try {
    remotas = (await Cuenta.misCompras()).map(desdeServidor);
  } catch (err) {
    if (mia !== serie) return;
    /* 401: la sesión murió (cuenta.js ya la borró). Se vuelve a pintar
       desde cero, que ahora es "sin sesión", y el formulario lo dice. */
    if (err.status === 401 && !Cuenta.sesion()) { pintar(); mostrarError(err.message); return; }
    estado(`No pudimos traer las de tu cuenta: ${err.message} Estas son las de este teléfono.`, "error");
    return;
  }
  if (mia !== serie) return;

  const enCuenta = new Set(remotas.map(c => c.id));
  const soloLocales = leer().filter(c => !enCuenta.has(c.id)).map(c => ({ ...c, enCuenta: false }));
  estado("");
  pintarLista([...remotas, ...soloLocales], true);
}

/* ── el toast con deshacer ──
   Quitar es local y reversible durante unos segundos: no hay servidor del
   que perder nada, pero si esta era la única copia del link a mano, un
   toque de más no tiene por qué costar la entrada. */
let tOculto;
function avisar(texto, deshacer) {
  const t = $("#toast");
  $("#toastTxt").textContent = texto;
  const btn = $("#toastDeshacer");
  btn.hidden = !deshacer;
  btn.onclick = deshacer ? () => { deshacer(); ocultarToast(); } : null;
  t.dataset.on = "1";
  clearTimeout(tOculto);
  tOculto = setTimeout(ocultarToast, 6000);
}
function ocultarToast() { $("#toast").dataset.on = "0"; }

function quitar(id) {
  const lista = leer();
  const idx = lista.findIndex(c => c.id === id);
  if (idx < 0) return;
  const [quitada] = lista.splice(idx, 1);
  guardar(lista);
  pintar();
  avisar(`Quitaste "${quitada.evento || "esa entrada"}" de este teléfono.`, () => {
    const actuales = leer();
    actuales.push(quitada);
    guardar(actuales);
    pintar();
  });
}

/* ── guardar una compra local en la cuenta ──
   El botón se apaga mientras viaja; al volver bien se repinta todo (la
   compra pasa a "en tu cuenta" con la fecha real del servidor). Si falla,
   el motivo va al toast y el botón vuelve: la tarjeta sigue ahí. */
async function vincular(id, boton) {
  boton.disabled = true;
  const txt = boton.textContent;
  boton.textContent = "Guardando…";
  try {
    await Cuenta.vincular(id);
    avisar("Guardada en tu cuenta.");
    pintar();
  } catch (err) {
    avisar(err.message);
    boton.disabled = false;
    boton.textContent = txt;
    if (err.status === 401 && !Cuenta.sesion()) pintar();
  }
}

/* ── el formulario: entrar o crear ──
   Los mismos dos campos en los dos modos; crear suma el nombre (opcional)
   y la nota de "sin verificación". El modo vive en data-modo del form.
   Se valida al enviar y no mientras se escribe. */
const form = $("#formCuenta");

function ponerModo(modo) {
  const crear = modo === "crear";
  form.dataset.modo = modo;
  $("#campoNombre").hidden = !crear;
  $("#notaCrear").hidden = !crear;
  $("#btnEnviar").textContent = crear ? "Crear cuenta" : "Entrar";
  $("#cambioTxt").textContent = crear ? "¿Ya tenés cuenta?" : "¿Primera vez?";
  $("#btnModo").textContent = crear ? "Entrar" : "Crear cuenta";
  $("#fClave").setAttribute("autocomplete", crear ? "new-password" : "current-password");
  $("#entrarBajada").textContent = crear
    ? "Con tu correo y una contraseña alcanza. Lo que compres con la sesión abierta queda guardado solo."
    : "Las compras que guardes en tu cuenta te siguen aunque cambies de aparato.";
  mostrarError("");
}

function mostrarError(msg) {
  const p = $("#formError");
  p.hidden = !msg;
  p.textContent = msg || "";
}

$("#btnModo").addEventListener("click", () => {
  ponerModo(form.dataset.modo === "crear" ? "entrar" : "crear");
  $("#fMail").focus();
});

form.addEventListener("submit", async e => {
  e.preventDefault();
  if (!Cuenta) { mostrarError("No se pudo cargar la cuenta. Recargá la página."); return; }
  const crear = form.dataset.modo === "crear";
  const email = $("#fMail").value.trim();
  const clave = $("#fClave").value;
  const nombre = $("#fNombre").value.trim();

  $("#fMail").setAttribute("aria-invalid", String(!EMAIL_RE.test(email)));
  if (!EMAIL_RE.test(email)) { mostrarError("Escribí un correo válido."); $("#fMail").focus(); return; }
  const claveMal = crear ? clave.length < 8 : !clave;
  $("#fClave").setAttribute("aria-invalid", String(claveMal));
  if (claveMal) {
    mostrarError(crear ? "La contraseña tiene que tener al menos 8 caracteres." : "Escribí tu contraseña.");
    $("#fClave").focus();
    return;
  }
  mostrarError("");

  const btn = $("#btnEnviar");
  btn.disabled = true;
  btn.textContent = crear ? "Creando…" : "Entrando…";
  try {
    if (crear) await Cuenta.crear({ email, password: clave, nombre: nombre || undefined });
    else await Cuenta.entrar(email, clave);
    $("#fClave").value = "";
    avisar(crear ? "Tu cuenta quedó creada." : "Entraste a tu cuenta.");
    pintar();
  } catch (err) {
    /* 409 al crear: ese correo ya tiene cuenta. El formulario pasa a
       "Entrar" con el correo puesto; sólo falta la clave. */
    if (crear && err.status === 409) { ponerModo("entrar"); }
    mostrarError(err.message);
    $("#fClave").focus();
  } finally {
    btn.disabled = false;
    btn.textContent = form.dataset.modo === "crear" ? "Crear cuenta" : "Entrar";
  }
});

$("#btnSalir").addEventListener("click", async () => {
  if (!Cuenta) return;
  await Cuenta.salir();
  ponerModo("entrar");
  avisar("Saliste de tu cuenta.");
  pintar();
});

document.addEventListener("click", e => {
  const q = e.target.closest("[data-quitar]");
  if (q) { quitar(q.dataset.quitar); return; }
  const v = e.target.closest("[data-vincular]");
  if (v) vincular(v.dataset.vincular, v);
});

pintar();
})();
