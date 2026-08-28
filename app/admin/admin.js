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

/* ── arranque: si ya había sesión, entrar directo ── */
(async () => {
  try {
    if (await cargarPerfil()) arrancarApp();
  } catch { /* sesión vieja o cuenta deshabilitada: queda la pantalla de entrar */ }
})();

window.ADMIN = { S, sb, mostrar, avisar, esc };   // para las tareas siguientes
})();
