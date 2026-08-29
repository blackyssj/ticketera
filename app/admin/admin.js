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
               <button type="button" class="btn plano" id="btnRrpp">Relacionadores →</button>` : ""}
      </div>
      <p class="error" id="fError"></p>
    </form>
    ${id && puedeEditar() ? `<section class="tarjeta arte" id="zonaArte"></section>` : ""}`;

  $("#btnVolver").onclick = () => mostrar("eventos");
  $("#fSlug").oninput = ev => $("#vistaSlug").textContent = ev.target.value || "…";
  if (id) {
    $("#btnTablero").onclick = () => pantallaTablero(id);
    $("#btnEntradas").onclick = () => pantallaEntradas(id);
    $("#btnRrpp").onclick = () => pantallaRelacionadores(id);
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
    <section id="zonaPlano"></section>`;

  $("#btnVolver").onclick = () => abrirEvento(eventoId);

  /* El salón se recarga solo cuando se reparte una mesa, y el tablero se
     entera por acá: la alerta de "mesas sin asignar" es la que se está
     bajando, y una alerta que sigue diciendo 2 después de asignar la
     primera enseña a no creerle. */
  await Promise.all([
    refrescarResumen(eventoId),
    montarSalon(eventoId, { editar: puedeEditar(),
                            alCambiar: () => refrescarResumen(eventoId) }),
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
      nivel: "peligro", plano: true },
    { cifra: a.revision_manual.ordenes,
      titulo: "En revisión manual",
      pie: `${bs(a.revision_manual.monto)} cobrados`,
      viva: "La pasarela cobró un monto distinto al esperado. Hay que mirarlas de a una: es plata que entró y no tiene entrada del otro lado.",
      hecha: "Nadie pagó de más ni de menos.",
      nivel: "aviso" },
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
      ${f.cifra && f.plano
        ? `<button type="button" class="btn plano chico" id="irAlPlano">Ver el plano</button>` : ""}
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
                busca: "", sel: null, asignando: null, alCambiar: null };

async function montarSalon(eventoId, opts) {
  Object.assign(SALON, {
    evento: eventoId, editar: !!(opts && opts.editar),
    compras: [], mesas: [], busca: "", sel: null, asignando: null,
    alCambiar: (opts && opts.alCambiar) || null,
  });
  const c = $("#zonaCompradores"), p = $("#zonaPlano");
  if (c) {
    c.innerHTML = `<p class="cargando">Cargando compradores…</p>`;
    c.onclick = clicEnCompradores;
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
  return m
    ? `<button type="button" class="btn plano chico" data-abrir="${esc(c.orden_id)}">Cambiar</button>
       <button type="button" class="btn plano chico" data-liberar="${esc(c.orden_id)}">Liberar</button>`
    : `<button type="button" class="btn plano chico" data-abrir="${esc(c.orden_id)}">Asignar mesa</button>`;
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
  const b = e.target.closest("button[data-abrir],button[data-liberar],button[data-confirmar],button[data-cerrar]");
  if (!b) return;
  const d = b.dataset;
  if (d.cerrar) { SALON.asignando = null; pintarFilasCompradores(); return; }
  if (d.abrir)  { SALON.asignando = d.abrir; pintarFilasCompradores(); return; }
  if (d.liberar) return liberarMesa(d.liberar);
  if (d.confirmar) {
    const sel = $("#selMesa");
    if (sel && sel.value) return asignarMesa(d.confirmar, sel.value);
  }
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

/* ── arranque: si ya había sesión, entrar directo ── */
(async () => {
  try {
    if (await cargarPerfil()) arrancarApp();
  } catch { /* sesión vieja o cuenta deshabilitada: queda la pantalla de entrar */ }
})();

window.ADMIN = { S, sb, mostrar, avisar, esc };   // para las tareas siguientes
})();
