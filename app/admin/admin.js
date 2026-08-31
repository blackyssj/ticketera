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
  /* El slug del organizador se trae acá porque de él cuelgan todos los links
     públicos que muestra el panel. Antes salían de CFG.ORGANIZADOR, que es
     una constante: La Manzana veía sus eventos con el link de Amstel. Ahora
     esa constante ya no existe. Si la consulta falla no se corta la sesión —
     el panel entero no puede caerse porque no se pudo armar un link. */
  await miOrganizadorSlug().catch(() => null);
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
  { id: "equipo",    txt: "Equipo",     roles: ["admin"] },
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
  if (p === "equipo") return pantallaEquipo();
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
        <em class="ayuda">/${esc(S.orgSlug || "…")}/<b id="vistaSlug">${esc(e.slug || "…")}</b></em></label>
      <label><span>Lugar</span><input id="fLugar" value="${esc(e.lugar || "")}"></label>
      <label><span>Fecha</span><input id="fFecha" type="date" value="${e.fecha || ""}" required></label>
      <label><span>Hora</span><input id="fHora" type="time" value="${String(e.hora_inicio).slice(0,5)}"></label>
      <label><span>Edad mínima</span><input id="fEdad" type="number" min="0" max="99" value="${e.edad_min}"></label>
      <label><span>Máximo de entradas por compra</span>
        <input id="fTope" type="number" min="1" max="50" value="${e.tope_entradas_orden}"></label>
      <div class="acciones">
        <button class="btn primario" id="btnGuardar">Guardar</button>
        ${id ? `<button type="button" class="btn plano" id="btnTablero">Tablero →</button>
               <button type="button" class="btn plano" id="btnEntradas">Entradas y precios →</button>
               <button type="button" class="btn plano" id="btnCortesias">Cortesías →</button>
               <button type="button" class="btn plano" id="btnRrpp">Relacionadores →</button>
               <button type="button" class="btn plano" id="btnCierre">Cierre y liquidación →</button>` : ""}
      </div>
      <p class="error" id="fError"></p>
    </form>
    ${id && puedeEditar() ? `<section class="tarjeta arte" id="zonaArte"></section>` : ""}`;

  $("#btnVolver").onclick = () => mostrar("eventos");
  $("#fSlug").oninput = ev => $("#vistaSlug").textContent = ev.target.value || "…";
  if (id) {
    $("#btnTablero").onclick = () => pantallaTablero(id);
    $("#btnEntradas").onclick = () => pantallaEntradas(id);
    $("#btnCortesias").onclick = () => pantallaCortesias(id);
    $("#btnRrpp").onclick = () => pantallaRelacionadores(id);
    $("#btnCierre").onclick = () => pantallaCierre(id);
    cablearArte(e);   // solo con evento guardado: sin slug no hay carpeta donde subir
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

/* ══ el arte de la entrada ════════════════════════════════════════
   El organizador sube UNA imagen y todas las entradas del evento se dibujan
   encima, con el QR sobre el arte — igual que en Bowie y BurTown. Hasta acá
   eso solo salía por `scripts/subir-arte.py`, o sea por una terminal que el
   organizador no tiene: el arte de su propia fiesta dependía de que alguien
   del equipo estuviera libre.

   Sube el navegador directo al bucket. Las policies de 0014 ya atan cada
   archivo a la carpeta de su organizador, así que no hace falta service_role
   ni una Edge Function en el medio. Y el bucket es de lectura pública pero
   NO listable: nadie enumera lo que subió otro. */

const ARTE_EXT  = { "image/png": "png", "image/jpeg": "jpg", "image/webp": "webp" };
const ARTE_TOPE = 5 * 1024 * 1024;

/* Comodidad de interfaz, no seguridad: la policy del bucket exige
   puede_editar() igual, y un rrpp ni siquiera tiene la pestaña de eventos. */
const puedeEditar = () => !!S.yo && (S.yo.rol === "admin" || S.yo.rol === "staff");

/* El slug del organizador de la SESIÓN: el que la policy del bucket compara
   con la primera carpeta de la ruta, y el que arma los links públicos. Se
   cachea en S.orgSlug apenas entra la sesión (cargarPerfil).
   La RLS de `organizadores` ya deja ver una sola fila: la propia. */
async function miOrganizadorSlug() {
  if (S.orgSlug) return S.orgSlug;
  const { data, error } = await sb.from("organizadores")
    .select("slug").eq("id", S.yo.organizador_id).maybeSingle();
  if (error || !data) throw new Error("No pude averiguar tu organizador, así que no sé dónde guardar la imagen.");
  S.orgSlug = data.slug;
  return data.slug;
}

/* El navegador cachea por URL. Cada subida estrena nombre, así que casi
   siempre alcanzaría; pero el arte que dejó el script vive en una ruta fija
   (evento.png) y ahí la URL SÍ se repite, y la vista previa se quedaría
   mostrando la vieja mientras el organizador cree que no subió nada. El ?v=
   es solo para mirar — a la base va la URL limpia, que es la que carga
   ticket.js y la que el escáner nunca ve. */
const conVersion = u => u + (u.includes("?") ? "&" : "?") + "v=" + Date.now();

/* La ruta sale de la URL guardada y no se recalcula: el arte pudo haberlo
   subido el script con otra extensión, y borrar una ruta adivinada es borrar
   el archivo de otro o ninguno. */
const rutaDeArte = u => {
  const m = String(u || "").match(/\/storage\/v1\/object\/public\/arte\/(.+)$/);
  return m ? decodeURIComponent(m[1].split("?")[0]) : null;
};

async function subirArte(archivo, ev, ext) {
  const org = await miOrganizadorSlug();
  /* El nombre del archivo lo armamos nosotros, con el slug GUARDADO del
     evento: ni el del input (que puede estar editado sin guardar y mandaría
     la imagen a una carpeta que no es la del evento) ni el del archivo del
     usuario — un nombre ajeno metido en una ruta es cómo se escribe donde no
     se debía. Los dos slugs son [a-z0-9-] por check de la base, así que la
     ruta no necesita escaparse.

     Y cada subida estrena archivo, con la hora en el nombre, en vez de pisar
     siempre `evento.<ext>` como hace el script. No es preferencia: el bucket
     no tiene policy de select a propósito — es lo que lo vuelve no listable —
     y sin poder LEER la fila, el storage no deja reemplazar (`upsert` es un
     `insert ... on conflict`, y para resolver el conflicto necesita ver la
     fila que pisa) ni borrar. Probado contra la base: con `upsert: true` toda
     subida vuelve "new row violates row-level security policy", incluso a una
     ruta que no existe. Escribir uno nuevo es lo único que el navegador puede
     hacer sin service_role, y no hay por qué aflojar el bucket para esto: la
     entrada mira `eventos.arte_url`, no el nombre del archivo.
     El anterior queda en el bucket sin que nada lo apunte. */
  const t = new Date();
  const dosDig = n => String(n).padStart(2, "0");
  const marca = `${t.getFullYear()}${dosDig(t.getMonth() + 1)}${dosDig(t.getDate())}` +
                `-${dosDig(t.getHours())}${dosDig(t.getMinutes())}${dosDig(t.getSeconds())}` +
                `-${String(t.getMilliseconds()).padStart(3, "0")}`;
  const ruta = `${org}/${ev.slug}/evento-${marca}.${ext}`;

  const { error: eSubida } = await sb.storage.from("arte")
    .upload(ruta, archivo, { contentType: archivo.type });
  if (eSubida) throw new Error("No se pudo subir la imagen: " + eSubida.message);

  const url = `${CFG.SUPABASE_URL}/storage/v1/object/public/arte/${ruta}`;
  /* Se piden las filas de vuelta (.select) a propósito: un update que RLS
     filtra no da error, contesta 204 y cero filas. Sin esto el caso más
     silencioso — el que no puede editar — vería "listo" con la imagen ya
     subida y el evento sin tocar. */
  const { data: filas, error: eFila } = await sb.from("eventos")
    .update({ arte_url: url }).eq("id", ev.id).select("id");
  /* La imagen quedó arriba pero el evento no la apunta: hay un archivo
     huérfano en el bucket y las entradas siguen saliendo como antes. Decirlo
     es lo único que evita que el organizador se vaya tranquilo con un arte
     que nadie va a ver. */
  if (eFila || !filas || !filas.length) throw new Error(
    "La imagen se subió pero NO quedó guardada en el evento" +
    (eFila ? " (" + eFila.message + ")" : " (la base no lo permitió)") +
    ". Las entradas siguen saliendo como antes: volvé a intentarlo.");
  return url;
}

/* La vista previa manda sobre la URL: el organizador reconoce su imagen de un
   vistazo y una dirección larga no le dice nada. Encima va marcada la caja
   del QR, que es el dato que hace que el arte salga bien a la primera en vez
   de con el código tapando el logo. */
function cablearArte(ev) {
  const caja = $("#zonaArte");
  if (!caja) return;

  const estado = (txt, cls) => {
    const n = $("#arteEstado");
    if (!n) return;
    n.textContent = txt;
    n.className = "arte-estado" + (cls ? " " + cls : "");
  };

  const pintar = () => {
    caja.innerHTML = `
      <h3>Arte de la entrada</h3>
      <p class="ayuda">Una sola imagen y todas las entradas del evento se
        dibujan encima. El recuadro marca dónde cae el QR: dejá esa zona
        despejada o va a tapar lo que haya debajo.</p>
      <div class="arte-cuerpo">
        ${ev.arte_url ? `
          <div class="arte-lienzo">
            <img src="${esc(conVersion(ev.arte_url))}" alt="Arte actual de las entradas de ${esc(ev.nombre)}">
            <span class="arte-qr" aria-hidden="true"><i>QR</i></span>
          </div>`
        : `<div class="arte-lienzo sin-arte">
            <span class="arte-qr" aria-hidden="true"><i>QR</i></span>
            <p>Sin arte propio. Las entradas salen con el diseño de la ticketera.</p>
          </div>`}
        <div class="arte-controles">
          <label><span>${ev.arte_url ? "Reemplazar imagen" : "Subir imagen"}</span>
            <input type="file" id="fArte" accept="image/png,image/jpeg,image/webp"></label>
          <p class="ayuda">PNG, JPG o WEBP, hasta 5 MB. Se sube apenas la elegís.</p>
          ${ev.arte_url ? `<button type="button" class="btn plano chico" id="btnQuitarArte">Quitar el arte</button>` : ""}
          <p class="arte-estado" id="arteEstado" role="status" aria-live="polite"></p>
        </div>
      </div>`;
    cablearControles();
  };

  const trabajando = si => {
    ["#fArte", "#btnQuitarArte"].forEach(s => { const n = $(s); if (n) n.disabled = si; });
  };

  function cablearControles() {
    $("#fArte").onchange = async e => {
      const f = e.target.files && e.target.files[0];
      e.target.value = "";   // elegir el mismo archivo dos veces tiene que volver a disparar
      if (!f) return;

      /* Tipo y tamaño se validan ACÁ, antes de mandar un solo byte: un
         rechazo del servidor después de subir 5 MB por el 4G de un boliche
         es una espera perdida y nada aprendido. Mismo criterio que el script. */
      const ext = ARTE_EXT[f.type];
      if (!ext) {
        estado(`Ese archivo es ${f.type || "de un tipo que no reconozco"}. Tiene que ser PNG, JPG o WEBP.`, "mal");
        return;
      }
      if (f.size > ARTE_TOPE) {
        estado(`La imagen pesa ${(f.size / 1024 / 1024).toFixed(1)} MB y el tope son 5 MB. Achicala y volvé a intentar.`, "mal");
        return;
      }

      trabajando(true);
      estado("Subiendo la imagen…", "trabajando");
      try {
        ev.arte_url = await subirArte(f, ev, ext);
        pintar();                      // se redibuja con ?v= nuevo: se ve la que acaba de subir
        estado("Listo. Esto es lo que va a salir en las entradas.", "ok");
        avisar("Arte actualizado.");
      } catch (err) {
        estado(err.message, "mal");
      } finally {
        trabajando(false);
      }
    };

    const btnQuitar = $("#btnQuitarArte");
    if (btnQuitar) btnQuitar.onclick = async () => {
      if (!confirm("¿Quitar el arte? Las entradas vuelven al diseño propio de la ticketera.")) return;
      trabajando(true);
      estado("Quitando…", "trabajando");
      /* Primero se desata del evento, que es lo que cambia las entradas, y
         recién después se intenta borrar el archivo. Al revés quedaría el
         evento apuntando a una URL muerta. */
      const ruta = rutaDeArte(ev.arte_url);
      const { data: filas, error } = await sb.from("eventos")
        .update({ arte_url: null }).eq("id", ev.id).select("id");
      if (error || !filas || !filas.length) {
        estado("No se pudo quitar" + (error ? ": " + error.message : ": la base no lo permitió."), "mal");
        trabajando(false);
        return;
      }
      /* El borrado desde el navegador no borra nada y tampoco falla: es el
         mismo motivo de arriba — sin policy de select, el storage no ve la
         fila que tiene que borrar. Se intenta igual (por si algún día la hay)
         pero no se promete lo que no pasó: la imagen queda en su dirección y
         lo que cambia es que ninguna entrada la usa. */
      const borrado = ruta ? await sb.storage.from("arte").remove([ruta]) : null;
      const quedo = !borrado || borrado.error || !(borrado.data || []).length;
      ev.arte_url = null;
      pintar();
      estado(quedo
        ? "Las entradas vuelven al diseño de la ticketera. La imagen sigue guardada en su dirección, pero ya no la usa nadie."
        : "Listo: el arte se quitó y el archivo se borró.", "ok");
      avisar("Arte quitado.");
    };
  }

  pintar();
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
  const url = `${location.origin}/${S.orgSlug}/${slug}`;

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
    b.onclick = () => copiarNodo(document.getElementById(b.dataset.copiar), b.dataset.que));
}

/* `que` nombra lo que se está copiando porque no siempre es un link: la
   pantalla de Equipo copia una clave que se ve una sola vez, y un aviso
   que dice "el link" justo ahí hace dudar de si copió lo que se quería. */
async function copiarNodo(nodo, que = "El link") {
  if (!nodo) return;
  try {
    if (!navigator.clipboard) throw new Error("sin portapapeles");
    await navigator.clipboard.writeText(nodo.textContent);
    avisar(que + " se copió.");
  } catch {
    const r = document.createRange();
    r.selectNodeContents(nodo);
    const sel = getSelection();
    sel.removeAllRanges();
    sel.addRange(r);
    avisar("No se pudo copiar solo. Quedó seleccionado en pantalla: copialo a mano.");
  }
}


/* ══ cierre y liquidación ═════════════════════════════════════════
   La última pantalla del ciclo. Muestra dos columnas de números a
   propósito: la foto con la que se cerró y lo que dicen los datos hoy.
   Si se anuló algo después del cierre, esa diferencia es lo primero que
   hay que ver — el que ya cobró contra la foto tiene un comprobante que
   no coincide con lo de hoy, y esconderlo no lo arregla. */
const LIQ = { evento: null, ev: null, datos: null, pagando: null, cerrando: false };

async function pantallaCierre(eventoId) {
  $("#main").innerHTML = `<p class="cargando">Cargando…</p>`;
  const [ev, res] = await Promise.all([
    sb.from("eventos").select("id,nombre,estado").eq("id", eventoId).single(),
    sb.rpc("liquidacion_evento", { p_evento: eventoId }),
  ]);
  if (ev.error || !ev.data) { avisar("Ese evento ya no existe."); mostrar("eventos"); return; }
  if (res.error) { $("#main").innerHTML = `<p class="error">${esc(res.error.message)}</p>`; return; }
  Object.assign(LIQ, { evento: eventoId, ev: ev.data, datos: res.data || {},
                       pagando: null, cerrando: false });
  pintarCierre();
}

function pintarCierre() {
  const d = LIQ.datos, hoy = d.hoy || {}, foto = d.foto, sin = d.sin_resolver || {};
  const cerrado = d.evento && d.evento.cerrado;
  const pend = Number(sin.revision_manual || 0) + Number(sin.pendientes_vivas || 0);

  $("#main").innerHTML = `
    <div class="cab-seccion">
      <button class="btn plano chico" id="btnVolver">← ${esc(LIQ.ev.nombre)}</button>
      <h2>Cierre y liquidación</h2>
    </div>

    ${!cerrado ? `
      <section class="tarjeta">
        <h3>Todavía sin cerrar</h3>
        <p class="ayuda">Cerrar congela las cifras. Lo que se le pague a cada
          relacionador queda escrito con estos números, y una anulación posterior
          ya no los mueve.</p>
        ${pend ? `<div class="liq-pendiente">
          <p><b>Hay plata sin resolver.</b> Cerrar igual se puede, pero la cuenta
             va a quedar con esto adentro:</p>
          <ul>
            ${Number(sin.revision_manual) ? `<li>${sin.revision_manual}
              ${Number(sin.revision_manual) === 1 ? "orden" : "órdenes"} en revisión manual
              — se cobró un monto distinto al esperado y nadie decidió qué hacer.</li>` : ""}
            ${Number(sin.pendientes_vivas) ? `<li>${sin.pendientes_vivas}
              ${Number(sin.pendientes_vivas) === 1 ? "reserva" : "reservas"} todavía
              en curso, con el cupo tomado.</li>` : ""}
          </ul>
          <button type="button" class="btn plano chico" id="btnIrTablero">Ver el tablero →</button>
        </div>` : `<p class="liq-ok">✓ No quedó nada sin resolver.</p>`}
        ${cuadroCifras(hoy, "Así quedaría la liquidación")}
        <div class="acciones">
          <button class="btn primario" id="btnCerrar">Cerrar el evento y liquidar</button>
        </div>
      </section>`
    : `
      <section class="tarjeta">
        <div class="liq-cab">
          <div>
            <h3>Cerrado</h3>
            <p class="ayuda">Lo cerró ${esc(foto.cerrada_por || "—")} el
              ${fmtFH(foto.cerrada_at)} · <i>${esc(foto.motivo)}</i></p>
          </div>
          <button type="button" class="btn plano chico" id="btnReabrir">Reabrir</button>
        </div>
        ${cuadroCifras(foto, "La liquidación")}
        ${foto.difiere ? cuadroDiferencia(foto, hoy) : ""}
      </section>

      <h3 class="titulo-bloque">A quién hay que pagarle</h3>
      ${(foto.lineas || []).length ? `
        <ul class="lista">${foto.lineas.map(l => filaLinea(l)).join("")}</ul>
        ${resumenPagos(foto.lineas)}`
      : `<p class="vacio">Ningún relacionador vendió en este evento, así que no hay
           comisiones que pagar.</p>`}`}`;

  $("#btnVolver").onclick = () => abrirEvento(LIQ.evento);
  const irT = $("#btnIrTablero"); if (irT) irT.onclick = () => pantallaTablero(LIQ.evento);
  const bc = $("#btnCerrar"); if (bc) bc.onclick = () => pedirCierre();
  const br = $("#btnReabrir"); if (br) br.onclick = () => pedirReapertura();
  document.querySelectorAll("#main [data-pagar]").forEach(b =>
    b.onclick = () => pedirPago(b.dataset.pagar));
}

/* El fee viaja aparte en las tres cifras porque no es del organizador: es
   lo de la plataforma. Meterlo adentro del bruto haría que el boliche crea
   que le corresponde y descubra que no cuando cobra menos. */
function cuadroCifras(c, titulo) {
  return `
    <div class="liq-cifras">
      <h4>${esc(titulo)}</h4>
      <dl>
        <div><dt>Se vendió</dt><dd>${bs(c.bruto)}</dd></div>
        <div class="tenue"><dt>Servicio de TICKETAZO</dt><dd>${bs(c.fee)}</dd></div>
        <div class="tenue"><dt>Pasó por la pasarela</dt><dd>${bs(c.cobrado)}</dd></div>
        <div><dt>Comisiones de relacionadores</dt><dd>− ${bs(c.comisiones)}</dd></div>
        <div class="total"><dt>Para el organizador</dt><dd>${bs(c.neto)}</dd></div>
      </dl>
      <p class="ayuda">${c.entradas} ${Number(c.entradas) === 1 ? "manilla" : "manillas"}
         en ${c.ordenes} ${Number(c.ordenes) === 1 ? "compra" : "compras"}.</p>
    </div>`;
}

function cuadroDiferencia(foto, hoy) {
  const dif = foto.diferencia || {};
  const linea = (t, v, fmt) => Number(v) === 0 ? ""
    : `<li>${esc(t)}: <b>${Number(v) > 0 ? "+" : "−"}${fmt(Math.abs(Number(v)))}</b></li>`;
  return `
    <div class="liq-difiere">
      <p><b>Los datos de hoy ya no coinciden con la liquidación.</b> Pasó algo
         después del cierre — casi siempre una anulación. La liquidación
         <b>no</b> se recalcula: es con la que se pagó.</p>
      <ul>
        ${linea("Vendido", dif.bruto, bs)}
        ${linea("Comisiones", dif.comisiones, bs)}
        ${linea("Manillas", dif.entradas, n => n + (n === 1 ? " manilla" : " manillas"))}
      </ul>
      <p class="ayuda">Hoy el evento suma ${bs(hoy.bruto)} y ${bs(hoy.comisiones)} de
         comisiones. Si hay que liquidar con estos números, reabrí y volvé a cerrar.</p>
    </div>`;
}

function filaLinea(l) {
  return `
    <li class="fila quieta liq-linea${l.pagada ? " pagada" : ""}">
      <span class="fila-nombre">${esc(l.nombre)}
        <em>${l.slug ? "?r=" + esc(l.slug) + " · " : ""}${l.entradas}
          ${Number(l.entradas) === 1 ? "manilla" : "manillas"} ×
          ${bs(l.comision_unitaria)}</em></span>
      <span class="cifra destacada">${bs(l.comision)}</span>
      ${l.pagada
        ? `<span class="pastilla verde">Pagada</span>
           <span class="fila-dato tenue">${fmtFH(l.pagada_at)}${
             l.pagada_por ? " · " + esc(l.pagada_por) : ""}${
             l.pagado_nota ? " · " + esc(l.pagado_nota) : ""}</span>`
        : `<button type="button" class="btn primario chico" data-pagar="${l.id}">
             Marcar pagada</button>`}
    </li>`;
}

function resumenPagos(lineas) {
  const pagado = lineas.filter(l => l.pagada).reduce((a, l) => a + Number(l.pagado_monto || 0), 0);
  const debe = lineas.filter(l => !l.pagada).reduce((a, l) => a + Number(l.comision || 0), 0);
  return `
    <div class="total">
      <div>
        <h3>${debe > 0 ? "Falta pagar" : "Todo pagado"}</h3>
        <p>${pagado > 0 ? `Ya se pagaron ${bs(pagado)}.` : "Todavía no se pagó ninguna."}</p>
      </div>
      <span class="monto">${bs(debe)}</span>
    </div>`;
}


/* El motivo es obligatorio en la base, así que la pantalla lo pide en vez
   de dejar que la base rebote con un error que el usuario no pidió. */
async function pedirCierre() {
  const motivo = prompt("¿Por qué se cierra? Queda escrito con la liquidación.",
                        "Evento terminado");
  if (motivo === null) return;
  const { data, error } = await sb.rpc("cerrar_evento",
    { p_evento: LIQ.evento, p_motivo: motivo });
  if (error) { avisar(sinCodigo(error.message)); return; }
  avisar(data.motivo);
  await pantallaCierre(LIQ.evento);
}

async function pedirReapertura() {
  const motivo = prompt("¿Por qué se reabre? La liquidación anterior queda guardada.", "");
  if (motivo === null) return;
  const { data, error } = await sb.rpc("reabrir_evento",
    { p_evento: LIQ.evento, p_motivo: motivo });
  if (error) { avisar(sinCodigo(error.message)); return; }
  avisar(data.motivo);
  await pantallaCierre(LIQ.evento);
}

/* Marcar pagado no se deshace desde acá a propósito: si se marcó de más,
   la salida es reabrir y volver a cerrar, que deja registro. Un botón de
   "despagar" sería la puerta para tapar un pago que sí se hizo. */
async function pedirPago(lineaId) {
  const l = (LIQ.datos.foto.lineas || []).find(x => x.id === lineaId);
  if (!l) return;
  if (!confirm(`Marcar como pagada la comisión de ${l.nombre}: ${bs(l.comision)}.\n\n` +
               `Esto queda registrado y no se deshace desde acá.`)) return;
  const nota = prompt("¿Cómo se pagó? (opcional: transferencia, efectivo, nº de comprobante)", "");
  if (nota === null) return;
  const { data, error } = await sb.rpc("pagar_comision",
    { p_linea: lineaId, p_monto: null, p_nota: nota });
  if (error) { avisar(sinCodigo(error.message)); return; }
  avisar(data.motivo);
  await pantallaCierre(LIQ.evento);
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

  /* Sus compradores y el plano cuelgan de UN evento, y él puede estar
     repartiendo links de varios a la vez: sin elegir cuál, el plano sería
     el de cualquiera. La lista junta los que están a la venta —donde el
     plano sirve para vender— con aquellos donde ya vendió algo, aunque
     estén cerrados: por esos le siguen preguntando al día siguiente. */
  const evs = [];
  const vistos = new Set();
  (re.data || []).forEach(e => {
    vistos.add(e.id);
    evs.push({ id: e.id, nombre: e.nombre, fecha: e.fecha });
  });
  ventas.forEach(v => {
    if (vistos.has(v.evento_id)) return;
    vistos.add(v.evento_id);
    evs.push({ id: v.evento_id, nombre: v.evento_nombre, fecha: v.evento_fecha });
  });

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
         entrando por tu link y pague, acá aparecen las entradas y tu comisión.</p>`}

    ${evs.length ? `
      <div class="cab-bloque sep">
        <h3 class="titulo-bloque">Tu salón</h3>
        ${evs.length > 1
          ? `<select id="selEventoSalon" aria-label="Evento del que ver compradores y mesas">
               ${evs.map(e => `<option value="${esc(e.id)}">${esc(e.nombre)} · ${fmtF(e.fecha)}</option>`).join("")}
             </select>`
          : `<span class="conteo">${esc(evs[0].nombre)} · ${fmtF(evs[0].fecha)}</span>`}
      </div>
      <section id="zonaCompradores"></section>
      <section id="zonaPlano"></section>` : ""}`;

  cablearCopiar();

  /* Los mismos dos componentes del tablero, sin una segunda versión: la
     lista ya le devuelve solo sus compradores y el plano le muestra las
     mesas de todos con el nombre únicamente en las que vendió él. Lo
     único que cambia es `editar`, que acá es false y le saca los botones
     de repartir — el salón lo acomoda una sola persona (0029), y un botón
     que la base le va a rebotar solo enseña a desconfiar de los botones. */
  if (evs.length) {
    const sel = $("#selEventoSalon");
    if (sel) sel.onchange = () => montarSalon(sel.value, { editar: puedeEditar() });
    montarSalon(evs[0].id, { editar: puedeEditar() });
  }
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
    const url = `${location.origin}/${S.orgSlug}/${e.slug}` +
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

/* ══ el tablero del evento ════════════════════════════════════════
   No está para que el número de lo vendido quede lindo: está para ver
   dónde se está escapando la plata. Por eso el orden es lo grande arriba
   —manillas, recaudado y cuánta gente ya entró— y ENSEGUIDA las alertas,
   sin scrollear: son las cifras que hay que dejar en cero antes de que
   abra la puerta, y cualquier total que las promedie con lo cobrado las
   esconde. Los desgloses van al final: se miran una vez, no cada rato.

   resumen_evento() exige puede_editar() y a cualquier otro le contesta
   'Sin permiso'. Acá no se vuelve a preguntar: el rrpp ni siquiera tiene
   la pestaña de eventos, y si llegara por consola la que decide es la
   base. */

const num = n => Number(n || 0).toLocaleString("es-BO");
const pct = n => (Number(n || 0) % 1 ? Number(n).toFixed(1) : Number(n || 0).toFixed(0)) + "%";
/* Una manilla es una persona, y "1 manillas" en una lista que se lee de
   corrido delata que el texto lo armó una máquina justo donde hay que
   confiar en lo que dice. */
const manillasTxt = n => `${num(n)} ${Number(n) === 1 ? "manilla" : "manillas"}`;
const fmtFH = t => t
  ? new Date(t).toLocaleString("es-BO",
      { day: "numeric", month: "short", hour: "2-digit", minute: "2-digit" })
  : "";

async function pantallaTablero(eventoId) {
  $("#main").innerHTML = `<p class="cargando">Cargando el tablero…</p>`;
  const ev = await sb.from("eventos").select("id,nombre").eq("id", eventoId).single();
  if (ev.error || !ev.data) {
    avisar("Ese evento ya no existe.");
    mostrar("eventos");
    return;
  }

  $("#main").innerHTML = `
    <div class="cab-seccion">
      <button class="btn plano chico" id="btnVolver">← ${esc(ev.data.nombre)}</button>
      <h2>Tablero</h2>
    </div>
    <div id="zonaResumen"><p class="cargando">Cargando…</p></div>
    <section id="zonaCompradores"></section>
    <section id="zonaPlano"></section>
    <section id="zonaRegistro"></section>`;

  $("#btnVolver").onclick = () => abrirEvento(eventoId);

  /* El salón se recarga solo cuando se reparte una mesa, y el tablero se
     entera por acá: la alerta de "mesas sin asignar" es la que se está
     bajando, y una alerta que sigue diciendo 2 después de asignar la
     primera enseña a no creerle. */
  await Promise.all([
    refrescarResumen(eventoId),
    /* Anular una compra baja las cifras de arriba Y agrega una fila al
       registro de abajo: el mismo `alCambiar` refresca los dos, porque un
       tablero que sigue diciendo lo de antes de la anulación enseña a no
       creerle. */
    montarSalon(eventoId, { editar: puedeEditar(),
                            alCambiar: () => Promise.all([refrescarResumen(eventoId),
                                                          refrescarRegistro(eventoId)]) }),
    refrescarRegistro(eventoId),
  ]);
}

async function refrescarResumen(eventoId) {
  const z = $("#zonaResumen");
  if (!z) return;
  const { data, error } = await sb.rpc("resumen_evento", { p_evento: eventoId });
  if (error) { z.innerHTML = `<p class="error">${esc(error.message)}</p>`; return; }
  /* {} en vez de error: resumen_evento() devuelve lo mismo para "no es de
     tu organizador" que para "no existe", a propósito, para que no sirva
     de oráculo de qué uuids hay en la base del vecino. */
  if (!data || !data.vendido) {
    z.innerHTML = `<p class="vacio">No hay datos de este evento.</p>`;
    return;
  }
  z.innerHTML = bloqueCifras(data) + bloqueAlertas(data.alertas) + bloqueDesgloses(data);
  const ir = $("#irAlPlano");
  if (ir) ir.onclick = () => {
    const p = $("#zonaPlano");
    if (p) p.scrollIntoView({ behavior: "smooth", block: "start" });
  };
  /* La alerta de revisión manual contaba las órdenes desde 0033 y no
     ofrecía nada: el que la leía se enteraba de que había plata cobrada
     sin entrada del otro lado y ahí se terminaba. Este botón es el
     camino que faltaba. */
  const rev = $("#irARevision");
  if (rev) rev.onclick = () => pantallaRevision(eventoId);
}

/* Tres números y ninguno es el mismo dato: lo que se vendió, lo que entró
   a la caja y cuánta gente ya está adentro. El tercero es el que cambia
   toda la noche y es el que nadie puede calcular de memoria. */
function bloqueCifras(r) {
  const v = r.vendido, p = r.puerta;
  const avance = Math.max(0, Math.min(100, Number(p.porcentaje) || 0));
  return `<div class="cifras">
    <div class="cifra-grande">
      <span class="valor">${num(v.manillas)}</span>
      <span class="rotulo">Manillas vendidas</span>
      <span class="pie">${num(v.ordenes)} ${v.ordenes === 1 ? "orden pagada" : "órdenes pagadas"}
        · ${num(v.unidades)} ${v.unidades === 1 ? "unidad" : "unidades"}</span>
    </div>
    <div class="cifra-grande plata">
      <span class="valor">${bs(v.recaudado)}</span>
      <span class="rotulo">Recaudado</span>
      <span class="pie">ticket promedio ${bs(v.ticket_promedio)} · el fee de ${bs(v.fee)} viaja aparte</span>
    </div>
    <div class="cifra-grande">
      <span class="valor">${num(p.usadas)}<i> de ${num(p.emitidas)}</i></span>
      <span class="rotulo">Ya entraron</span>
      <span class="pie">${pct(p.porcentaje)} · faltan ${num(p.faltan)}</span>
      <span class="avance"><i style="width:${avance}%"></i></span>
    </div>
  </div>`;
}

/* Una alerta en cero no es una alerta. Si la que está resuelta grita igual
   que la que tiene algo pendiente, a la tercera noche no se mira ninguna:
   la de cero se apaga y dice que está hecha, que es información distinta
   de "acá no hay dato". Y ninguno de estos montos se suma a lo recaudado:
   son plata que no entró, o que entró mal. */
function bloqueAlertas(a) {
  const filas = [
    { cifra: a.mesas_sin_asignar.ordenes,
      titulo: "Mesas sin asignar",
      pie: `${num(a.mesas_sin_asignar.manillas)} manillas · ${bs(a.mesas_sin_asignar.monto)} ya cobrados`,
      viva: "Compras de mesa pagadas a las que todavía nadie les dijo dónde se sientan. Este es el número que va a cero antes de que abra la puerta.",
      hecha: "Toda compra de mesa tiene su lugar.",
      nivel: "peligro", boton: { id: "irAlPlano", txt: "Ver el plano" } },
    { cifra: a.revision_manual.ordenes,
      titulo: "En revisión manual",
      pie: `${bs(a.revision_manual.monto)} cobrados`,
      viva: "La pasarela cobró un monto distinto al esperado. Hay que mirarlas de a una: es plata que entró y no tiene entrada del otro lado.",
      hecha: "Nadie pagó de más ni de menos.",
      nivel: "aviso", boton: { id: "irARevision", txt: "Resolverlas" } },
    { cifra: a.pendientes_vencidas.ordenes,
      titulo: "Pendientes vencidas",
      pie: `${bs(a.pendientes_vencidas.monto)} que no entraron`,
      viva: "Retuvieron cupo y nunca pagaron. Siguen diciendo «pendiente» hasta que pase el barrido.",
      hecha: "Ninguna reserva quedó colgada.",
      nivel: "aviso" },
  ];
  /* Esta cuarta no existe cuando está en cero, ni apagada: en una base sana
     es cero SIEMPRE, y una tarjeta permanente que dice "✓ 0" entrena a
     pasarla de largo justo el día que deja de ser cero. Si aparece, hay
     gente que puede pasar el molinete con una entrada que nadie cobró. */
  if (a.manillas_sin_orden_pagada) filas.push({
    cifra: a.manillas_sin_orden_pagada,
    titulo: "Manillas sin orden pagada",
    pie: "revisá antes de abrir",
    viva: "Hay entradas válidas cuya orden no está pagada: pasan el molinete igual.",
    hecha: "", nivel: "peligro" });

  return `<div class="alertas">${filas.map(f => `
    <div class="alerta ${f.cifra ? "viva " + f.nivel : "hecha"}">
      <span class="alerta-cifra">${f.cifra ? num(f.cifra) : "✓"}</span>
      <div class="alerta-txt">
        <h4>${esc(f.titulo)}</h4>
        <p>${esc(f.cifra ? f.viva : f.hecha)}</p>
        ${f.cifra ? `<span class="alerta-pie">${esc(f.pie)}</span>` : ""}
      </div>
      ${f.cifra && f.boton
        ? `<button type="button" class="btn plano chico" id="${f.boton.id}">${esc(f.boton.txt)}</button>` : ""}
    </div>`).join("")}</div>`;
}

const CANAL_TXT = { publico: "Público", rrpp: "Relacionadores",
                    puerta: "Puerta", cortesia: "Cortesías" };
const ESTADO_TXT = { pagada: "Pagadas", pendiente: "Pendientes", vencida: "Vencidas",
                     revision_manual: "En revisión manual", anulada: "Anuladas" };

/* `quedan` en null dice dos cosas distintas y `en_venta` las separa: sin
   tope, o directamente no se vende en la fase de hoy. Mostrar el 0 que
   devuelve disponibilidad_tipo() cuando no encuentra la fila de precio
   haría leer "agotado" donde lo que pasa es que nunca salió a la venta. */
function quedanTxt(p) {
  if (p.quedan == null) return p.en_venta ? `<i>sin tope</i>` : `<i>fuera de fase</i>`;
  return Number(p.quedan) === 0 ? `<b class="agotado">agotado</b>` : num(p.quedan);
}

function bloqueDesgloses(r) {
  return `
  <h3 class="titulo-bloque">Por producto</h3>
  <p class="ayuda bajo-titulo">Las unidades son lo que compró el cliente y miden el cupo;
    las manillas son la gente que entra. Un combo de 10 vendido una vez es 1 unidad y 10 manillas.</p>
  <div class="grilla-envoltorio">
    <table class="tabla">
      <thead><tr>
        <th>Producto</th><th class="n">Unidades</th><th class="n">Manillas</th>
        <th class="n">Cupo</th><th class="n">Quedan</th>
        <th class="n">Precio</th><th class="n">Recaudado</th>
      </tr></thead>
      <tbody>${r.productos.map(p => `
        <tr${p.activo ? "" : ' class="apagada"'}>
          <td><span class="prod-nombre">${esc(p.nombre)}</span>
            <em>${esc(p.categoria)}${p.manillas_por_unidad > 1
                  ? ` · ${num(p.manillas_por_unidad)} manillas por unidad` : ""}${
                  p.activo ? "" : " · inactivo"}</em></td>
          <td class="n">${num(p.unidades)}</td>
          <td class="n">${num(p.manillas)}${p.manillas_anuladas
              ? `<em>${num(p.manillas_anuladas)} anuladas</em>` : ""}</td>
          <td class="n">${p.cupo == null ? `<i>sin tope</i>` : num(p.cupo)}</td>
          <td class="n">${quedanTxt(p)}</td>
          <td class="n">${p.precio == null ? `<i>—</i>` : bs(p.precio)}</td>
          <td class="n">${bs(p.recaudado)}</td>
        </tr>`).join("")}</tbody>
    </table>
  </div>

  <div class="dos-tablas">
    <div>
      <h3 class="titulo-bloque">Por canal</h3>
      <div class="grilla-envoltorio">
        <table class="tabla">
          <thead><tr><th>Canal</th><th class="n">Órdenes</th>
            <th class="n">Manillas</th><th class="n">Usadas</th></tr></thead>
          <tbody>${r.canales.map(c => `
            <tr${Number(c.manillas) ? "" : ' class="apagada"'}>
              <td>${esc(CANAL_TXT[c.canal] || c.canal)}</td>
              <td class="n">${num(c.ordenes)}</td>
              <td class="n">${num(c.manillas)}</td>
              <td class="n">${num(c.manillas_usadas)}</td>
            </tr>`).join("")}</tbody>
        </table>
      </div>
    </div>
    <div>
      <h3 class="titulo-bloque">Por estado de orden</h3>
      <div class="grilla-envoltorio">
        <table class="tabla">
          <thead><tr><th>Estado</th><th class="n">Órdenes</th>
            <th class="n">Subtotal</th><th class="n">Total con fee</th></tr></thead>
          <tbody>${r.estados.map(e => `
            <tr${Number(e.ordenes) ? "" : ' class="apagada"'}>
              <td>${esc(ESTADO_TXT[e.estado] || e.estado)}</td>
              <td class="n">${num(e.ordenes)}</td>
              <td class="n">${bs(e.subtotal)}</td>
              <td class="n">${bs(e.total)}</td>
            </tr>`).join("")}</tbody>
        </table>
      </div>
    </div>
  </div>`;
}

/* ══ el salón: quién compró y dónde se sienta ═════════════════════
   La lista de compradores y el plano son dos vistas del mismo hecho, así
   que comparten estado y se recargan juntos: asignar desde el plano tiene
   que apagar la fila de la lista, y asignar desde la lista tiene que
   pintar la chapa. Con una copia cada uno, la mitad que no se enteró
   sigue ofreciendo una mesa que ya tiene dueño — y eso se descubre en la
   puerta, con los dos grupos parados.

   Es la MISMA pantalla para el administrador y para el relacionador, y no
   hay un solo `if` de rol acá adentro: compradores_evento() ya devuelve
   todas las órdenes al que puede editar y solo las suyas al que no, y
   mesas_evento() manda las 24 mesas a los dos pero con el nombre del
   comprador únicamente donde corresponde. `editar` decide una cosa sola:
   si se dibujan los botones de repartir. Mostrarle a un rrpp un botón que
   la base le va a rebotar es enseñarle a desconfiar de los botones; la
   guardia de verdad es puede_editar() adentro de asignar_mesa(). */
const SALON = { evento: null, editar: false, compras: [], mesas: [],
                busca: "", sel: null, asignando: null, alCambiar: null,
                anulando: null, abierta: null, manillas: {}, anulandoEntrada: null };

async function montarSalon(eventoId, opts) {
  Object.assign(SALON, {
    evento: eventoId, editar: !!(opts && opts.editar),
    compras: [], mesas: [], busca: "", sel: null, asignando: null,
    anulando: null, abierta: null, manillas: {}, anulandoEntrada: null,
    alCambiar: (opts && opts.alCambiar) || null,
  });
  const c = $("#zonaCompradores"), p = $("#zonaPlano");
  if (c) {
    c.innerHTML = `<p class="cargando">Cargando compradores…</p>`;
    c.onclick = clicEnCompradores;
    /* Los formularios de anulación piden un motivo escrito, así que van en
       un <form> de verdad: Enter envía, el `required` del navegador frena
       el vacío antes de molestar a la base, y el foco no se pierde. Se
       escuchan acá arriba porque las filas se repintan enteras. */
    c.onsubmit = enviarEnCompradores;
  }
  if (p) {
    p.innerHTML = `<p class="cargando">Cargando el plano…</p>`;
    p.onclick = clicEnPlano;
  }
  await cargarSalon();
}

/* Las dos listas llegan enteras, un jsonb cada una: no hay paginado que
   pueda comerse una fila en silencio como hace PostgREST a las 1000, y el
   filtro por evento y por rol ya viajó adentro de la función. Es lo que
   además deja que el buscador de abajo trabaje sin volver a la base. */
async function cargarSalon() {
  const [rc, rm] = await Promise.all([
    // sin default en todos sus parámetros: se pasan siempre los dos
    sb.rpc("compradores_evento", { p_evento: SALON.evento, p_solo_mios: false }),
    sb.rpc("mesas_evento", { p_evento: SALON.evento }),
  ]);
  SALON.compras = rc.data || [];
  SALON.mesas = rm.data || [];
  pintarCompradores(rc.error);
  pintarPlano(rm.error);
}

async function refrescarSalon() {
  await cargarSalon();
  if (SALON.alCambiar) await SALON.alCambiar();
}

/* Una compra puede tener mesa por dos caminos: `ordenes.mesa_asignada_id`,
   que es lo que escribe asignar_mesa(), o `mesas.orden_id`, que es la
   chapa que el cliente eligió él mismo en la venta. compradores_evento()
   solo trae el primero, así que mirando esa sola punta una chapa comprada
   directo figuraría "sin asignar" y volvería a la lista para repartir:
   dos grupos, la misma mesa. Es el mismo criterio con el que
   alertas.mesas_sin_asignar descuenta las que ya tienen dueño por el otro
   lado, y por eso las dos cuentas dan igual. */
const mesaDeCompra = c => SALON.mesas.find(m =>
  (c.mesa_id && m.id === c.mesa_id) || (m.orden_id && m.orden_id === c.orden_id));

/* Que una compra sea "de mesa" lo dice el producto, no el precio: a quien
   compró cuatro generales no le falta ninguna mesa, y marcarle "sin
   asignar" sería inventarle una tarea. */
const compraDeMesa = c => (c.productos || []).some(p => p.categoria === "mesa");

/* La compra trae más manillas de las que la mesa aguanta. No lo impide
   nadie —ver asignarMesa()— pero se muestra siempre, no solo al asignar:
   el que llega el sábado a mirar el plano tiene que verlo también. */
const noEntra = (c, m) => !!(c && m && Number(c.manillas) > Number(m.manillas));

/* ── la lista de compradores ── */
function pintarCompradores(error) {
  const z = $("#zonaCompradores");
  if (!z) return;
  z.innerHTML = `
    <div class="cab-bloque">
      <h3 class="titulo-bloque">Compradores</h3>
      ${SALON.compras.length ? `<input id="buscaComprador" class="buscador" type="search"
         autocomplete="off" placeholder="Buscar por nombre o teléfono"
         value="${esc(SALON.busca)}" aria-label="Buscar comprador por nombre o teléfono">` : ""}
      <span class="conteo" id="conteoCompradores"></span>
    </div>
    ${error ? `<p class="error">${esc(error.message)}</p>` : ""}
    ${SALON.compras.length ? `
      <div class="grilla-envoltorio">
        <table class="tabla tabla-compras">
          <thead><tr>
            <th>Comprador</th><th>Contacto</th><th>Compró</th>
            <th class="n">Manillas</th><th class="n">Pagó</th>
            <th>Relacionador</th><th>Mesa</th>
            ${SALON.editar ? `<th class="col-accion"></th>` : ""}
          </tr></thead>
          <tbody id="filasCompradores"></tbody>
        </table>
      </div>`
      : error ? "" : `<p class="vacio">Todavía no hay compras pagadas en este evento.</p>`}`;

  const b = $("#buscaComprador");
  /* El buscador filtra sobre lo que YA está en memoria: en la puerta se
     busca a alguien que dice "compré y no me llegó", y con el 4G del
     boliche una consulta por tecla es medio segundo de espera por letra.
     La lista entera de un evento son decenas de filas, no miles. */
  if (b) b.oninput = () => { SALON.busca = b.value; pintarFilasCompradores(); };
  pintarFilasCompradores();
}

function filtrarCompras() {
  const q = SALON.busca.trim().toLowerCase();
  if (!q) return SALON.compras;
  // El teléfono se compara también sin separadores: quien lo busca lo
  // escribe como se lo dictaron y en la base puede estar con espacios,
  // guiones o +591 adelante.
  const soloNum = s => String(s || "").replace(/\D/g, "");
  const qn = soloNum(q);
  return SALON.compras.filter(c =>
    String(c.comprador || "").toLowerCase().includes(q) ||
    String(c.telefono || "").toLowerCase().includes(q) ||
    (qn.length >= 3 && soloNum(c.telefono).includes(qn)));
}

function pintarFilasCompradores() {
  const tb = $("#filasCompradores");
  if (!tb) return;
  const filas = filtrarCompras();
  const cont = $("#conteoCompradores");
  if (cont) cont.textContent = SALON.busca.trim()
    ? `${filas.length} de ${SALON.compras.length}`
    : `${SALON.compras.length} ${SALON.compras.length === 1 ? "compra" : "compras"}`;
  tb.innerHTML = filas.length
    ? filas.map(filaCompra).join("")
    : `<tr><td class="sin-nada" colspan="${SALON.editar ? 8 : 7}">
         Nadie con ese nombre ni ese teléfono en este evento.</td></tr>`;
}

function filaCompra(c) {
  const m = mesaDeCompra(c);
  return filaCompraFila(c, m) + filaCompraDetalle(c);
}

function filaCompraFila(c, m) {
  return `<tr data-orden="${esc(c.orden_id)}">
    <td><span class="prod-nombre">${esc(c.comprador || "Sin nombre")}</span>
      <em>${esc(fmtFH(c.fecha))}</em></td>
    <td class="dato">${esc(c.telefono || "—")}${c.email ? `<em>${esc(c.email)}</em>` : ""}</td>
    <td class="detalle">${esc(c.detalle || "—")}</td>
    <td class="n">${num(c.manillas)}${c.manillas_usadas
        ? `<em>${num(c.manillas_usadas)} usadas</em>` : ""}</td>
    <td class="n">${bs(c.pagado)}</td>
    <td class="dato">${esc(c.rrpp_nombre || (c.canal === "rrpp" ? "sin nombre" : "Público"))}</td>
    <td>${m
      ? `<span class="chip-mesa${noEntra(c, m) ? " chica" : ""}">${esc(m.etiqueta)}<em>${esc(m.planta)}</em></span>${
          noEntra(c, m) ? `<em class="chica-nota">es de ${num(m.manillas)}</em>` : ""}`
      : compraDeMesa(c) ? `<span class="chip-mesa falta">sin asignar</span>`
                        : `<span class="tenue">—</span>`}</td>
    ${SALON.editar ? `<td class="col-accion">${accionesCompra(c, m)}</td>` : ""}
  </tr>`;
}

function accionesCompra(c, m) {
  if (SALON.asignando === c.orden_id) return selectorDeMesas(c, m);
  const mesa = m
    ? `<button type="button" class="btn plano chico" data-abrir="${esc(c.orden_id)}">Cambiar</button>
       <button type="button" class="btn plano chico" data-liberar="${esc(c.orden_id)}">Liberar</button>`
    : `<button type="button" class="btn plano chico" data-abrir="${esc(c.orden_id)}">Asignar mesa</button>`;
  /* "Manillas" antes que "Anular": la manilla suelta —la perdida, la
     duplicada— es lo que se hace seguido, y anular la compra entera es lo
     que no se deshace. El orden de los botones es el orden de la
     frecuencia, no el del código. */
  return `${mesa}
    <button type="button" class="btn plano chico" data-manillas="${esc(c.orden_id)}"
      >${SALON.abierta === c.orden_id ? "Ocultar" : "Manillas"}</button>
    <button type="button" class="btn plano chico peligrosa" data-anular="${esc(c.orden_id)}">Anular</button>`;
}

/* ── anular ──
   La fila que se despliega abajo de la compra: el formulario de anulación
   y, si se pidió, la lista de manillas con su propio botón por fila. Van
   en la MISMA fila desplegada para que no se pueda tener abierta la
   anulación de una compra y la lista de otra al mismo tiempo. */
function filaCompraDetalle(c) {
  const cols = SALON.editar ? 8 : 7;
  const abre = SALON.anulando === c.orden_id || SALON.abierta === c.orden_id;
  if (!abre) return "";
  return `<tr class="fila-detalle"><td colspan="${cols}">
    ${SALON.anulando === c.orden_id ? formAnularCompra(c) : ""}
    ${SALON.abierta === c.orden_id ? listaManillas(c) : ""}
  </td></tr>`;
}

/* La confirmación dice QUÉ se va a anular —cuántas manillas y cuánta
   plata— y no "¿estás seguro?". Nadie está seguro de un id: se está
   seguro de "las tres de Marcela, 300 Bs". Y dice lo que NO va a pasar:
   la plata no vuelve sola. Prometer un reintegro que esta ticketera no
   hace sería la peor forma de enterarse. */
function formAnularCompra(c) {
  const usadas = Number(c.manillas_usadas) || 0;
  return `<form class="form-anular" data-anular-compra="${esc(c.orden_id)}">
    <p class="anular-que">Se anulan <b>${manillasTxt(c.manillas)}</b> de
      ${esc(c.comprador || "sin nombre")} y su cupo vuelve a la venta.
      Los <b>${bs(c.pagado)}</b> cobrados no se devuelven solos: el reintegro se hace
      en la pasarela. <b>Esto no se deshace.</b></p>
    ${usadas ? `<label class="anular-usadas">
      <input type="checkbox" name="usadas">
      <span>${usadas === 1 ? "Una manilla de esta compra ya entró" : `${num(usadas)} manillas de esta compra ya entraron`}
        al evento. Anularlas igual —un contracargo— no las saca de adentro y hace bajar
        el conteo de la puerta.</span></label>` : ""}
    <label class="anular-motivo"><span>Motivo</span>
      <input name="motivo" required maxlength="200" autocomplete="off"
             placeholder="pago doble, contracargo, se arrepintió…"></label>
    <div class="acciones">
      <button type="submit" class="btn primario chico">Anular la compra</button>
      <button type="button" class="btn plano chico" data-cerrar="1">Cancelar</button>
    </div>
  </form>`;
}

const ESTADO_MANILLA = { valida: { txt: "Válida", cls: "verde" },
                         usada:  { txt: "Ya entró", cls: "dorada" },
                         anulada:{ txt: "Anulada", cls: "roja" } };

function listaManillas(c) {
  const filas = SALON.manillas[c.orden_id];
  if (!filas) return `<p class="cargando">Cargando las manillas…</p>`;
  if (!filas.length) return `<p class="vacio">Esta compra no tiene manillas emitidas.</p>`;
  return `<table class="tabla tabla-manillas">
    <thead><tr><th>Código</th><th>Producto</th><th>A nombre de</th>
      <th>Estado</th><th class="col-accion"></th></tr></thead>
    <tbody>${filas.map(en => {
      const e = ESTADO_MANILLA[en.estado] || { txt: en.estado, cls: "gris" };
      return `<tr>
        <td class="dato"><code>${esc(en.code)}</code></td>
        <td>${esc((en.tipo_entrada && en.tipo_entrada.nombre) || "—")}</td>
        <td class="dato">${esc(en.cliente || "—")}</td>
        <td><span class="pastilla ${e.cls}">${e.txt}</span>${
          en.used_at ? `<em>${esc(fmtFH(en.used_at))}</em>` : ""}</td>
        <td class="col-accion">${en.estado === "anulada" ? ""
          : `<button type="button" class="btn plano chico peligrosa"
               data-anular-manilla="${esc(en.id)}">Anular</button>`}</td>
      </tr>${SALON.anulandoEntrada === en.id ? `
      <tr><td colspan="5">${formAnularManilla(en, false)}</td></tr>` : ""}`;
    }).join("")}</tbody>
  </table>`;
}

/* El mismo formulario para la manilla de una compra y para una cortesía,
   porque atrás es la misma función. Lo que cambia es la consecuencia y hay
   que decirla: la de una compra no devuelve cupo —la unidad se vendió y se
   cobró—, la cortesía sí, porque no tiene compra que la sostenga. */
function formAnularManilla(en, esCortesia) {
  return `<form class="form-anular" data-anular-entrada="${esc(en.id)}">
    <p class="anular-que">Se anula la manilla <b>${esc(en.code)}</b>. ${esCortesia
      ? "Su lugar vuelve al cupo: una cortesía no tiene compra detrás que lo retenga."
      : "La compra queda en pie —ya se cobró— y el resto de sus manillas siguen entrando."}
      ${en.estado === "usada"
        ? `<b>Esta ya entró al evento:</b> anularla no la saca de adentro.` : ""}</p>
    ${en.estado === "usada" ? `<label class="anular-usadas">
      <input type="checkbox" name="usadas"> <span>Anularla igual.</span></label>` : ""}
    <label class="anular-motivo"><span>Motivo</span>
      <input name="motivo" required maxlength="200" autocomplete="off"
             placeholder="manilla perdida, QR duplicado…"></label>
    <div class="acciones">
      <button type="submit" class="btn primario chico">Anular la manilla</button>
      <button type="button" class="btn plano chico" data-cerrar="1">Cancelar</button>
    </div>
  </form>`;
}

/* Las libres salen del mismo jsonb que pinta el plano, así que esta lista
   no puede ofrecer una mesa que la chapa de al lado muestra ocupada. La
   que ya tiene esta compra entra igual: cambiar de opinión no tiene por
   qué ser liberar y volver a asignar. */
function selectorDeMesas(c, actual) {
  const libres = SALON.mesas.filter(m => !m.ocupada || (actual && m.id === actual.id));
  if (!libres.length) return `<span class="tenue">No queda ninguna mesa libre.</span>
    <button type="button" class="btn plano chico" data-cerrar="1">Cerrar</button>`;
  return `<span class="picker">
    <select id="selMesa" aria-label="Mesa para ${esc(c.comprador || "esta compra")}">
      ${libres.map(m => `<option value="${esc(m.id)}"${actual && m.id === actual.id ? " selected" : ""}
        >${esc(m.etiqueta)} · ${esc(m.planta)} · ${manillasTxt(m.manillas)}${
          noEntra(c, m) ? ` — chica: la compra trae ${num(c.manillas)}` : ""}</option>`).join("")}
    </select>
    <button type="button" class="btn primario chico" data-confirmar="${esc(c.orden_id)}">Asignar</button>
    <button type="button" class="btn plano chico" data-cerrar="1">Cancelar</button>
  </span>`;
}

function clicEnCompradores(e) {
  const b = e.target.closest("button[data-abrir],button[data-liberar],button[data-confirmar]," +
                             "button[data-cerrar],button[data-anular],button[data-manillas]," +
                             "button[data-anular-manilla]");
  if (!b) return;
  const d = b.dataset;
  if (d.cerrar) {
    SALON.asignando = null; SALON.anulando = null; SALON.anulandoEntrada = null;
    pintarFilasCompradores(); return;
  }
  if (d.abrir)  { SALON.asignando = d.abrir; pintarFilasCompradores(); return; }
  if (d.liberar) return liberarMesa(d.liberar);
  if (d.confirmar) {
    const sel = $("#selMesa");
    if (sel && sel.value) return asignarMesa(d.confirmar, sel.value);
  }
  if (d.anular) {
    SALON.anulando = SALON.anulando === d.anular ? null : d.anular;
    SALON.anulandoEntrada = null;
    pintarFilasCompradores(); return;
  }
  if (d.manillas) {
    if (SALON.abierta === d.manillas) { SALON.abierta = null; pintarFilasCompradores(); return; }
    return abrirManillas(d.manillas);
  }
  if (d.anularManilla) {
    SALON.anulandoEntrada = SALON.anulandoEntrada === d.anularManilla ? null : d.anularManilla;
    pintarFilasCompradores(); return;
  }
}

function enviarEnCompradores(e) {
  const f = e.target.closest("form[data-anular-compra],form[data-anular-entrada]");
  if (!f) return;
  e.preventDefault();
  const motivo = (f.elements.motivo && f.elements.motivo.value) || "";
  const usadas = !!(f.elements.usadas && f.elements.usadas.checked);
  if (f.dataset.anularCompra) return anularCompra(f.dataset.anularCompra, motivo, usadas);
  return anularManilla(f.dataset.anularEntrada, motivo, usadas);
}

/* Las manillas de una compra se piden recién cuando alguien las quiere
   ver, y con el filtro por orden del lado del servidor: son cuatro filas
   por compra y traerlas todas de entrada serían miles en un evento
   grande, justo el corte silencioso de PostgREST a las 1000. */
async function abrirManillas(ordenId) {
  SALON.abierta = ordenId;
  SALON.anulandoEntrada = null;
  pintarFilasCompradores();
  const { data, error } = await sb.from("entradas")
    .select("id,code,estado,cliente,canal,used_at,tipo_entrada(nombre)")
    .eq("orden_id", ordenId)
    .order("created_at");
  if (error) { avisar(error.message); SALON.abierta = null; pintarFilasCompradores(); return; }
  SALON.manillas[ordenId] = data || [];
  pintarFilasCompradores();
}

/* Los códigos de Postgres viajan pegados adelante del mensaje para que la
   máquina los pueda mirar (MOTIVO_REQUERIDO, HAY_USADAS, SIN_CUPO). El
   que está mirando la pantalla no los necesita: la frase que sigue ya
   está escrita para él. Se le devuelve la mayúscula que le sacó el
   prefijo — una frase que arranca en minúscula se lee como un pedazo de
   otra cosa, justo cuando hay que confiar en lo que dice. */
const sinCodigo = m => {
  const t = String(m || "").replace(/^[A-Z_]+:\s*/, "");
  return t.charAt(0).toUpperCase() + t.slice(1);
};

async function anularCompra(ordenId, motivo, incluirUsadas) {
  const { data, error } = await sb.rpc("anular_orden",
    { p_orden: ordenId, p_motivo: motivo, p_incluir_usadas: !!incluirUsadas });
  if (error) { avisar(sinCodigo(error.message)); return; }
  avisar(data.motivo);
  SALON.anulando = null;
  SALON.abierta = null;
  delete SALON.manillas[ordenId];
  await refrescarSalon();
}

async function anularManilla(entradaId, motivo, incluirUsadas) {
  const { data, error } = await sb.rpc("anular_entrada",
    { p_entrada: entradaId, p_motivo: motivo, p_incluir_usadas: !!incluirUsadas });
  if (error) { avisar(sinCodigo(error.message)); return; }
  avisar(data.motivo);
  SALON.anulandoEntrada = null;
  /* La lista abierta se vuelve a pedir: la fila anulada tiene que quedar
     marcada ahí mismo, no en el próximo refresco. */
  if (SALON.abierta) delete SALON.manillas[SALON.abierta];
  const abierta = SALON.abierta;
  await refrescarSalon();
  if (abierta) await abrirManillas(abierta);
}

/* ── el plano ──
   Una fila por mesa con x, y, w en PORCENTAJE del lienzo, no en píxeles:
   el mismo salón tiene que caer igual en la pantalla de la oficina y en el
   teléfono del que reparte. El lienzo pone el sistema de coordenadas
   (position:relative + aspect-ratio) y cada chapa se centra en su punto
   con translate(-50%,-50%). Es lo mismo que ya resolvía el plano de la
   venta antes de que la mesa pasara a venderse como producto; lo que
   cambia acá es el propósito: allá se elegía una para comprar, acá se
   mira quién la tiene. */
const PLANTA_TXT = { baja: "Planta baja", alta: "Planta alta" };
const CAT_TXT = { mesa: "Mesa", lounge: "Lounge", palco: "Palco" };
const ORDEN_PLANTA = { baja: 0, alta: 1 };   // la baja primero: es la que se llena

function pintarPlano(error) {
  const z = $("#zonaPlano");
  if (!z) return;
  const plantas = [...new Set(SALON.mesas.map(m => m.planta))].sort((a, b) =>
    (ORDEN_PLANTA[a] ?? 9) - (ORDEN_PLANTA[b] ?? 9) || String(a).localeCompare(b));
  const libres = SALON.mesas.filter(m => !m.ocupada).length;

  z.innerHTML = `
    <div class="cab-bloque">
      <h3 class="titulo-bloque">Plano de mesas</h3>
      <span class="conteo">${num(libres)} ${libres === 1 ? "libre" : "libres"} de ${num(SALON.mesas.length)}</span>
      <span class="leyenda">
        <span><i class="pip libre"></i>libre</span>
        <span><i class="pip ocupada"></i>ocupada</span>
      </span>
    </div>
    ${error ? `<p class="error">${esc(error.message)}</p>` : ""}
    ${SALON.mesas.length ? plantas.map(p => {
      const suyas = SALON.mesas.filter(m => m.planta === p);
      const l = suyas.filter(m => !m.ocupada).length;
      return `<section class="planta">
        <h4>${esc(PLANTA_TXT[p] || "Planta " + p)}
          <em>${num(l)} de ${num(suyas.length)} libres</em></h4>
        <div class="lienzo">${suyas.map(chapa).join("")}</div>
      </section>`;
    }).join("")
    : error ? "" : `<p class="vacio">Este evento no tiene mesas cargadas.</p>`}
    <div id="fichaMesa"></div>`;
  pintarFicha();
}

function chapa(m) {
  const sel = SALON.sel === m.id;
  return `<button type="button" class="chapa ${esc(m.categoria)}"
    data-mesa="${esc(m.id)}" data-ocupada="${m.ocupada ? 1 : 0}" data-sel="${sel ? 1 : 0}"
    aria-pressed="${sel}" aria-label="${esc(rotuloMesa(m))}"
    style="left:${Number(m.x)}%;top:${Number(m.y)}%;width:${Number(m.w)}%"
    ><span class="et">${esc(m.etiqueta)}</span></button>`;
}

function rotuloMesa(m) {
  const cat = CAT_TXT[m.categoria] || "Mesa";
  if (!m.ocupada) return `${cat} ${m.etiqueta}, ${manillasTxt(m.manillas)}, libre, ${bs(m.precio)}`;
  /* Para el relacionador, la mesa de otro llega `ocupada: true` con
     `comprador: null`. El corte ya lo hizo la base y acá se respeta tal
     cual: ni un "de otro relacionador" inventado ni el orden_id crudo. Un
     uuid no es un nombre, pero es un handle, y devolverlo por la pantalla
     sería deshacer a mano lo que la función se guardó. Ocupada, y ya. */
  return `${cat} ${m.etiqueta}, ${manillasTxt(m.manillas)}, ocupada` +
         (m.comprador ? `, la tiene ${m.comprador}` : "");
}

function marcarSeleccion() {
  document.querySelectorAll("#zonaPlano .chapa").forEach(b => {
    const s = b.dataset.mesa === SALON.sel;
    b.dataset.sel = s ? "1" : "0";
    b.setAttribute("aria-pressed", String(s));
  });
  pintarFicha();
}

function pintarFicha() {
  const f = $("#fichaMesa");
  if (!f) return;
  const m = SALON.mesas.find(x => x.id === SALON.sel);
  if (!m) {
    f.className = "ficha sin-mesa";
    f.innerHTML = `<p class="ayuda">Tocá una mesa para ver de qué tamaño es,
      cuánto cuesta y quién la tiene.</p>`;
    return;
  }
  const dueño = SALON.compras.find(c => mesaDeCompra(c) === m);
  const chica = noEntra(dueño, m);

  f.className = "ficha" + (m.ocupada ? " ocupada" : "");
  f.innerHTML = `
    <div class="ficha-cab">
      <span class="ficha-et">${esc(m.etiqueta)}</span>
      <div>
        <h4>${esc(CAT_TXT[m.categoria] || "Mesa")} ${esc(m.etiqueta)}
          · ${esc((PLANTA_TXT[m.planta] || m.planta)).toLowerCase()}</h4>
        <p>${manillasTxt(m.manillas)} · ${bs(m.precio)}</p>
      </div>
      <span class="pastilla ${m.ocupada ? "gris" : "verde"}">${m.ocupada ? "Ocupada" : "Libre"}</span>
    </div>
    ${m.ocupada ? `<p class="ficha-quien">${m.comprador
        ? `La tiene <b>${esc(m.comprador)}</b>${m.rrpp_nombre ? ` · vendió ${esc(m.rrpp_nombre)}` : ""}`
        : "Ocupada"}${m.orden_estado && m.orden_estado !== "pagada"
        ? ` · la orden está <b>${esc(m.orden_estado)}</b>` : ""}</p>` : ""}
    ${chica ? `<p class="chica-aviso">${esc(m.etiqueta)} es de ${num(m.manillas)} y
       lo que compró ${esc(dueño.comprador || "esta orden")} trae ${num(dueño.manillas)}:
       faltan ${num(Number(dueño.manillas) - Number(m.manillas))} lugares. Juntale otra mesa
       o avisale al equipo.</p>` : ""}
    ${SALON.editar ? accionesFicha(m) : ""}`;
}

function accionesFicha(m) {
  if (m.ocupada) {
    /* Sin orden_id no hay a quién liberarle: no puede pasar del lado del
       administrador —mesas_evento() se lo da entero— y si pasara, un botón
       que no sabe qué soltar es peor que no tenerlo. */
    return m.orden_id
      ? `<div class="ficha-acciones">
           <button type="button" class="btn plano chico" data-liberar="${esc(m.orden_id)}">Liberar la mesa</button>
         </div>` : "";
  }
  const sinMesa = SALON.compras.filter(c => !mesaDeCompra(c));
  if (!sinMesa.length) return `<p class="ayuda">No queda ninguna compra esperando mesa.</p>`;
  /* Primero las compras de mesa: son las que la están esperando de verdad.
     Las otras quedan abajo por si el equipo decide sentar a alguien igual,
     que es una decisión de la casa y no algo que la pantalla deba impedir. */
  const orden = [...sinMesa].sort((a, b) =>
    (compraDeMesa(b) ? 1 : 0) - (compraDeMesa(a) ? 1 : 0) ||
    Number(b.manillas) - Number(a.manillas));
  return `<div class="ficha-acciones">
    <select id="selCompra" aria-label="Compra a la que darle la mesa ${esc(m.etiqueta)}">
      ${orden.map(c => `<option value="${esc(c.orden_id)}"
        >${esc(c.comprador || "Sin nombre")} · ${manillasTxt(c.manillas)} · ${esc(c.detalle || "")}${
          noEntra(c, m) ? ` — no entra: la mesa es de ${num(m.manillas)}` : ""}</option>`).join("")}
    </select>
    <button type="button" class="btn primario chico" data-dar="${esc(m.id)}">Asignar</button>
  </div>`;
}

function clicEnPlano(e) {
  const ch = e.target.closest("button.chapa");
  if (ch) {
    SALON.sel = SALON.sel === ch.dataset.mesa ? null : ch.dataset.mesa;
    marcarSeleccion();
    return;
  }
  const b = e.target.closest("button[data-liberar],button[data-dar]");
  if (!b) return;
  if (b.dataset.liberar) return liberarMesa(b.dataset.liberar);
  const sel = $("#selCompra");
  if (sel && sel.value) return asignarMesa(sel.value, b.dataset.dar);
}

/* ── repartir ──
   asignar_mesa() NO valida que la mesa alcance para las manillas del
   combo, y es a propósito: los boliches juntan dos mesas para un grupo
   grande todo el tiempo, y bloquearlo haría que el administrador pelee
   con el sistema en vez de usarlo. Pero que la base no lo impida no
   significa que la pantalla se calle: el que reparte tiene que enterarse
   acá, no el sábado con veinte personas paradas frente a una mesa de
   catorce. Avisa, dice cuánto falta, y deja seguir. */
async function asignarMesa(ordenId, mesaId) {
  const c = SALON.compras.find(x => x.orden_id === ordenId);
  const m = SALON.mesas.find(x => x.id === mesaId);
  if (noEntra(c, m) && !confirm(
      `${m.etiqueta} es de ${m.manillas} y el combo trae ${c.manillas}: ` +
      `faltan ${Number(c.manillas) - Number(m.manillas)} lugares.\n\n` +
      `Se puede asignar igual —para eso se juntan mesas—, pero alguien se va a ` +
      `quedar parado si nadie lo sabe. ¿La asigno?`)) return;

  const { data, error } = await sb.rpc("asignar_mesa", { p_orden: ordenId, p_mesa: mesaId });
  /* El error es el 'Sin permiso' de puede_editar(): no es un resultado del
     reparto, es alguien que no debería haber llegado hasta acá. */
  if (error) { avisar(error.message); return; }
  /* `motivo` viene armado desde el SQL y se muestra TAL CUAL: nombra la
     mesa y a quién la tiene, y el que lo lee está parado frente al
     cliente. Rearmarlo acá perdería justo esos dos datos, que la pantalla
     no tiene cuando el update toca cero filas. `codigo` es para la
     máquina; para esto alcanza con `ok`. */
  avisar(data.motivo);
  SALON.asignando = null;
  if (data.ok) SALON.sel = mesaId;
  await refrescarSalon();
}

async function liberarMesa(ordenId) {
  const { data, error } = await sb.rpc("liberar_mesa", { p_orden: ordenId });
  if (error) { avisar(error.message); return; }
  avisar(data.motivo);
  SALON.asignando = null;
  await refrescarSalon();
}

/* ══ el registro de decisiones ════════════════════════════════════
   Abajo de todo en el tablero, y no arriba: no es una alerta, es lo que
   se mira cuando algo ya pasó y hay que explicarlo. Cada fila dice qué se
   hizo, por qué y quién — y el motivo va entero, sin recortar: es la
   única parte que nadie puede reconstruir después.

   La base no deja editarlo ni borrarlo (admin_bitacora es append-only),
   así que acá no hay un solo botón: es una pantalla de lectura. */
const ACCION_TXT = {
  orden_anulada:       "Compra anulada",
  entrada_anulada:     "Manilla anulada",
  cortesias_emitidas:  "Cortesías emitidas",
  revision_confirmada: "Revisión confirmada",
};

async function refrescarRegistro(eventoId) {
  const z = $("#zonaRegistro");
  if (!z) return;
  const { data, error } = await sb.rpc("bitacora_admin", { p_evento: eventoId });
  if (error) { z.innerHTML = `<p class="error">${esc(error.message)}</p>`; return; }
  const filas = (data && data.filas) || [];
  z.innerHTML = `
    <h3 class="titulo-bloque">Decisiones</h3>
    <p class="ayuda bajo-titulo">Anulaciones, cortesías y revisiones resueltas.
      Se escribe solo y no se puede editar ni borrar.${
      data && data.cortada ? ` Se muestran las últimas ${num(data.tope)} de ${num(data.total)}.` : ""}</p>
    ${filas.length ? `
      <div class="grilla-envoltorio">
        <table class="tabla tabla-registro">
          <thead><tr><th>Cuándo</th><th>Qué</th><th>Motivo</th><th>Quién</th></tr></thead>
          <tbody>${filas.map(f => `
            <tr>
              <td class="dato">${esc(fmtFH(f.ocurrio_at))}</td>
              <td><span class="prod-nombre">${esc(ACCION_TXT[f.accion] || f.accion)}</span>
                <em>${esc(detalleRegistro(f))}</em></td>
              <td class="detalle">${esc(f.motivo)}</td>
              <td class="dato">${esc(f.actor || "—")}</td>
            </tr>`).join("")}</tbody>
        </table>
      </div>`
      : `<p class="vacio">Todavía no se anuló ni se regaló nada en este evento.</p>`}`;
}

/* La línea chica de cada fila: lo que la decisión tocó, en el vocabulario
   de cada acción. Un "3" suelto no dice nada; "3 manillas · 1 ya había
   entrado" es lo que hace falta para entender una anulación vieja. */
function detalleRegistro(f) {
  const d = f.detalle || {};
  if (f.accion === "orden_anulada") {
    const usadas = Number(d.usadas_incluidas) || 0;
    return [
      d.comprador || "sin nombre",
      manillasTxt(d.entradas_anuladas || 0),
      usadas ? `${num(usadas)} ya ${usadas === 1 ? "había" : "habían"} entrado` : "",
      d.mesa_liberada ? "mesa liberada" : "",
      d.estado_previo === "revision_manual" ? "venía de una revisión" : "",
    ].filter(Boolean).join(" · ");
  }
  if (f.accion === "entrada_anulada") {
    return [d.code, d.cliente, d.estado_previo === "usada" ? "ya había entrado" : "",
            d.devuelve_cupo ? "devolvió su lugar" : ""].filter(Boolean).join(" · ");
  }
  if (f.accion === "cortesias_emitidas") {
    return [`${num(d.cantidad)} × ${d.tipo || ""}`, `para ${d.para || "—"}`].join(" · ");
  }
  if (f.accion === "revision_confirmada") {
    return [d.comprador || "sin nombre", manillasTxt(d.entradas || 0),
            d.monto_cobrado != null ? `cobrado ${bs(d.monto_cobrado)} de ${bs(d.total)}` : "",
            d.pago_ref ? `ref ${d.pago_ref}` : ""].filter(Boolean).join(" · ");
  }
  return "";
}

/* ══ cortesías ════════════════════════════════════════════════════
   El formulario más corto posible —qué, cuántas, para quién, por qué— y
   después los códigos, que es a lo que se vino. Sale de acá con algo que
   se pueda mandar: los códigos copiables de una, y las entradas dibujadas
   sobre el arte del evento con el mismo ticket.js de la venta. Una
   cortesía que se ve distinta a una entrada comprada es una cortesía que
   en la puerta se discute.

   `quedan` de cada producto se muestra al lado del nombre porque una
   cortesía consume cupo: el que regala cincuenta tiene que ver, en el
   momento de elegir, que le quedan cincuenta menos para vender. */
const CORT = { evento: null, ev: null, fase: null, productos: [], ultimas: null,
               dibujando: false, lista: [], total: 0, anulando: null };
const MES_TXT = ["ENE","FEB","MAR","ABR","MAY","JUN","JUL","AGO","SEP","OCT","NOV","DIC"];
const DIA_TXT = ["DOM","LUN","MAR","MIÉ","JUE","VIE","SÁB"];

/* La misma forma que arma la Edge Function `orden` para la página del
   comprador: ticket.js espera marca_1 / marca_2 / fecha_txt y no el
   registro crudo de la base. Se rearma acá en vez de tocar ticket.js
   porque el que manda es el dibujo, que ya está andando en dos páginas. */
function eventoParaTicket(e) {
  const f = new Date(e.fecha + "T00:00:00-04:00");
  const partes = String(e.nombre || "").split(" ");
  return {
    id: e.id,
    marca_1: partes[0] || "",
    marca_2: partes.slice(1).join(" "),
    lugar: e.lugar || "",
    fecha_txt: `${DIA_TXT[f.getDay()]} ${f.getDate()} ${MES_TXT[f.getMonth()]} · ${String(e.hora_inicio || "21:00").slice(0, 5)}`,
    arte_url: e.arte_url || null,
  };
}

async function pantallaCortesias(eventoId) {
  $("#main").innerHTML = `<p class="cargando">Cargando…</p>`;
  const [ev, res] = await Promise.all([
    sb.from("eventos").select("id,nombre,slug,lugar,fecha,hora_inicio,arte_url")
      .eq("id", eventoId).single(),
    sb.rpc("resumen_evento", { p_evento: eventoId }),
  ]);
  if (ev.error || !ev.data) { avisar("Ese evento ya no existe."); mostrar("eventos"); return; }
  if (res.error) { $("#main").innerHTML = `<p class="error">${esc(res.error.message)}</p>`; return; }

  const r = res.data || {};
  const faseId = r.evento && r.evento.fase_id;
  /* El arte de la fase gana sobre el del evento, como en ticket.js: una
     preventa se distingue a simple vista. */
  const fase = faseId
    ? (await sb.from("evento_fase").select("id,nombre,arte_url").eq("id", faseId).single()).data
    : null;

  Object.assign(CORT, { evento: eventoId, ev: ev.data, fase, ultimas: null,
                        lista: [], total: 0, anulando: null,
                        productos: (r.productos || []).filter(p => p.en_venta || p.quedan != null) });

  $("#main").innerHTML = `
    <div class="cab-seccion">
      <button class="btn plano chico" id="btnVolver">← ${esc(ev.data.nombre)}</button>
      <h2>Cortesías</h2>
    </div>
    ${faseId ? "" : `<p class="vacio">Este evento no tiene ninguna fase abierta hoy, así que
      no hay contra qué descontar el cupo. Abrí una fase en «Entradas y precios» y volvé.</p>`}
    <section class="tarjeta cortesias">
      <h3>Regalar entradas</h3>
      <p class="ayuda">Salen sin precio y sin compra, a nombre de quien digas, y
        <b>consumen cupo</b>: una cortesía ocupa un lugar igual que una entrada vendida.
        Hasta 50 por vez.</p>
      <form class="form-cortesias" id="formCortesias">
        <label><span>Producto</span>
          <select id="cTipo" required>
            ${CORT.productos.map(p => opcionDeProducto(p, false)).join("")}
          </select></label>
        <label><span>Cuántas</span>
          <input id="cCantidad" type="number" min="1" max="50" value="2" required></label>
        <label><span>A nombre de</span>
          <input id="cPara" required maxlength="80" autocomplete="off"
                 placeholder="Radio Line, el DJ, la marca…"></label>
        <label class="ancha"><span>Motivo</span>
          <input id="cMotivo" required maxlength="200" autocomplete="off"
                 placeholder="canje por la transmisión, invitados del DJ…"></label>
        <div class="acciones">
          <button class="btn primario" id="btnEmitir"${faseId ? "" : " disabled"}>Emitir</button>
        </div>
        <p class="error" id="cError"></p>
      </form>
    </section>
    <section id="zonaEmitidas"></section>
    <section id="zonaCortesias"><p class="cargando">Cargando las cortesías del evento…</p></section>`;

  $("#btnVolver").onclick = () => abrirEvento(eventoId);
  $("#formCortesias").onsubmit = ev2 => { ev2.preventDefault(); emitirCortesias(); };
  const zc = $("#zonaCortesias");
  zc.onclick = clicEnCortesias;
  zc.onsubmit = enviarEnCortesias;
  if (!CORT.productos.length) {
    $("#cError").textContent = "Este evento todavía no tiene ningún producto con precio en la fase de hoy.";
    $("#btnEmitir").disabled = true;
  }
  await cargarCortesias();
}

/* ── las que ya se regalaron ──
   Una cortesía no tiene orden, así que no aparece en la lista de
   compradores del tablero: sin esta lista, la manilla que se regaló por
   error no se puede anular desde ninguna pantalla y el organizador queda
   otra vez dependiendo de que alguien entre a la base. Es el mismo
   anular_entrada() de allá, con el mismo formulario. */
async function cargarCortesias() {
  const tope = 200;
  const { data, error, count } = await sb.from("entradas")
    .select("id,code,estado,cliente,created_at,tipo_entrada(nombre)", { count: "exact" })
    .eq("evento_id", CORT.evento)
    .eq("canal", "cortesia")
    .order("created_at", { ascending: false })
    .limit(tope);
  if (error) {
    $("#zonaCortesias").innerHTML = `<p class="error">${esc(error.message)}</p>`;
    return;
  }
  CORT.lista = data || [];
  CORT.total = count == null ? CORT.lista.length : count;
  pintarCortesias(tope);
}

function pintarCortesias(tope) {
  const z = $("#zonaCortesias");
  if (!z) return;
  const vivas = CORT.lista.filter(e => e.estado !== "anulada").length;
  z.innerHTML = `
    <h3 class="titulo-bloque">Cortesías de este evento</h3>
    <p class="ayuda bajo-titulo">${num(vivas)} ${vivas === 1 ? "vive" : "viven"} y
      ${vivas === 1 ? "ocupa" : "ocupan"} su lugar en el cupo.${
      CORT.total > tope ? ` Se muestran las últimas ${num(tope)} de ${num(CORT.total)}.` : ""}</p>
    ${CORT.lista.length ? `
      <div class="grilla-envoltorio">
        <table class="tabla tabla-manillas">
          <thead><tr><th>Código</th><th>Producto</th><th>A nombre de</th>
            <th>Cuándo</th><th>Estado</th><th class="col-accion"></th></tr></thead>
          <tbody>${CORT.lista.map(en => {
            const e = ESTADO_MANILLA[en.estado] || { txt: en.estado, cls: "gris" };
            return `<tr>
              <td class="dato"><code>${esc(en.code)}</code></td>
              <td>${esc((en.tipo_entrada && en.tipo_entrada.nombre) || "—")}</td>
              <td class="dato">${esc(en.cliente || "—")}</td>
              <td class="dato">${esc(fmtFH(en.created_at))}</td>
              <td><span class="pastilla ${e.cls}">${e.txt}</span></td>
              <td class="col-accion">${en.estado === "anulada" ? ""
                : `<button type="button" class="btn plano chico peligrosa"
                     data-anular-cortesia="${esc(en.id)}">Anular</button>`}</td>
            </tr>${CORT.anulando === en.id ? `
            <tr><td colspan="6">${formAnularManilla(en, true)}</td></tr>` : ""}`;
          }).join("")}</tbody>
        </table>
      </div>`
      : `<p class="vacio">Todavía no se regaló ninguna entrada de este evento.</p>`}`;
}

function clicEnCortesias(e) {
  const b = e.target.closest("button[data-anular-cortesia],button[data-cerrar]");
  if (!b) return;
  const id = b.dataset.anularCortesia;
  CORT.anulando = (b.dataset.cerrar || CORT.anulando === id) ? null : id;
  pintarCortesias(200);
}

function enviarEnCortesias(e) {
  const f = e.target.closest("form[data-anular-entrada]");
  if (!f) return;
  e.preventDefault();
  anularCortesia(f.dataset.anularEntrada,
                 f.elements.motivo.value,
                 !!(f.elements.usadas && f.elements.usadas.checked));
}

async function anularCortesia(entradaId, motivo, incluirUsadas) {
  const { data, error } = await sb.rpc("anular_entrada",
    { p_entrada: entradaId, p_motivo: motivo, p_incluir_usadas: !!incluirUsadas });
  if (error) { avisar(sinCodigo(error.message)); return; }
  avisar(data.motivo);
  CORT.anulando = null;
  await cargarCortesias();
  /* El lugar que devolvió tiene que verse en el selector de arriba: si
     `quedan` sigue diciendo lo de antes, la próxima tanda se elige con un
     número que ya no existe. */
  const res = await sb.rpc("resumen_evento", { p_evento: CORT.evento });
  if (res.data && res.data.productos) refrescarSelectorCortesias(res.data.productos);
}

async function emitirCortesias() {
  const b = $("#btnEmitir");
  $("#cError").textContent = "";
  b.disabled = true;
  const { data, error } = await sb.rpc("emitir_cortesias", {
    p_evento:   CORT.evento,
    p_tipo:     $("#cTipo").value,
    p_cantidad: Number($("#cCantidad").value),
    p_para:     $("#cPara").value,
    p_motivo:   $("#cMotivo").value,
  });
  b.disabled = false;
  if (error) { $("#cError").textContent = sinCodigo(error.message); return; }
  avisar(data.motivo);
  CORT.ultimas = data;
  $("#cPara").value = "";
  $("#cMotivo").value = "";
  pintarEmitidas();
  await cargarCortesias();
  /* El `quedan` del selector queda viejo apenas se emite: se vuelve a
     pedir el tablero para que la próxima tanda se elija con el número de
     ahora y no con el de hace un minuto. */
  const res = await sb.rpc("resumen_evento", { p_evento: CORT.evento });
  if (res.data && res.data.productos) refrescarSelectorCortesias(res.data.productos);
}

function refrescarSelectorCortesias(productos) {
  CORT.productos = productos.filter(p => p.en_venta || p.quedan != null);
  const sel = $("#cTipo");
  if (!sel) return;
  const elegido = sel.value;
  sel.innerHTML = CORT.productos.map(p => opcionDeProducto(p, p.tipo_id === elegido)).join("");
}

const opcionDeProducto = (p, elegido) => `<option value="${esc(p.tipo_id)}"${
  elegido ? " selected" : ""}>${esc(p.nombre)}${
  p.quedan == null ? " · sin tope" : ` · quedan ${num(p.quedan)}`}${
  p.manillas_por_unidad > 1 ? ` · ${num(p.manillas_por_unidad)} manillas por unidad` : ""}</option>`;

function pintarEmitidas() {
  const z = $("#zonaEmitidas");
  const d = CORT.ultimas;
  if (!z || !d) return;
  const codes = d.codes || [];
  z.innerHTML = `
    <section class="tarjeta emitidas">
      <h3>${num(codes.length)} ${codes.length === 1 ? "cortesía emitida" : "cortesías emitidas"}</h3>
      <p class="ayuda">${esc(d.tipo)} a nombre de <b>${esc(d.para)}</b>.${
        d.quedan == null ? "" : ` Quedan ${num(d.quedan)} para vender.`}</p>
      <div class="codigos" id="codigosCortesias">${codes.map(c =>
        `<code>${esc(c)}</code>`).join(" ")}</div>
      <div class="acciones">
        <button type="button" class="btn plano chico" data-copiar="codigosCortesias"
                data-que="Los códigos">Copiar los códigos</button>
        <button type="button" class="btn plano chico" id="btnDibujar">Dibujar las entradas</button>
      </div>
      <div id="zonaTickets"></div>
    </section>`;
  cablearCopiar();
  const bd = $("#btnDibujar");
  /* Sin la librería del QR no se dibuja nada, y decirlo es mejor que un
     botón que no hace nada: los códigos de arriba alcanzan para mandarlos
     por WhatsApp y que la puerta los cargue a mano. */
  if (typeof qrcode !== "function" || !window.dibujarTicket) {
    bd.disabled = true;
    bd.title = "No cargó la librería del QR. Los códigos de arriba sirven igual.";
    return;
  }
  bd.onclick = () => dibujarCortesias();
}

async function dibujarCortesias() {
  const d = CORT.ultimas, z = $("#zonaTickets");
  if (!d || !z || CORT.dibujando) return;
  CORT.dibujando = true;
  z.innerHTML = `<p class="cargando">Dibujando…</p>`;
  if (document.fonts && document.fonts.ready) await document.fonts.ready;
  const evento = eventoParaTicket(CORT.ev);
  const pngs = [];
  try {
    for (const code of d.codes) {
      pngs.push(await window.dibujarTicket(
        { code, cliente: d.para, etiqueta: d.tipo }, evento, CORT.fase));
    }
  } catch (e) {
    CORT.dibujando = false;
    z.innerHTML = `<p class="error">No se pudieron dibujar: ${esc(e.message)}</p>`;
    return;
  }
  CORT.dibujando = false;
  z.innerHTML = `
    <div class="tickets-rail">${pngs.map((p, i) =>
      `<img src="${p}" alt="Cortesía ${esc(d.codes[i])}" loading="lazy">`).join("")}</div>
    <div class="acciones">
      <button type="button" class="btn primario chico" id="btnBajar">Descargar las ${num(pngs.length)}</button>
    </div>`;
  $("#btnBajar").onclick = () => {
    pngs.forEach((p, i) => {
      const a = document.createElement("a");
      a.href = p;
      a.download = `cortesia-${i + 1}-${d.codes[i]}.png`;
      document.body.appendChild(a); a.click(); a.remove();
    });
    avisar(`${pngs.length} ${pngs.length === 1 ? "entrada descargada" : "entradas descargadas"}.`);
  };
}

/* ══ la revisión manual ═══════════════════════════════════════════
   El caso más delicado del sistema: plata cobrada de un lado y ninguna
   entrada emitida del otro, con una persona esperando. La pantalla pone
   las dos cifras una al lado de la otra —lo esperado y lo que la pasarela
   dijo haber cobrado— con la diferencia ya restada, y el `pago_ref`
   copiable para ir a buscar el cobro en el panel de la pasarela. Sin eso,
   las dos decisiones se toman a ciegas.

   Confirmar emite las entradas. Anular cierra la compra. Las dos piden un
   motivo escrito, y no es burocracia: es la decisión que alguien va a
   tener que justificar. */
const REV = { evento: null, filas: [], abierta: null, decision: null };

async function pantallaRevision(eventoId) {
  $("#main").innerHTML = `<p class="cargando">Cargando…</p>`;
  const ev = await sb.from("eventos").select("id,nombre").eq("id", eventoId).single();
  if (ev.error || !ev.data) { avisar("Ese evento ya no existe."); mostrar("eventos"); return; }

  Object.assign(REV, { evento: eventoId, filas: [], abierta: null, decision: null });
  $("#main").innerHTML = `
    <div class="cab-seccion">
      <button class="btn plano chico" id="btnVolver">← Tablero</button>
      <h2>Revisión manual</h2>
    </div>
    <p class="ayuda bajo-titulo">La pasarela cobró un monto distinto al esperado, así que
      estas compras quedaron sin entradas emitidas. Miralas de a una con el
      código de la pasarela y decidí: emitir igual, o anular.</p>
    <section id="zonaRevision"><p class="cargando">Cargando…</p></section>`;
  $("#btnVolver").onclick = () => pantallaTablero(eventoId);
  const z = $("#zonaRevision");
  z.onclick = clicEnRevision;
  z.onsubmit = enviarEnRevision;
  await cargarRevision();
}

async function cargarRevision() {
  const { data, error } = await sb.rpc("ordenes_en_revision", { p_evento: REV.evento });
  if (error) { $("#zonaRevision").innerHTML = `<p class="error">${esc(error.message)}</p>`; return; }
  REV.filas = data || [];
  pintarRevision();
}

function pintarRevision() {
  const z = $("#zonaRevision");
  if (!z) return;
  z.innerHTML = REV.filas.length
    ? REV.filas.map(tarjetaRevision).join("")
    : `<p class="vacio">No quedó ninguna compra en revisión. Nadie pagó de más ni de menos.</p>`;
  cablearCopiar();
}

function tarjetaRevision(o) {
  const dif = o.diferencia == null ? null : Number(o.diferencia);
  return `<article class="rev-tarjeta" data-orden="${esc(o.orden_id)}">
    <div class="rev-cab">
      <div>
        <h4>${esc(o.comprador || "Sin nombre")}</h4>
        <p>${esc(o.telefono || "sin teléfono")}${o.email ? ` · ${esc(o.email)}` : ""}
          · ${esc(fmtFH(o.fecha))}</p>
      </div>
      <span class="pastilla aviso">Sin entradas emitidas</span>
    </div>
    <p class="rev-detalle">${esc(o.detalle || "—")}</p>
    <div class="rev-plata">
      <span><em>Esperado</em><b>${bs(o.total)}</b></span>
      <span><em>Cobrado</em><b>${o.monto_cobrado == null
        ? `<i class="tenue">no quedó anotado</i>` : bs(o.monto_cobrado)}</b></span>
      <span class="rev-dif ${dif == null ? "" : dif < 0 ? "menos" : "mas"}"><em>Diferencia</em><b>${
        dif == null ? "—" : (dif > 0 ? "+" : "") + bs(dif)}</b></span>
    </div>
    ${o.pago_ref ? `<div class="link-publico">
      <span class="clave-rotulo">Pasarela</span>
      <code id="ref-${esc(o.orden_id)}">${esc(o.pago_ref)}</code>
      <button type="button" class="btn plano chico" data-copiar="ref-${esc(o.orden_id)}"
              data-que="El código de la pasarela">Copiar</button>
    </div>` : `<p class="ayuda">Esta compra no tiene código de pasarela anotado.</p>`}
    ${REV.abierta === o.orden_id ? formRevision(o) : `
    <div class="acciones">
      <button type="button" class="btn primario chico" data-decidir="confirmar"
              data-orden="${esc(o.orden_id)}">Confirmar y emitir</button>
      <button type="button" class="btn plano chico peligrosa" data-decidir="anular"
              data-orden="${esc(o.orden_id)}">Anular la compra</button>
    </div>`}
  </article>`;
}

function formRevision(o) {
  const conf = REV.decision === "confirmar";
  return `<form class="form-anular" data-resolver="${esc(o.orden_id)}">
    <p class="anular-que">${conf
      ? `Se emiten las <b>${num(o.unidades)} ${o.unidades === 1 ? "unidad" : "unidades"}</b>
         de esta compra y queda como pagada, aunque la pasarela haya cobrado
         ${o.monto_cobrado == null ? "otro monto" : bs(o.monto_cobrado)} en vez de ${bs(o.total)}.`
      : `Se anula la compra entera. No se emite ninguna entrada y
         ${o.monto_cobrado == null ? "lo cobrado" : bs(o.monto_cobrado)} <b>no se devuelve solo</b>:
         el reintegro se hace en la pasarela.`} <b>Esto no se deshace.</b></p>
    <label class="anular-motivo"><span>Motivo</span>
      <input name="motivo" required maxlength="200" autocomplete="off"
             placeholder="${conf ? "pagó 1 Bs de menos por redondeo, se acepta" : "no aparece el cobro en la pasarela"}"></label>
    <div class="acciones">
      <button type="submit" class="btn primario chico">${conf ? "Confirmar y emitir" : "Anular la compra"}</button>
      <button type="button" class="btn plano chico" data-cerrar="1">Cancelar</button>
    </div>
  </form>`;
}

function clicEnRevision(e) {
  const b = e.target.closest("button[data-decidir],button[data-cerrar]");
  if (!b) return;
  if (b.dataset.cerrar) { REV.abierta = null; REV.decision = null; pintarRevision(); return; }
  REV.abierta = b.dataset.orden;
  REV.decision = b.dataset.decidir;
  pintarRevision();
}

function enviarEnRevision(e) {
  const f = e.target.closest("form[data-resolver]");
  if (!f) return;
  e.preventDefault();
  resolverRevision(f.dataset.resolver, REV.decision, f.elements.motivo.value);
}

async function resolverRevision(ordenId, decision, motivo) {
  const { data, error } = await sb.rpc("resolver_revision",
    { p_orden: ordenId, p_decision: decision, p_motivo: motivo });
  if (error) { avisar(sinCodigo(error.message)); return; }
  avisar(data.motivo);
  REV.abierta = null;
  REV.decision = null;
  await cargarRevision();
}

/* ══ el equipo ════════════════════════════════════════════════════
   Hasta hoy dar de alta a alguien era `python3 scripts/crear-usuario.py`,
   o sea una terminal, y el organizador de un boliche no tiene una. Peor:
   la pantalla del relacionador le dice al que no tiene código "pedíselo a
   un administrador, te lo carga en tu perfil" — y el administrador no
   tenía dónde cargarlo. El circuito terminaba en una instrucción que no
   se podía seguir. Los slugs de nico y dani se los puso alguien con SQL
   a mano; esta pantalla es para que eso no vuelva a pasar.

   Dos caminos, y la diferencia no es de comodidad:

   · Crear una cuenta, resetear una clave, activar/desactivar y cambiar el
     rol pasan por la Edge Function `equipo`. Escribir en auth.users pide
     service_role, que no puede vivir en el navegador; y las guardias que
     importan —quién llama, de qué organizador, y que nadie se desactive a
     sí mismo— tienen que decidirse del lado del servidor.
   · El slug y la comisión de alguien que ya existe son un update sobre
     `perfiles`, y la policy de 0002 ya deja que el admin toque las filas
     de SU organizador. Van directo por PostgREST: meter una función en el
     medio no agregaría ninguna garantía, solo un salto más que se puede
     desincronizar.

   Nada de los `if` de rol de acá es seguridad: el que llegue por consola
   se choca con la función o con la RLS, que son las que deciden. */

const EQ = { gente: [], editando: null, alta: false, clave: null };

const ROLES_TXT = { admin: "Administrador", staff: "Staff",
                    rrpp: "Relacionador", portero: "Portero" };

/* Se llama con `fetch` y no con sb.functions.invoke a propósito: invoke
   convierte cualquier respuesta que no sea 2xx en un error genérico y
   tira el cuerpo, o sea justo el `motivo` que esta pantalla necesita
   mostrar ("ese usuario ya está tomado", "ya hay alguien con ese
   código"). Sin el cuerpo, el administrador leería "Edge Function
   returned a non-2xx status code" y no sabría qué corregir.

   El token sale de la sesión viva —getSession() lo renueva solo si
   venció— y viaja en el Authorization. La función no cree nada de lo que
   le mandemos: se lo pregunta a /auth/v1/user. */
async function llamarEquipo(cuerpo) {
  const { data: { session } } = await sb.auth.getSession();
  if (!session) throw new Error("Se cerró tu sesión. Entrá de nuevo.");
  const r = await fetch(`${CFG.SUPABASE_URL}/functions/v1/equipo`, {
    method: "POST",
    headers: { "Content-Type": "application/json",
               apikey: CFG.SUPABASE_ANON_KEY,
               Authorization: `Bearer ${session.access_token}` },
    body: JSON.stringify(cuerpo),
  });
  const txt = await r.text();
  let j = null;
  try { j = txt ? JSON.parse(txt) : null; } catch { /* la reja del gateway no contesta JSON */ }
  if (!j) throw new Error(r.status === 401
    ? "Se cerró tu sesión. Entrá de nuevo."
    : `No se pudo completar (${r.status}).`);
  if (!j.ok) throw new Error(j.motivo || "La operación fue rechazada.");
  return j;
}

/* `mantenerClave` lo pasan los refrescos de adentro de la pantalla: la
   clave recién generada no puede desaparecer porque se desactivó a otro,
   pero sí tiene que irse al salir de Equipo y volver. Una clave que
   reaparece sola contradice el "se ve una sola vez" que dice el cartel. */
async function pantallaEquipo(opts) {
  $("#main").innerHTML = `<p class="cargando">Cargando el equipo…</p>`;
  EQ.editando = null;
  EQ.alta = false;
  if (!(opts && opts.mantenerClave)) EQ.clave = null;
  /* El filtro por organizador va del lado del servidor aunque la RLS ya
     lo haga: es la misma regla de siempre —PostgREST corta en 1000 filas
     sin avisar y lo que se filtra en JS no ahorra ese corte— y además
     deja escrito acá qué lista se está pidiendo. */
  const { data, error } = await sb.from("perfiles")
    .select("id,nombre,rol,activo,slug,comision_entrada")
    .eq("organizador_id", S.yo.organizador_id)
    .order("activo", { ascending: false })
    .order("nombre");
  if (error) { $("#main").innerHTML = `<p class="error">${esc(error.message)}</p>`; return; }
  EQ.gente = data || [];
  pintarEquipo();
}

function pintarEquipo() {
  $("#main").innerHTML = `
    <div class="cab-seccion">
      <h2>Equipo</h2>
      <button class="btn primario" id="btnAlta">Dar de alta</button>
    </div>
    <p class="ayuda equipo-intro">Cada persona entra al panel con su usuario y su
      clave. No hay correo ni recuperación: la clave se muestra una sola vez, y si
      se pierde se resetea desde acá.</p>
    <div id="zonaClave">${bloqueClave()}</div>
    <div id="zonaAlta">${EQ.alta ? formAlta() : ""}</div>
    ${EQ.gente.length ? `<ul class="lista" id="listaEquipo">${
      EQ.gente.map(filaPersona).join("")}</ul>`
      /* La lista siempre te incluye a vos, así que vacía significa que la
         sesión dejó de resolver un perfil: no es un estado normal. */
      : `<p class="vacio">No aparece nadie, ni siquiera vos. Salí y volvé a entrar.</p>`}`;

  $("#btnAlta").onclick = () => { EQ.alta = !EQ.alta; EQ.editando = null; pintarEquipo(); };
  cablearCopiar();
  const okClave = $("#btnClaveOk");
  if (okClave) okClave.onclick = () => { EQ.clave = null; pintarEquipo(); };
  if (EQ.alta) cablearAlta();
  if (EQ.editando) cablearEdicion();
  const lista = $("#listaEquipo");
  if (lista) lista.onclick = clicEnEquipo;
}

/* ── la clave recién generada ──
   Va arriba de todo y no se va sola: es el único momento en que existe.
   No se guarda, no se loguea y no se manda por ningún lado — si esta caja
   se cierra sin que nadie la copie, lo único que queda es resetearla. */
function bloqueClave() {
  if (!EQ.clave) return "";
  const c = EQ.clave;
  return `<section class="tarjeta clave-nueva">
    <h3>${esc(c.titulo)}</h3>
    <p class="ayuda">Anotala o copiala ahora. Esta es la única vez que se ve:
      no se guarda en ningún lado y no hay correo de recuperación. Si se
      pierde, lo único que se puede hacer es resetearla y generar otra.</p>
    <p class="link-publico"><span class="clave-rotulo">Usuario</span>
      <code id="claveUsuario">${esc(c.usuario)}</code>
      <button type="button" class="btn plano chico" data-copiar="claveUsuario"
        data-que="El usuario">Copiar</button></p>
    <p class="link-publico"><span class="clave-rotulo">Clave</span>
      <code id="claveClave" class="clave-valor">${esc(c.clave)}</code>
      <button type="button" class="btn plano chico" data-copiar="claveClave"
        data-que="La clave">Copiar</button></p>
    <div class="acciones"><button type="button" class="btn plano chico" id="btnClaveOk">Ya la anoté</button></div>
  </section>`;
}

function filaPersona(p) {
  const yo = p.id === S.yo.id;
  const editando = EQ.editando === p.id;
  return `<li class="fila quieta persona${p.activo ? "" : " inactiva"}" data-id="${esc(p.id)}">
    <span class="fila-nombre">${esc(p.nombre)}
      <em>${esc(ROLES_TXT[p.rol] || p.rol)}${p.rol === "rrpp"
        ? p.slug ? ` · <b>?r=${esc(p.slug)}</b>` : ` · <b class="falta-slug">sin código</b>`
        : ""}</em></span>
    <span class="pastilla ${p.activo ? "verde" : "gris"}">${p.activo ? "Activa" : "Inactiva"}</span>
    <span class="cifra">${p.rol !== "rrpp" ? ""
      : p.comision_entrada == null ? `—<em>comisión del evento</em>`
      : `${bs(p.comision_entrada)}<em>por entrada</em>`}</span>
    <span class="persona-acciones">
      <button type="button" class="btn plano chico" data-editar="${esc(p.id)}"
        >${editando ? "Cerrar" : "Editar"}</button>
      <button type="button" class="btn plano chico" data-clave="${esc(p.id)}">Resetear clave</button>
      ${yo
        /* El botón de desactivarse no se dibuja: la función lo rechaza igual, y
           un botón que siempre rebota enseña a desconfiar de los botones. */
        ? `<span class="nota-yo" title="A vos mismo no: es cómo un organizador se queda sin ningún administrador y sin forma de recuperar la cuenta.">sos vos</span>`
        : `<button type="button" class="btn plano chico" data-activo="${esc(p.id)}"
             >${p.activo ? "Desactivar" : "Reactivar"}</button>`}
    </span>
    ${editando ? formEdicion(p, yo) : ""}
  </li>`;
}

/* ── editar: el código y la comisión ──
   Los dos campos que hacían falta y no existían en ninguna pantalla. */
function formEdicion(p, yo) {
  return `<form class="form-persona" id="formEdicion">
    <label><span>Rol</span>
      <select id="edRol"${yo ? " disabled" : ""}>
        ${Object.keys(ROLES_TXT).map(r =>
          `<option value="${r}"${r === p.rol ? " selected" : ""}>${ROLES_TXT[r]}</option>`).join("")}
      </select>
      ${yo ? `<em class="ayuda">A vos mismo no: así es como un organizador se
        queda sin ningún administrador.</em>` : ""}</label>
    <label><span>Código de relacionador</span>
      <input id="edSlug" value="${esc(p.slug || "")}" placeholder="sin código"
             pattern="[a-z0-9\\-]{2,30}" autocapitalize="none" autocomplete="off">
      <em class="ayuda">Es lo que va en el <b>?r=</b> de su link de venta. Minúsculas,
        números y guiones. Sin código, su link no se puede armar.</em></label>
    <label><span>Comisión por entrada</span>
      <input id="edComision" type="number" min="0" step="0.5"
             value="${p.comision_entrada == null ? "" : Number(p.comision_entrada)}"
             placeholder="la del evento">
      <em class="ayuda">Un <b>monto fijo en Bs</b> por entrada vendida, nunca un
        porcentaje: si mañana sube el precio de la entrada, esto no se mueve.
        Vacío = usa la comisión que tenga cargada el evento.</em></label>
    <div class="acciones">
      <button class="btn primario chico" id="btnGuardarPersona">Guardar</button>
      <button type="button" class="btn plano chico" data-cerrar-edicion="1">Cancelar</button>
    </div>
    <p class="error" id="edError"></p>
  </form>`;
}

function cablearEdicion() {
  const f = $("#formEdicion");
  if (!f) return;
  f.onsubmit = async e => {
    e.preventDefault();
    const p = EQ.gente.find(x => x.id === EQ.editando);
    if (!p) return;
    const err = $("#edError");
    err.textContent = "";
    const slug = $("#edSlug").value.trim().toLowerCase();
    const com  = $("#edComision").value.trim();
    const rol  = $("#edRol").value;

    if (slug && !/^[a-z0-9-]{2,30}$/.test(slug)) {
      err.textContent = "El código va en minúsculas, entre 2 y 30 caracteres, y solo admite letras, números y guiones.";
      return;
    }
    if (com !== "" && !(Number(com) >= 0)) {
      err.textContent = "La comisión es un monto en Bs: un número de 0 para arriba, o vacío.";
      return;
    }
    $("#btnGuardarPersona").disabled = true;
    try {
      /* .select() no es decoración: un update que la RLS filtra no da
         error, contesta 204 y cero filas. Sin pedir las filas de vuelta,
         el caso más silencioso —el que no tenía permiso— vería "listo"
         con la base intacta. Ya nos pasó con el arte. */
      const { data: filas, error } = await sb.from("perfiles")
        .update({ slug: slug || null,
                  comision_entrada: com === "" ? null : Number(com) })
        .eq("id", p.id).select("id,nombre,rol,activo,slug,comision_entrada");
      if (error) throw new Error(errorDePerfil(error));
      if (!filas || !filas.length) throw new Error(
        "La base no dejó guardar el cambio: no se modificó nada.");

      /* El rol va por la función porque la guardia que importa —que nadie
         se baje el rol a sí mismo— tiene que decidirse del lado del
         servidor. Se manda solo si cambió: una llamada de más a la
         función que crea cuentas no es gratis. */
      if (rol !== p.rol) await llamarEquipo({ accion: "rol", id: p.id, rol });

      avisar("Guardado.");
      EQ.editando = null;
      await pantallaEquipo({ mantenerClave: true });
    } catch (ex) {
      err.textContent = ex.message;
      const b = $("#btnGuardarPersona");
      if (b) b.disabled = false;
    }
  };
}

/* Los códigos de Postgres traducidos donde el organizador los va a leer.
   El mensaje crudo dice «duplicate key value violates unique constraint
   "perfiles_slug_uk"», que no le explica a nadie qué tiene que cambiar. */
function errorDePerfil(error) {
  if (error.code === "23505") return "Ya hay alguien con ese código en tu equipo. Elegí otro.";
  if (error.code === "23514") return "El código va en minúsculas, entre 2 y 30 caracteres, y solo admite letras, números y guiones.";
  return error.message;
}

/* ── el alta ──
   El código del relacionador se pide ACÁ, en el mismo formulario: que
   haya que volver después a completarlo es exactamente el bache que esta
   pantalla vino a tapar. */
function formAlta() {
  return `<section class="tarjeta">
    <h3>Dar de alta</h3>
    <form class="form-persona" id="formAlta">
      <label><span>Usuario</span>
        <input id="alUsuario" required autocapitalize="none" autocomplete="off"
               pattern="[a-z0-9.\\-]{3,30}" placeholder="nico">
        <em class="ayuda">Con esto entra al panel. Minúsculas, números, punto y
          guión; entre 3 y 30. No se puede cambiar después.</em></label>
      <label><span>Nombre</span>
        <input id="alNombre" required maxlength="80" placeholder="Nicolás Vargas">
        <em class="ayuda">Como lo vas a reconocer en las listas de ventas.</em></label>
      <label><span>Rol</span>
        <select id="alRol">
          ${Object.keys(ROLES_TXT).map(r =>
            `<option value="${r}"${r === "rrpp" ? " selected" : ""}>${ROLES_TXT[r]}</option>`).join("")}
        </select>
        <em class="ayuda" id="alRolAyuda"></em></label>
      <div id="alZonaRrpp" class="alta-rrpp">
        <label><span>Código de relacionador</span>
          <input id="alSlug" autocapitalize="none" autocomplete="off"
                 pattern="[a-z0-9\\-]{2,30}" placeholder="nico">
          <em class="ayuda">Lo que va en el <b>?r=</b> de su link. Sin esto, el link
            no se puede armar y su primera noche no se le atribuye a nadie.</em></label>
        <label><span>Comisión por entrada</span>
          <input id="alComision" type="number" min="0" step="0.5" placeholder="la del evento">
          <em class="ayuda">Un <b>monto fijo en Bs</b> por entrada, nunca un porcentaje.
            Vacío = usa la del evento.</em></label>
      </div>
      <div class="acciones">
        <button class="btn primario" id="btnCrear">Crear la cuenta</button>
        <button type="button" class="btn plano" id="btnCancelarAlta">Cancelar</button>
      </div>
      <p class="error" id="alError"></p>
    </form>
  </section>`;
}

const AYUDA_ROL = {
  admin:   "Todo, incluida esta pantalla. Que haya más de uno es lo que evita quedarse afuera.",
  staff:   "Eventos, precios y el salón. No da de alta a nadie.",
  rrpp:    "Solo lo suyo: su link, sus ventas y su comisión.",
  portero: "Solo la pantalla de Puerta, para escanear en el ingreso.",
};

function cablearAlta() {
  const rol = $("#alRol");
  const verSegunRol = () => {
    $("#alZonaRrpp").hidden = rol.value !== "rrpp";
    $("#alRolAyuda").textContent = AYUDA_ROL[rol.value] || "";
  };
  rol.onchange = verSegunRol;
  verSegunRol();
  /* El código se propone solo a partir del usuario, que es lo que el
     administrador ya escribió, y deja de proponerse en cuanto lo toca a
     mano: adivinarle encima lo que escribió es peor que no adivinar. */
  const slug = $("#alSlug");
  slug.oninput = () => { slug.dataset.tocado = "1"; };
  $("#alUsuario").oninput = e => {
    if (slug.dataset.tocado) return;
    slug.value = e.target.value.trim().toLowerCase().replace(/[^a-z0-9-]/g, "");
  };
  $("#btnCancelarAlta").onclick = () => { EQ.alta = false; pintarEquipo(); };

  $("#formAlta").onsubmit = async e => {
    e.preventDefault();
    const err = $("#alError");
    err.textContent = "";
    const usuario = $("#alUsuario").value.trim().toLowerCase();
    const nombre  = $("#alNombre").value.trim();
    const r       = rol.value;
    const esRrpp  = r === "rrpp";
    const sSlug   = esRrpp ? $("#alSlug").value.trim().toLowerCase() : "";
    const sCom    = esRrpp ? $("#alComision").value.trim() : "";

    if (!/^[a-z0-9.-]{3,30}$/.test(usuario)) {
      err.textContent = "El usuario va en minúsculas, entre 3 y 30 caracteres, y solo admite letras, números, punto y guión.";
      return;
    }
    if (sSlug && !/^[a-z0-9-]{2,30}$/.test(sSlug)) {
      err.textContent = "El código va en minúsculas, entre 2 y 30 caracteres, y solo admite letras, números y guiones.";
      return;
    }
    /* Un relacionador sin código es el bache de siempre; no se prohíbe
       —puede que el código se decida mañana— pero no sale en silencio. */
    if (esRrpp && !sSlug && !confirm(
        "Sin código, este relacionador no va a tener link de venta y no vas a " +
        "poder atribuirle ninguna entrada.\n\n¿Lo creo igual?")) return;

    $("#btnCrear").disabled = true;
    try {
      const res = await llamarEquipo({
        accion: "crear", usuario, nombre, rol: r,
        slug: sSlug || null, comision_entrada: sCom === "" ? null : Number(sCom),
      });
      EQ.clave = { titulo: `La clave de ${nombre}`, usuario: res.usuario, clave: res.clave };
      EQ.alta = false;
      avisar("Cuenta creada.");
      await pantallaEquipo({ mantenerClave: true });
    } catch (ex) {
      err.textContent = ex.message;
      const b = $("#btnCrear");
      if (b) b.disabled = false;
    }
  };
}

function clicEnEquipo(e) {
  const b = e.target.closest("button[data-editar],button[data-clave],button[data-activo],button[data-cerrar-edicion]");
  if (!b) return;
  const d = b.dataset;
  if (d.cerrarEdicion) { EQ.editando = null; pintarEquipo(); return; }
  if (d.editar) {
    EQ.editando = EQ.editando === d.editar ? null : d.editar;
    EQ.alta = false;
    pintarEquipo();
    return;
  }
  if (d.clave)  return resetearClave(d.clave);
  if (d.activo) return cambiarActivo(d.activo);
}

async function resetearClave(id) {
  const p = EQ.gente.find(x => x.id === id);
  if (!p) return;
  if (!confirm(`¿Generar una clave nueva para ${p.nombre}?\n\n` +
    `La de ahora deja de servir en el acto, y la nueva se ve una sola vez.`)) return;
  try {
    const res = await llamarEquipo({ accion: "resetear", id });
    EQ.clave = { titulo: `La clave nueva de ${p.nombre}`, usuario: res.usuario, clave: res.clave };
    avisar("Clave reseteada.");
    pintarEquipo();
    window.scrollTo({ top: 0, behavior: "smooth" });
  } catch (ex) {
    avisar(ex.message);
  }
}

/* Desactivar, nunca borrar: alguien con ventas hechas no se puede borrar
   sin llevarse puesto el historial de comisiones, y a la primera
   discusión con un relacionador te quedaste sin la prueba de cuánto
   vendió. Desactivado no entra al panel y su token deja de abrir nada
   —mi_rol() y mi_organizador() filtran por `activo`— pero sus ventas
   siguen contando. */
async function cambiarActivo(id) {
  const p = EQ.gente.find(x => x.id === id);
  if (!p) return;
  if (p.activo && !confirm(`¿Desactivar a ${p.nombre}?\n\n` +
    `No va a poder entrar más al panel. Sus ventas y sus comisiones quedan ` +
    `intactas: esto no borra a nadie, y se puede reactivar cuando quieras.`)) return;
  try {
    await llamarEquipo({ accion: "activo", id, activo: !p.activo });
    avisar(p.activo ? `${p.nombre} quedó desactivado.` : `${p.nombre} vuelve a entrar.`);
    await pantallaEquipo({ mantenerClave: true });
  } catch (ex) {
    avisar(ex.message);
  }
}

/* ── arranque: si ya había sesión, entrar directo ── */
(async () => {
  try {
    if (await cargarPerfil()) arrancarApp();
  } catch { /* sesión vieja o cuenta deshabilitada: queda la pantalla de entrar */ }
})();

window.ADMIN = { S, sb, mostrar, avisar, esc };   // para las tareas siguientes
})();
