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

// las tareas 5 a 7 la reemplazan
async function pantallaEventos() { $("#main").innerHTML = "<p>…</p>"; }

/* ── arranque: si ya había sesión, entrar directo ── */
(async () => {
  try {
    if (await cargarPerfil()) arrancarApp();
  } catch { /* sesión vieja o cuenta deshabilitada: queda la pantalla de entrar */ }
})();

window.ADMIN = { S, sb, mostrar, avisar, esc };   // para las tareas siguientes
})();
