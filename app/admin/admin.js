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
  const { data, error } = await sb.from("perfiles")
    .select("id,nombre,rol,organizador_id,activo").eq("id", user.id).maybeSingle();
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
  { id: "eventos", txt: "Eventos", roles: ["admin", "staff"] },
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
    const { data } = await sb.from("eventos").select("*").eq("id", id).single();
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
        <input id="fSlug" value="${esc(e.slug)}" pattern="[a-z0-9-]{2,60}" required>
        <em class="ayuda">/${esc(CFG.ORGANIZADOR)}/<b id="vistaSlug">${esc(e.slug || "…")}</b></em></label>
      <label><span>Lugar</span><input id="fLugar" value="${esc(e.lugar || "")}"></label>
      <label><span>Fecha</span><input id="fFecha" type="date" value="${e.fecha || ""}" required></label>
      <label><span>Hora</span><input id="fHora" type="time" value="${String(e.hora_inicio).slice(0,5)}"></label>
      <label><span>Edad mínima</span><input id="fEdad" type="number" min="0" max="99" value="${e.edad_min}"></label>
      <label><span>Máximo de entradas por compra</span>
        <input id="fTope" type="number" min="1" max="50" value="${e.tope_entradas_orden}"></label>
      <div class="acciones">
        <button class="btn primario" id="btnGuardar">Guardar</button>
        ${id ? `<button type="button" class="btn plano" id="btnEntradas">Entradas y precios →</button>` : ""}
      </div>
      <p class="error" id="fError"></p>
    </form>`;

  $("#btnVolver").onclick = () => mostrar("eventos");
  $("#fSlug").oninput = ev => $("#vistaSlug").textContent = ev.target.value || "…";
  if (id) $("#btnEntradas").onclick = () => pantallaEntradas(id);

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

  const [ev, tipos, fases, precios] = await Promise.all([
    sb.from("eventos").select("id,nombre,estado").eq("id", eventoId).single(),
    sb.from("tipo_entrada").select("*").eq("evento_id", eventoId).order("orden"),
    sb.from("evento_fase").select("*").eq("evento_id", eventoId).order("orden"),
    sb.from("fase_precio").select("*"),
  ]);
  const T = tipos.data || [], F = fases.data || [];
  const idsFase = new Set(F.map(f => f.id));
  const P = new Map((precios.data || [])
    .filter(p => idsFase.has(p.fase_id))
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
  $("#btnGuardarGrilla").onclick = () => guardarGrilla(eventoId, P);
  zonaPublicar(eventoId, ev.data.estado);
}

function ventana(f) {
  const d = x => x ? new Date(x).toLocaleDateString("es-BO", { day: "numeric", month: "short" }) : "";
  if (!f.desde && !f.hasta) return "siempre";
  return `${d(f.desde)} → ${d(f.hasta) || "sin fin"}`;
}

async function guardarGrilla(eventoId, P) {
  const filas = [], borrar = [];
  document.querySelectorAll(".celda-precio").forEach(inp => {
    const f = inp.dataset.f, t = inp.dataset.t;
    const cupoInp = document.querySelector(`.celda-cupo[data-f="${f}"][data-t="${t}"]`);
    const precio = inp.value.trim();
    if (precio === "") { if (P.has(`${f}|${t}`)) borrar.push({ f, t }); return; }
    filas.push({ organizador_id: S.yo.organizador_id, fase_id: f, tipo_id: t,
                 precio: Number(precio),
                 cupo: cupoInp.value.trim() === "" ? null : Number(cupoInp.value) });
  });

  for (const b of borrar) {
    await sb.from("fase_precio").delete().eq("fase_id", b.f).eq("tipo_id", b.t);
  }
  if (filas.length) {
    const { error } = await sb.from("fase_precio")
      .upsert(filas, { onConflict: "fase_id,tipo_id" });
    if (error) { avisar("No se pudo guardar: " + error.message); return; }
  }
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
async function zonaPublicar(eventoId, estado) {
  const { data: chequeo } = await sb.rpc("listo_para_publicar", { p_evento: eventoId });
  const listo = chequeo && chequeo.ok;
  const faltan = (chequeo && chequeo.faltan) || [];
  const publicado = estado === "publicado";
  const url = `${location.origin}/${CFG.ORGANIZADOR}/`;

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
      </div>
      <button class="btn ${publicado ? "plano" : "primario"}" id="btnPublicar"
        ${!publicado && !listo ? "disabled" : ""}>
        ${publicado ? "Quitar de la venta" : "Poner a la venta"}</button>
    </div>`;

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

/* ── arranque: si ya había sesión, entrar directo ── */
(async () => {
  try {
    if (await cargarPerfil()) arrancarApp();
  } catch { /* sesión vieja o cuenta deshabilitada: queda la pantalla de entrar */ }
})();

window.ADMIN = { S, sb, mostrar, avisar, esc };   // para las tareas siguientes
})();
