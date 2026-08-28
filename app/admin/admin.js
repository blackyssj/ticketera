/* Administración de la ticketera.
   El staff está autenticado, así que la guardia es RLS: este archivo habla
   directo con PostgREST y NO valida permisos — los valida la base. Cualquier
   `if (rol === ...)` de acá es comodidad de interfaz, nunca seguridad. */
(() => {
"use strict";

const CFG = window.CONFIG;
const sb = window.supabase.createClient(CFG.SUPABASE_URL, CFG.SUPABASE_ANON_KEY);

const S = { yo: null, pantalla: "eventos", evento: null };
const $ = s => document.querySelector(s);
const esc = s => String(s ?? "").replace(/[&<>"']/g, c =>
  ({ "&":"&amp;", "<":"&lt;", ">":"&gt;", '"':"&quot;", "'":"&#39;" }[c]));

let tToast;
function avisar(txt) {
  const t = $("#toast");
  t.textContent = txt; t.dataset.on = "1";
  clearTimeout(tToast);
  tToast = setTimeout(() => t.dataset.on = "0", 4000);
}

/* El usuario no tiene correo: se le arma uno sintético, igual que en Puerta.
   Es un identificador, no una casilla — no hay recuperación por correo. */
const correoDe = u => `${u.trim().toLowerCase()}@ticketera.local`;

async function entrar(usuario, clave) {
  const { error } = await sb.auth.signInWithPassword(
    { email: correoDe(usuario), password: clave });
  if (error) throw new Error("Usuario o clave incorrectos.");
  await cargarPerfil();
}

async function cargarPerfil() {
  const { data: { user } } = await sb.auth.getUser();
  if (!user) return false;
  /* El slug viene acá y no se pide después: es lo que arma el ?r= del link
     de venta, o sea lo primero que la pantalla del relacionador tiene que
     poder decidir — si mostrar el link o explicar que le falta el código. */
  const { data, error } = await sb.from("perfiles")
    .select("id,nombre,rol,organizador_id,activo,slug").eq("id", user.id).maybeSingle();
  if (error || !data || !data.activo) {
    await sb.auth.signOut();
    throw new Error("Tu cuenta no está habilitada.");
  }
  S.yo = data;
  return true;
}

$("#formEntrar").addEventListener("submit", async e => {
  e.preventDefault();
  $("#eError").textContent = "";
  $("#btnEntrar").disabled = true;
  try {
    await entrar($("#eUsuario").value, $("#eClave").value);
    arrancarApp();
  } catch (err) {
    $("#eError").textContent = err.message;
  } finally {
    $("#btnEntrar").disabled = false;
  }
});

$("#btnSalir").addEventListener("click", async () => {
  await sb.auth.signOut();
  location.reload();
});

/* El rol decide qué pestañas se ven. La base decide qué se puede hacer. */
const PANTALLAS = [
  { id: "eventos",   txt: "Eventos",    roles: ["admin", "staff"] },
  { id: "misventas", txt: "Mis ventas", roles: ["rrpp"] },
  { id: "puerta",    txt: "Puerta",     roles: ["portero", "admin"] },
];

function arrancarApp() {
  $("#pantallaEntrar").hidden = true;
  $("#app").hidden = false;
  $("#yo").textContent = `${S.yo.nombre} · ${S.yo.rol}`;
  const mias = PANTALLAS.filter(p => p.roles.includes(S.yo.rol));
  $("#tabs").innerHTML = mias.map(p =>
    `<button data-p="${p.id}"${p.id === S.pantalla ? ' aria-current="page"' : ""}>${esc(p.txt)}</button>`
  ).join("");
  if (!mias.some(p => p.id === S.pantalla) && mias.length) S.pantalla = mias[0].id;
  mostrar(S.pantalla);
}

$("#tabs").addEventListener("click", e => {
  const b = e.target.closest("button[data-p]");
  if (b) mostrar(b.dataset.p);
});

function mostrar(p) {
  S.pantalla = p;
  document.querySelectorAll("#tabs button").forEach(b =>
    b.toggleAttribute("aria-current", b.dataset.p === p));
  if (p === "eventos") return pantallaEventos();
  if (p === "misventas") return pantallaMisVentas();
  if (p === "puerta") return window.PUERTA.pantalla();   // vive en puerta.js
  $("#main").innerHTML = "";
}

const fmtF = f => new Date(f + "T00:00:00-04:00")
  .toLocaleDateString("es-BO", { day: "numeric", month: "short", year: "numeric" });
const bs = n => Number(n || 0).toLocaleString("es-BO") + " Bs";

const ESTADOS = {
  borrador:  { txt: "Borrador",  cls: "gris" },
  publicado: { txt: "A la venta", cls: "verde" },
  cerrado:   { txt: "Cerrado",   cls: "gris" },
};

async function pantallaEventos() {
  $("#main").innerHTML = `<p class="cargando">Cargando eventos…</p>`;
  const { data, error } = await sb.from("eventos")
    .select("id,slug,nombre,fecha,estado,lugar")
    .order("fecha", { ascending: false });
  if (error) { $("#main").innerHTML = `<p class="error">${esc(error.message)}</p>`; return; }

  $("#main").innerHTML = `
    <div class="cab-seccion">
      <h2>Eventos</h2>
      <button class="btn primario" id="btnNuevo">Nuevo evento</button>
    </div>
    ${data.length ? `<ul class="lista">${data.map(e => `
      <li class="fila" data-ev="${e.id}">
        <span class="fila-nombre">${esc(e.nombre)}</span>
        <span class="pastilla ${ESTADOS[e.estado].cls}">${ESTADOS[e.estado].txt}</span>
        <span class="fila-dato">${fmtF(e.fecha)}</span>
        <span class="fila-dato tenue">${esc(e.lugar || "")}</span>
      </li>`).join("")}</ul>`
      : `<p class="vacio">Todavía no hay eventos. Creá el primero.</p>`}`;

  $("#btnNuevo").onclick = () => abrirEvento(null);
  document.querySelectorAll("#main .fila").forEach(f =>
    f.onclick = () => abrirEvento(f.dataset.ev));
}

/* Alta y edición en el mismo formulario: son los mismos campos, y tener dos
   pantallas casi iguales garantiza que una se olvide de un campo. */
async function abrirEvento(id) {
  let e = { nombre: "", slug: "", lugar: "", fecha: "", hora_inicio: "21:00",
            edad_min: 18, tope_entradas_orden: 10, estado: "borrador" };
  if (id) {
    const { data, error } = await sb.from("eventos").select("*").eq("id", id).single();
    if (error || !data) {
      avisar("Ese evento ya no existe.");
      mostrar("eventos");
      return;
    }
    e = data;
  }
  $("#main").innerHTML = `
    <div class="cab-seccion">
      <button class="btn plano chico" id="btnVolver">← Eventos</button>
      <h2>${id ? esc(e.nombre) : "Nuevo evento"}</h2>
    </div>
    <form class="form-evento" id="formEvento">
      <label><span>Nombre</span><input id="fNombre" value="${esc(e.nombre)}" required></label>
      <label><span>Link público</span>
        <input id="fSlug" value="${esc(e.slug)}" pattern="[a-z0-9\\-]{2,60}" required>
        <em class="ayuda">/${esc(CFG.ORGANIZADOR)}/<b id="vistaSlug">${esc(e.slug || "…")}</b></em></label>
      <label><span>Lugar</span><input id="fLugar" value="${esc(e.lugar || "")}"></label>
      <label><span>Fecha</span><input id="fFecha" type="date" value="${e.fecha || ""}" required></label>
      <label><span>Hora</span><input id="fHora" type="time" value="${String(e.hora_inicio).slice(0,5)}"></label>
      <label><span>Edad mínima</span><input id="fEdad" type="number" min="0" max="99" value="${e.edad_min}"></label>
      <label><span>Máximo de entradas por compra</span>
        <input id="fTope" type="number" min="1" max="50" value="${e.tope_entradas_orden}"></label>
      <div class="acciones">
        <button class="btn primario" id="btnGuardar">Guardar</button>
        ${id ? `<button type="button" class="btn plano" id="btnEntradas">Entradas y precios →</button>
               <button type="button" class="btn plano" id="btnRrpp">Relacionadores →</button>` : ""}
      </div>
      <p class="error" id="fError"></p>
    </form>`;

  $("#btnVolver").onclick = () => mostrar("eventos");
  $("#fSlug").oninput = ev => $("#vistaSlug").textContent = ev.target.value || "…";
  if (id) {
    $("#btnEntradas").onclick = () => pantallaEntradas(id);
    $("#btnRrpp").onclick = () => pantallaRelacionadores(id);
  }

  $("#formEvento").onsubmit = async ev => {
    ev.preventDefault();
    $("#fError").textContent = "";
    const fila = {
      organizador_id: S.yo.organizador_id,
      nombre: $("#fNombre").value.trim(),
      slug: $("#fSlug").value.trim().toLowerCase(),
      lugar: $("#fLugar").value.trim() || null,
      fecha: $("#fFecha").value,
      hora_inicio: $("#fHora").value || "21:00",
      edad_min: Number($("#fEdad").value),
      tope_entradas_orden: Number($("#fTope").value),
    };
    const q = id ? sb.from("eventos").update(fila).eq("id", id)
                 : sb.from("eventos").insert(fila).select("id").single();
    const { data, error } = await q;
    if (error) {
      // 23505 = unique_violation: el slug ya existe EN ESTE organizador
      $("#fError").textContent = error.code === "23505"
        ? "Ya tenés un evento con ese link. Elegí otro."
        : error.message;
      return;
    }
    avisar("Evento guardado.");
    id ? mostrar("eventos") : abrirEvento(data.id);
  };
}

/* La grilla es fases × tipos porque el precio vive en el cruce. Con dos
   listas separadas el organizador no ve que "General" cuesta distinto en
   cada fase, y eso es justamente lo que está vendiendo. */
async function pantallaEntradas(eventoId) {
  $("#main").innerHTML = `<p class="cargando">Cargando…</p>`;

  const [ev, tipos, fases] = await Promise.all([
    sb.from("eventos").select("id,nombre,estado,slug").eq("id", eventoId).single(),
    sb.from("tipo_entrada").select("*").eq("evento_id", eventoId).order("orden"),
    sb.from("evento_fase").select("*").eq("evento_id", eventoId).order("orden"),
  ]);
  const T = tipos.data || [], F = fases.data || [];
  /* fase_precio sin filtro traía las de TODO el organizador, y PostgREST
     corta en 1000 filas sin avisar: un precio fuera del corte desaparecía
     de la pantalla y, como el código creía que no existía, dejar la
     celda vacía tampoco lo borraba — quedaba invisible pero vendiendo.
     Acá ya tenemos los ids de fase de este evento, así que se filtra del
     lado del servidor con ellos. */
  const idsFase = F.map(f => f.id);
  const precios = idsFase.length
    ? await sb.from("fase_precio").select("*").in("fase_id", idsFase)
    : { data: [] };
  const P = new Map((precios.data || [])
    .map(p => [`${p.fase_id}|${p.tipo_id}`, p]));

  $("#main").innerHTML = `
    <div class="cab-seccion">
      <button class="btn plano chico" id="btnVolver">← ${esc(ev.data.nombre)}</button>
      <h2>Entradas y precios</h2>
    </div>
    <div class="grilla-envoltorio">
      <table class="grilla">
        <thead><tr><th>Tipo</th>
          ${F.map(f => `<th>${esc(f.nombre)}<em>${ventana(f)}</em></th>`).join("")}
          <th class="col-accion"><button class="btn plano chico" id="btnFase">+ Fase</button></th>
        </tr></thead>
        <tbody>
          ${T.map(t => `<tr data-tipo="${t.id}">
            <th>${esc(t.nombre)}<em>${esc(t.descripcion || "")}</em></th>
            ${F.map(f => {
              const p = P.get(`${f.id}|${t.id}`);
              return `<td>
                <input class="celda-precio" data-f="${f.id}" data-t="${t.id}"
                       type="number" min="0" step="1" placeholder="—"
                       value="${p ? Number(p.precio) : ""}" aria-label="Precio">
                <input class="celda-cupo" data-f="${f.id}" data-t="${t.id}"
                       type="number" min="1" placeholder="sin tope"
                       value="${p && p.cupo != null ? p.cupo : ""}" aria-label="Cupo">
              </td>`;
            }).join("")}
            <td class="col-accion"></td></tr>`).join("")}
        </tbody>
      </table>
    </div>
    <div class="acciones">
      <button class="btn plano" id="btnTipo">+ Tipo de entrada</button>
      <button class="btn primario" id="btnGuardarGrilla">Guardar precios</button>
    </div>
    <p class="ayuda">Precio vacío = ese tipo no se vende en esa fase. Cupo vacío = sin tope.</p>
    <div id="zonaPublicar"></div>`;

  $("#btnVolver").onclick = () => abrirEvento(eventoId);
  $("#btnTipo").onclick = () => nuevoTipo(eventoId);
  $("#btnFase").onclick = () => nuevaFase(eventoId);
  $("#btnGuardarGrilla").onclick = () => guardarGrilla(eventoId);
  zonaPublicar(eventoId, ev.data.estado, ev.data.slug);
}

function ventana(f) {
  const d = x => x ? new Date(x).toLocaleDateString("es-BO", { day: "numeric", month: "short" }) : "";
  if (!f.desde && !f.hasta) return "siempre";
  return `${d(f.desde)} → ${d(f.hasta) || "sin fin"}`;
}

/* Antes: un .delete() por celda vaciada y después un .upsert() con el
   resto — requests HTTP separados, sin transacción. Si el upsert fallaba,
   los borrados ya estaban aplicados y la base perdía precios mientras se
   avisaba "no se pudo guardar". Y el error de cada .delete() no se leía
   nunca. guardar_precios() hace las dos cosas en una sola llamada — la
   misma transacción — y deja en la base exactamente las filas de
   p_filas para las fases del evento. */
async function guardarGrilla(eventoId) {
  const filas = [];
  const vistos = new Set();
  document.querySelectorAll(".celda-precio").forEach(inp => {
    const f = inp.dataset.f, t = inp.dataset.t;
    const precio = inp.value.trim();
    if (precio === "") return;   // vacío = ese tipo no se vende en esa fase
    const clave = `${f}|${t}`;
    // guardar_precios() no se defiende de pares fase+tipo repetidos y
    // fallaría con un error feo de Postgres. Con esta grilla no puede
    // pasar (un input por cruce), pero deduplicar es barato y saca la
    // dependencia de que el render nunca cambie.
    if (vistos.has(clave)) return;
    vistos.add(clave);
    const cupoInp = document.querySelector(`.celda-cupo[data-f="${f}"][data-t="${t}"]`);
    filas.push({ fase_id: f, tipo_id: t,
                 precio: Number(precio),
                 cupo: cupoInp.value.trim() === "" ? null : Number(cupoInp.value) });
  });

  const { error } = await sb.rpc("guardar_precios", { p_evento: eventoId, p_filas: filas });
  if (error) { avisar("No se pudo guardar: " + error.message); return; }
  avisar("Precios guardados.");
  pantallaEntradas(eventoId);
}

async function nuevoTipo(eventoId) {
  const nombre = prompt("Nombre del tipo de entrada (General, VIP, Palco…)");
  if (!nombre) return;
  const { error } = await sb.from("tipo_entrada").insert({
    organizador_id: S.yo.organizador_id, evento_id: eventoId,
    nombre: nombre.trim(), orden: Date.parse(new Date().toISOString()) % 1000 });
  if (error) {
    avisar(error.code === "23505" ? "Ya existe un tipo con ese nombre." : error.message);
    return;
  }
  pantallaEntradas(eventoId);
}

async function nuevaFase(eventoId) {
  const nombre = prompt("Nombre de la fase (Preventa 1, General…)");
  if (!nombre) return;
  const hasta = prompt("¿Hasta qué día vale? (AAAA-MM-DD, vacío = sin fin)");
  /* orden fijo en 0 empataba con `order by orden` — Postgres desempataba a
     su antojo y fase_vigente() podía resolver la fase incorrecta. Acá se
     calcula el siguiente a partir del máximo que ya tenga el evento. */
  const { data: ultima } = await sb.from("evento_fase").select("orden")
    .eq("evento_id", eventoId).order("orden", { ascending: false }).limit(1);
  const orden = (ultima && ultima[0] ? ultima[0].orden : -1) + 1;
  const { error } = await sb.from("evento_fase").insert({
    organizador_id: S.yo.organizador_id, evento_id: eventoId,
    nombre: nombre.trim(), desde: new Date().toISOString(),
    hasta: hasta ? `${hasta}T23:59:00-04:00` : null, orden });
  if (error) { avisar(error.message); return; }
  pantallaEntradas(eventoId);
}

/* El chequeo se muestra ANTES de que el organizador apriete, no como error
   después. Un botón que se puede apretar y siempre falla enseña a ignorar
   los mensajes. */
async function zonaPublicar(eventoId, estado, slug) {
  const { data: chequeo } = await sb.rpc("listo_para_publicar", { p_evento: eventoId });
  const listo = chequeo && chequeo.ok;
  const faltan = (chequeo && chequeo.faltan) || [];
  const publicado = estado === "publicado";
  const url = `${location.origin}/${CFG.ORGANIZADOR}/${slug}`;

  $("#zonaPublicar").innerHTML = `
    <div class="publicar ${publicado ? "vivo" : ""}">
      <div>
        <h3>${publicado ? "A la venta" : "Sin publicar"}</h3>
        <p>${publicado
          ? `Cualquiera con el link puede comprar.`
          : listo
            ? "Está todo listo para ponerlo a la venta."
            : "Falta esto antes de poder publicarlo:"}</p>
        ${!publicado && !listo
          ? `<ul class="faltan">${faltan.map(f => `<li>${esc(f)}</li>`).join("")}</ul>` : ""}
        ${publicado ? `<p class="link-publico">
          <code id="linkPublico">${esc(url)}</code>
          <button type="button" class="btn plano chico" data-copiar="linkPublico">Copiar link</button>
        </p>` : ""}
      </div>
      <button class="btn ${publicado ? "plano" : "primario"}" id="btnPublicar"
        ${!publicado && !listo ? "disabled" : ""}>
        ${publicado ? "Quitar de la venta" : "Poner a la venta"}</button>
    </div>`;

  cablearCopiar();

  $("#btnPublicar").onclick = async () => {
    const { data, error } = await sb.rpc("publicar_evento",
      { p_evento: eventoId, p_publicar: !publicado });
    if (error) {
      avisar(error.message.replace(/^.*NO_PUBLICABLE:\s*/, "Falta: "));
      return;
    }
    avisar(data.estado === "publicado" ? "El evento está a la venta." : "Quitado de la venta.");
    pantallaEntradas(eventoId);
  };
}

/* ── copiar un link ──
   navigator.clipboard no existe fuera de contexto seguro (http pelado, una
   IP en la red del boliche) y puede fallar por permisos. Un botón "Copiar"
   que no copia y no avisa es peor que no tener botón: el relacionador cree
   que lo tiene, pega lo que hubiera en el portapapeles y esa venta no se le
   atribuye a nadie. El plan B deja el link seleccionado para el Ctrl+C de
   siempre, que funciona en todos lados. */
function cablearCopiar() {
  document.querySelectorAll("#main [data-copiar]").forEach(b =>
    b.onclick = () => copiarNodo(document.getElementById(b.dataset.copiar)));
}

async function copiarNodo(nodo) {
  if (!nodo) return;
  try {
    if (!navigator.clipboard) throw new Error("sin portapapeles");
    await navigator.clipboard.writeText(nodo.textContent);
    avisar("Link copiado.");
  } catch {
    const r = document.createRange();
    r.selectNodeContents(nodo);
    const sel = getSelection();
    sel.removeAllRanges();
    sel.addRange(r);
    avisar("No se pudo copiar solo. El link quedó seleccionado: copialo a mano.");
  }
}

/* ══ el relacionador ══════════════════════════════════════════════
   El orden de esta pantalla no es negociable: primero el link, después la
   plata. El link lo copia todos los días y es a lo que entra; lo que ganó
   lo mira una vez por semana. Al revés tendría que buscar lo urgente abajo
   de lo interesante.

   Nada de lo que se muestra acá lo elige el frontend: mis_ventas() filtra
   por auth.uid() adentro y no acepta un id de persona, así que ni con la
   consola abierta se puede pedir lo del compañero. */
async function pantallaMisVentas() {
  $("#main").innerHTML = `<p class="cargando">Cargando tus ventas…</p>`;

  /* Los eventos se acotan del lado del servidor por dos motivos: un evento
     en borrador no se puede comprar (crear_orden exige `publicado`), o sea
     que su link nace roto; y filtrar acá y no en JS es lo que evita que el
     corte mudo de 1000 filas de PostgREST se coma justo el de esta semana. */
  const [rv, re] = await Promise.all([
    sb.rpc("mis_ventas", {}),
    sb.from("eventos").select("id,slug,nombre,fecha")
      .eq("estado", "publicado").order("fecha", { ascending: true }),
  ]);
  if (rv.error) {
    $("#main").innerHTML = `<p class="error">${esc(rv.error.message)}</p>`;
    return;
  }
  const ventas = rv.data || [];
  const entradas = ventas.reduce((a, v) => a + Number(v.entradas || 0), 0);
  const total = ventas.reduce((a, v) => a + Number(v.comision || 0), 0);

  $("#main").innerHTML = `
    <div class="cab-seccion"><h2>Mis ventas</h2></div>

    <section class="tarjeta">
      <h3>Tu link de venta</h3>
      <p class="ayuda">Todo lo que se compre entrando por acá queda a tu nombre.</p>
      ${zonaLinks(re.data || [], re.error)}
    </section>

    <h3 class="titulo-bloque">Lo que vendiste</h3>
    ${ventas.length ? `
      <ul class="lista">${ventas.map(v => `
        <li class="fila quieta venta">
          <span class="fila-nombre">${esc(v.evento_nombre)}
            <em>${fmtF(v.evento_fecha)}</em></span>
          <span class="cifra">${v.entradas}<em>entradas</em></span>
          <span class="cifra">${bs(v.recaudado)}<em>recaudado</em></span>
          <span class="cifra destacada">${bs(v.comision)}
            <em>${v.entradas} × ${bs(v.comision_unitaria)}</em></span>
        </li>`).join("")}</ul>
      <div class="total">
        <div>
          <h3>Tu comisión</h3>
          <p>${entradas} ${entradas === 1 ? "entrada" : "entradas"} en
             ${ventas.length} ${ventas.length === 1 ? "evento" : "eventos"}</p>
        </div>
        <span class="monto">${bs(total)}</span>
      </div>`
    : `<p class="vacio">Todavía no vendiste nada. En cuanto alguien compre
         entrando por tu link y pague, acá aparecen las entradas y tu comisión.</p>`}`;

  cablearCopiar();
}

/* Un link con el ?r= vacío no falla: se vende igual y la venta no es de
   nadie. El relacionador reparte el link toda la noche creyendo que está
   vendiendo a su nombre y el lunes su comisión da cero, sin nada que
   explique por qué. Por eso sin slug no hay link — hay un cartel que dice
   qué falta y quién lo destraba. */
function zonaLinks(eventos, error) {
  if (!S.yo.slug) return `<p class="nota">Todavía no tenés tu código de
    relacionador, así que el link no se puede armar. Pedíselo a un
    administrador: te lo carga en tu perfil y el link aparece acá solo.</p>`;
  if (error) return `<p class="error">No se pudieron cargar los eventos: ${esc(error.message)}</p>`;
  if (!eventos.length) return `<p class="nota">Todavía no hay ningún evento a la
    venta. Cuando el organizador publique uno, tu link aparece acá.</p>`;

  return eventos.map((e, i) => {
    const url = `${location.origin}/${CFG.ORGANIZADOR}/${e.slug}` +
                `?r=${encodeURIComponent(S.yo.slug)}`;
    return `<div class="link-evento">
      <span class="link-titulo">${esc(e.nombre)} · ${fmtF(e.fecha)}</span>
      <p class="link-publico">
        <code id="lkr${i}">${esc(url)}</code>
        <button type="button" class="btn plano chico" data-copiar="lkr${i}">Copiar</button>
      </p>
    </div>`;
  }).join("");
}

/* El desglose por persona vive DENTRO del evento y no en una pestaña
   suelta: se abre cuando hay que pagar, y para pagar hay que saber de qué
   noche se está hablando. ventas_por_rrpp() ya lo devuelve ordenado por
   comisión descendente, que es el orden en el que se paga; no se reordena
   acá para que el admin y el relacionador vean la misma cuenta.
   La guardia es puede_editar() adentro de la función: a un rrpp que llegue
   por consola le contesta "Sin permiso", no una lista vacía. */
async function pantallaRelacionadores(eventoId) {
  $("#main").innerHTML = `<p class="cargando">Cargando…</p>`;
  const [ev, rr] = await Promise.all([
    sb.from("eventos").select("id,nombre").eq("id", eventoId).single(),
    sb.rpc("ventas_por_rrpp", { p_evento: eventoId }),   // sin default: se pasa siempre
  ]);
  if (ev.error || !ev.data) {
    avisar("Ese evento ya no existe.");
    mostrar("eventos");
    return;
  }

  const filas = rr.data || [];
  const entradas = filas.reduce((a, v) => a + Number(v.entradas || 0), 0);
  const total = filas.reduce((a, v) => a + Number(v.comision || 0), 0);

  $("#main").innerHTML = `
    <div class="cab-seccion">
      <button class="btn plano chico" id="btnVolver">← ${esc(ev.data.nombre)}</button>
      <h2>Relacionadores</h2>
    </div>
    ${rr.error ? `<p class="error">${esc(rr.error.message)}</p>` : ""}
    ${filas.length ? `
      <ul class="lista">${filas.map(v => `
        <li class="fila quieta venta">
          <span class="fila-nombre">${esc(v.nombre)}
            <em>${v.slug ? "?r=" + esc(v.slug) : "sin código"}</em></span>
          <span class="cifra">${v.entradas}<em>entradas</em></span>
          <span class="cifra">${bs(v.recaudado)}<em>recaudado</em></span>
          <span class="cifra destacada">${bs(v.comision)}
            <em>${v.entradas} × ${bs(v.comision_unitaria)}</em></span>
        </li>`).join("")}</ul>
      <div class="total">
        <div>
          <h3>Total a pagar</h3>
          <p>${entradas} ${entradas === 1 ? "entrada" : "entradas"} de
             ${filas.length} ${filas.length === 1 ? "relacionador" : "relacionadores"}</p>
        </div>
        <span class="monto">${bs(total)}</span>
      </div>`
    : rr.error ? "" : `<p class="vacio">Nadie vendió con su link en este evento
        todavía. Aparecen acá en cuanto se pague la primera orden que entró
        por un ?r=.</p>`}`;

  $("#btnVolver").onclick = () => abrirEvento(eventoId);
}

/* ── arranque: si ya había sesión, entrar directo ── */
(async () => {
  try {
    if (await cargarPerfil()) arrancarApp();
  } catch { /* sesión vieja o cuenta deshabilitada: queda la pantalla de entrar */ }
})();

window.ADMIN = { S, sb, mostrar, avisar, esc };   // para las tareas siguientes
})();
