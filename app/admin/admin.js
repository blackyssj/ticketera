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
               <button type="button" class="btn plano" id="btnCierre">Cierre y liquidación →</button>
               <button type="button" class="btn plano" id="btnBitacora">Bitácora →</button>` : ""}
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
    $("#btnBitacora").onclick = () => pantallaBitacora(id);
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

  const [ev, tipos, fases, vig] = await Promise.all([
    sb.from("eventos").select("id,nombre,estado,slug").eq("id", eventoId).single(),
    sb.from("tipo_entrada").select("*").eq("evento_id", eventoId).order("orden"),
    sb.from("evento_fase").select("*").eq("evento_id", eventoId).order("orden"),
    /* Cuál vende AHORA no se deduce acá: se le pregunta a la misma función
       que decide el precio de la venta real. Recalcularlo en JavaScript
       sería una segunda opinión, y el día que las dos discrepen la
       pantalla va a estar tranquilizando sobre algo que no está pasando. */
    sb.rpc("fase_vigente", { p_evento: eventoId }),
  ]);
  const T = tipos.data || [], F = fases.data || [];
  const vigente = vig.data || null;
  const proxima = proximaFase(F);
  /* fase_precio sin filtro traía las de TODO el organizador, y PostgREST
     corta en 1000 filas sin avisar: un precio fuera del corte desaparecía
     de la pantalla y, como el código creía que no existía, dejar la
     celda vacía tampoco lo borraba — quedaba invisible pero vendiendo.
     Acá ya tenemos los ids de fase de este evento, así que se filtra del
     lado del servidor con ellos. */
  const idsFase = F.map(f => f.id);
  /* El fee del organizador se trae acá para poder mostrar, al lado de cada
     precio, lo que el comprador va a pagar de verdad. Sin eso el organizador
     escribe 120, el comprador ve 130, y se entera cuando alguien le
     pregunta por qué le cobraron de más. */
  const cfgFee = (await sb.from("organizadores")
    .select("fee_pct,fee_fijo_transaccion,fee_piso")
    .eq("id", S.yo.organizador_id).single()).data
    || { fee_pct: 0, fee_fijo_transaccion: 0, fee_piso: 0 };
  /* Antes de pintar, no después: textoPaga() se llama dentro del template y
     con FEE_CFG todavía en cero el primer eco decía el precio pelado. */
  FEE_CFG = cfgFee;

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
          ${F.map(f => cabezaFase(f, vigente, proxima, F)).join("")}
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
                <span class="celda-paga" data-f="${f.id}" data-t="${t.id}"
                  >${p ? textoPaga(Number(p.precio)) : ""}</span>
              </td>`;
            }).join("")}
            <td class="col-accion"></td></tr>`).join("")}
        </tbody>
      </table>
    </div>
    <section id="zonaFase"></section>
    <p class="ayuda nota-fee">El precio es lo que te queda a vos. Encima va el
       ${Math.round(cfgFee.fee_pct * 100)}% de servicio de TICKETAZO, que paga el
       comprador${Number(cfgFee.fee_fijo_transaccion) > 0
         ? ` más ${bs(cfgFee.fee_fijo_transaccion)} por compra` : ""}${
         Number(cfgFee.fee_piso) > 0 ? `, con un mínimo de ${bs(cfgFee.fee_piso)}` : ""}.
       Debajo de cada precio dice cuánto va a pagar.</p>
    <div class="acciones">
      <button class="btn plano" id="btnTipo">+ Tipo de entrada</button>
      <button class="btn primario" id="btnGuardarGrilla">Guardar precios</button>
    </div>
    <p class="ayuda">Precio vacío = ese tipo no se vende en esa fase. Cupo vacío = sin tope.</p>
    <div id="zonaPublicar"></div>`;

  $("#btnVolver").onclick = () => abrirEvento(eventoId);
  $("#btnTipo").onclick = () => nuevoTipo(eventoId);
  /* El formulario se abre con la foto de fases que ya tiene la pantalla:
     el chequeo de solapamiento necesita a las OTRAS fases para poder
     nombrarlas, y volver a pedirlas al guardar dejaría la advertencia
     dependiendo de un request más que puede fallar justo ahí. */
  $("#btnFase").onclick = () => abrirFase(eventoId, null, F, vigente);
  document.querySelectorAll("#main .fase-editar").forEach(b => {
    b.onclick = () => abrirFase(eventoId, F.find(f => f.id === b.dataset.fase), F, vigente);
  });
  /* En vivo: el organizador prueba un precio, ve lo que paga el comprador y
     lo ajusta antes de guardar. Después de guardar ya es tarde: el número
     redondo que quería era el de la vitrina, no el suyo. */
  document.querySelectorAll("#main .celda-precio").forEach(inp => {
    inp.oninput = () => {
      const eco = document.querySelector(
        `#main .celda-paga[data-f="${inp.dataset.f}"][data-t="${inp.dataset.t}"]`);
      if (eco) eco.textContent = textoPaga(Number(inp.value));
    };
  });

  $("#btnGuardarGrilla").onclick = () => guardarGrilla(eventoId);
  zonaPublicar(eventoId, ev.data.estado, ev.data.slug);
}


/* La misma cuenta que crear_orden hace en la base (0025):
   max(round(subtotal × pct) + fijo, piso). Está duplicada acá a propósito
   y con el comentario para que se note: es una VISTA PREVIA, y la que vale
   es la de la base. Si algún día dejan de coincidir, la que está mal es
   esta — pero verla antes de guardar el precio evita el descubrimiento
   caro, que es el comprador preguntando por qué le cobraron de más. */
function feePreview(sub, cfg) {
  if (!(sub > 0)) return 0;
  return Math.max(Math.round(sub * Number(cfg.fee_pct || 0))
                  + Number(cfg.fee_fijo_transaccion || 0),
                  Number(cfg.fee_piso || 0));
}

let FEE_CFG = { fee_pct: 0, fee_fijo_transaccion: 0, fee_piso: 0 };
const textoPaga = sub => !(sub > 0) ? ""
  : `paga ${bs(sub + feePreview(sub, FEE_CFG))}`;

/* ══ el reloj de Bolivia ══════════════════════════════════════════
   Bolivia es UTC−4 todo el año: no hay horario de verano, así que el
   offset es una constante y no hace falta arrastrar una librería de husos
   para una sola zona.

   Lo que sí hace falta es no dejarlo librado al reloj de la máquina.
   `toLocaleString` sin `timeZone` usa el huso del navegador, y el panel se
   abre desde donde sea — el organizador de viaje, alguien del equipo en
   otro país. Sin fijar la zona, la misma fase se leería con otra hora en
   cada pantalla y "cierra el 5" sería el 4 o el 6 según dónde esté parado
   el que mira. Una fase que cierra el 5 cierra el 5 a las 23:59 DE
   BOLIVIA, y eso vale tanto para escribirla como para leerla. */
const RELOJ_BO = "America/La_Paz";

const fechaBO = iso => iso
  ? new Date(iso).toLocaleDateString("es-BO",
      { timeZone: RELOJ_BO, day: "numeric", month: "short" })
  : "";
const fechaHoraBO = iso => iso
  ? new Date(iso).toLocaleString("es-BO",
      { timeZone: RELOJ_BO, day: "numeric", month: "short",
        hour: "2-digit", minute: "2-digit", hour12: false })
  : "";
const horaBO = iso => iso
  ? new Date(iso).toLocaleTimeString("es-BO",
      { timeZone: RELOJ_BO, hour: "2-digit", minute: "2-digit", hour12: false })
  : "";

/* Las partes que van en un <input type="date"> y en uno type="time">, en
   hora de Bolivia. Salen de `toLocaleDateString("en-CA")` porque el
   formato corto de ese locale YA es AAAA-MM-DD, que es exactamente lo que
   el input espera: armarlo a mano con getFullYear/getMonth+1 es la receta
   del bug de un día, y encima daría la fecha del huso del navegador. */
function partesBO(iso) {
  if (!iso) return { fecha: "", hora: "" };
  const d = new Date(iso);
  return {
    fecha: d.toLocaleDateString("en-CA", { timeZone: RELOJ_BO }),
    hora: d.toLocaleTimeString("en-GB",
      { timeZone: RELOJ_BO, hour: "2-digit", minute: "2-digit", hour12: false }),
  };
}

/* El camino de vuelta: lo tipeado se fija a −04:00 explícitamente. Sin el
   offset, `new Date("2026-09-05T23:59")` se interpreta en el huso del
   navegador y la fase cerraría a otra hora — en Madrid, seis horas antes. */
const isoBO = (fecha, hora) => fecha ? `${fecha}T${hora || "00:00"}:00-04:00` : null;

const ventana = f => !f.desde && !f.hasta ? "siempre"
  : `${fechaHoraBO(f.desde) || "sin principio"} → ${fechaHoraBO(f.hasta) || "sin fin"}`;

/* ══ las fases ════════════════════════════════════════════════════
   Una fase es una ventana de tiempo con su propia lista de precios: la
   preventa cierra el jueves y la general arranca ahí. Hasta acá se creaba
   con dos prompt(), con `desde` clavado en el instante del clic, y después
   no se podía tocar nunca más — ni corregir el nombre, ni mover el cierre,
   ni borrar la que salió mal. O sea que el caso normal de una ticketera,
   dejar la general programada para cuando cierre la preventa, no se podía
   armar: toda fase nacía abierta.

   Y abajo de eso hay una trampa. `fase_vigente()` (0004, con el desempate
   de 0017) elige así:

     where activo and (desde is null or desde <= now())
                  and (hasta is null or hasta >  now())
     order by orden, id limit 1

   Con dos fases pisadas gana la de `orden` menor y la otra queda muerta
   sin que nada avise. El que arma "Preventa hasta el 5" y "General desde
   el 1" cree que subió el precio el día 1 y en realidad siguió vendiendo
   barato hasta el 5. Eso es plata, y es invisible.

   `fase_vigente()` no se toca: hay ventas hechas con esa lógica y
   cambiarla movería el precio de lo que se está vendiendo ahora mismo. Lo
   que cambia es la pantalla, en dos lugares:

   · En la grilla, cada fase dice qué está haciendo AHORA. La que está
     dentro de su ventana pero igual no vende sale marcada «tapada por
     «X»» — ese estado antes había que deducirlo de dos fechas y de un
     `order by` que no aparece escrito en ninguna pantalla.
   · Al guardar, si el rango se pisa con otro, sale el choque con nombres,
     fechas y cuál de las dos gana, y el botón cambia a «Guardar igual».

   Aviso y no rechazo, a propósito. Rechazar trabaría el camino normal
   para SALIR de un solapamiento: arreglar "Preventa hasta el 5" contra
   "General desde el 1" es editar una de las dos, y cuál se toque primero
   no puede decidir si el formulario acepta. Lo peligroso acá no es la
   acción, es que sea silenciosa — así que se le saca el silencio y se
   pide un segundo clic deliberado, que es justo lo que un prompt() nunca
   pidió. */

/* La próxima que abre: la de `desde` más chico entre las que todavía no
   arrancaron. Se marca aparte de las demás programadas porque es la única
   sobre la que hay algo que hacer hoy — es la que hay que mirar antes de
   irse a dormir. */
function proximaFase(F) {
  const ahora = Date.now();
  const futuras = F.filter(f => f.activo && f.desde && Date.parse(f.desde) > ahora)
                   .sort((a, b) => Date.parse(a.desde) - Date.parse(b.desde));
  return futuras.length ? futuras[0].id : null;
}

/* Cinco estados, y el que justifica la función es `tapada`: una fase
   dentro de su ventana que igual no vende, porque otra de `orden` menor
   también lo está. Las otras cuatro se pueden deducir de las fechas;
   ésta no. */
function estadoFase(f, F, vigenteId, proximaId) {
  const ahora = Date.now();
  const abrio = !f.desde || Date.parse(f.desde) <= ahora;
  const cerro = f.hasta && Date.parse(f.hasta) <= ahora;
  if (!f.activo) return { cls: "gris", txt: "inactiva" };
  if (f.id === vigenteId) return { cls: "verde", txt: "vende ahora" };
  if (cerro) return { cls: "gris", txt: `cerró ${fechaBO(f.hasta)}` };
  if (!abrio) return { cls: "dorada",
    txt: `${f.id === proximaId ? "próxima · " : ""}abre ${fechaHoraBO(f.desde)}` };
  /* Está en ventana y no es la vigente: la tapa otra. Se la nombra, porque
     "tapada" sin decir por quién obliga a mirar las cinco columnas y
     comparar fechas a ojo, que es exactamente lo que nadie hace. */
  const gana = F.find(x => x.id === vigenteId);
  return { cls: "roja", txt: gana ? `tapada por «${gana.nombre}»` : "no vende" };
}

function cabezaFase(f, vigenteId, proximaId, F) {
  const e = estadoFase(f, F || [], vigenteId, proximaId);
  return `<th class="th-fase">
    <span class="fase-titulo">${esc(f.nombre)}</span>
    <em>${esc(ventana(f))}</em>
    <span class="pastilla ${e.cls} fase-estado">${esc(e.txt)}</span>
    ${puedeEditar() ? `<button type="button" class="btn plano chico fase-editar"
      data-fase="${esc(f.id)}">Editar</button>` : ""}
  </th>`;
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

/* El formulario. Un prompt() para una fecha es donde alguien tipea
   "12/09/2026" y se guarda cualquier cosa: no valida, no muestra un
   calendario, no deja corregir, y el valor viaja como texto libre hasta
   la base. Un <input type="date"> lo valida el navegador y devuelve
   siempre AAAA-MM-DD, que es la única forma en que `isoBO` puede
   construir un instante que signifique lo que el organizador quiso. */
const FASE = { evento: null, fase: null, todas: [], vigente: null, insistiendo: false };

function abrirFase(eventoId, fase, todas, vigente) {
  Object.assign(FASE, { evento: eventoId, fase: fase || null,
                        todas: todas || [], vigente: vigente || null,
                        insistiendo: false });
  pintarFase();
  const z = $("#zonaFase");
  if (z) z.scrollIntoView({ behavior: "smooth", block: "nearest" });
}

function pintarFase() {
  const z = $("#zonaFase");
  if (!z) return;
  const f = FASE.fase;
  /* La fase nueva nace con la fecha y la hora de HOY en el campo `abre`,
     no vacía. Vacío significaría "desde siempre", que se pisa con todo lo
     que ya exista y dispararía el aviso de choque en el caso más común de
     todos. Prefijado a hoy hace lo mismo que hacía el prompt() —nace
     abierta— con la diferencia que ahora se ve y se puede correr a mañana,
     que es para lo que existe esta pantalla. */
  const d = partesBO(f ? f.desde : new Date().toISOString());
  const h = partesBO(f && f.hasta);
  z.innerHTML = `
    <form class="tarjeta form-fase" id="formFase">
      <h3>${f ? `Fase «${esc(f.nombre)}»` : "Fase nueva"}</h3>
      <label class="ancha"><span>Nombre</span>
        <input id="faNombre" value="${esc(f ? f.nombre : "")}" maxlength="60" required
               placeholder="Preventa, General, Última tanda…"></label>
      <label><span>Abre</span>
        <span class="par-fh">
          <input id="faDesdeF" type="date" value="${esc(d.fecha)}">
          <input id="faDesdeH" type="time" value="${esc(d.hora)}"></span>
        <em class="ayuda">Vacío = abierta desde siempre. Poné una fecha futura
          para dejarla programada.</em></label>
      <label><span>Cierra</span>
        <span class="par-fh">
          <input id="faHastaF" type="date" value="${esc(h.fecha)}">
          <input id="faHastaH" type="time" value="${esc(h.hora)}"></span>
        <em class="ayuda">Vacío = sin fin. Si ponés solo la fecha, cierra ese
          día a las 23:59 de Bolivia.</em></label>
      <p class="ayuda ancha">Las horas son de Bolivia (UTC−4), como en toda la
        ticketera.</p>
      <div id="faChoque"></div>
      <div class="acciones">
        <button class="btn primario" id="faGuardar">${
          FASE.insistiendo ? "Guardar igual" : "Guardar"}</button>
        <button type="button" class="btn plano" id="faCancelar">Cancelar</button>
        ${f ? `<button type="button" class="btn plano peligrosa" id="faBorrar">Borrar la fase</button>` : ""}
      </div>
      <p class="error" id="faError"></p>
    </form>`;

  $("#formFase").onsubmit = e => { e.preventDefault(); guardarFase(); };
  $("#faCancelar").onclick = () => { z.innerHTML = ""; };
  const b = $("#faBorrar");
  if (b) b.onclick = () => borrarFase();
  /* Tocar cualquier campo apaga el "Guardar igual": el segundo clic tiene
     que confirmar EL choque que se mostró, no uno anterior sobre fechas
     que ya cambiaron. */
  ["faNombre", "faDesdeF", "faDesdeH", "faHastaF", "faHastaH"].forEach(id => {
    const i = $("#" + id);
    if (i) i.oninput = () => {
      if (!FASE.insistiendo) return;
      FASE.insistiendo = false;
      $("#faGuardar").textContent = "Guardar";
      $("#faChoque").innerHTML = "";
    };
  });
}

/* Dos fases se pisan si sus ventanas se cruzan aunque sea un minuto. Un
   `desde` vacío es "desde siempre" y un `hasta` vacío es "para siempre":
   por eso el null cuenta como infinito y no como cero, que es el error
   clásico de esta comparación y el que haría pasar por limpio justo el
   caso peor — la fase sin fecha de fin, que se pisa con todo lo que venga
   después. */
function sePisan(a, b) {
  const d1 = a.desde ? Date.parse(a.desde) : -Infinity;
  const h1 = a.hasta ? Date.parse(a.hasta) : Infinity;
  const d2 = b.desde ? Date.parse(b.desde) : -Infinity;
  const h2 = b.hasta ? Date.parse(b.hasta) : Infinity;
  return d1 < h2 && d2 < h1;
}

/* Cuál de las dos gana en el pedazo que comparten: la misma regla que
   `fase_vigente()`, `order by orden, id`. Escrita acá con el comentario
   arriba porque es una COPIA, y la que vale es la de la base: si algún
   día dejan de coincidir, la que está mal es ésta. */
const ganaFase = (a, b) =>
  (a.orden !== b.orden ? a.orden < b.orden : String(a.id) < String(b.id)) ? a : b;

async function guardarFase() {
  const nombre = $("#faNombre").value.trim();
  $("#faError").textContent = "";
  if (!nombre) { $("#faError").textContent = "Ponele un nombre."; return; }

  const desde = isoBO($("#faDesdeF").value, $("#faDesdeH").value);
  /* El default del cierre son las 23:59 y no las 00:00: "la preventa vale
     hasta el 5" quiere decir todo el día 5. Con 00:00 la preventa habría
     cerrado la noche del 4 y el organizador se enteraría por el primero
     que llame a preguntar por qué le cobraron de más. */
  const hasta = isoBO($("#faHastaF").value, $("#faHastaH").value || "23:59");
  if (desde && hasta && Date.parse(desde) >= Date.parse(hasta)) {
    $("#faError").textContent = "La fase cerraría antes de abrir. Revisá las dos fechas.";
    return;
  }

  const f = FASE.fase;
  /* Al crear todavía no hay `orden` —se calcula recién al insertar— así
     que para el chequeo se la trata como la última, que es donde va a
     quedar: es la que PIERDE contra cualquier fase existente con la que se
     pise, y eso es exactamente lo que hay que decirle al organizador. */
  const propuesta = { id: f ? f.id : null, nombre,
                      desde, hasta, activo: f ? f.activo : true,
                      orden: f ? f.orden : Infinity };
  const choques = FASE.todas
    .filter(o => o.id !== propuesta.id && o.activo && sePisan(propuesta, o));

  if (choques.length && !FASE.insistiendo) {
    FASE.insistiendo = true;
    $("#faGuardar").textContent = "Guardar igual";
    $("#faChoque").innerHTML = avisoChoque(propuesta, choques);
    return;
  }

  const fila = { nombre, desde, hasta };
  if (f) {
    /* `.select()` obligatorio: si la policy filtrara la fila, el update
       vuelve sin error y con cero filas y la pantalla diría "guardado"
       sobre algo que no se guardó. Ya pasó dos veces en este proyecto. */
    const { data, error } = await sb.from("evento_fase")
      .update(fila).eq("id", f.id).select("id");
    if (error) { $("#faError").textContent = error.message; return; }
    if (!data || !data.length) {
      $("#faError").textContent = "No se guardó nada: tu cuenta no puede editar esta fase.";
      return;
    }
    avisar("Fase guardada.");
  } else {
    const { error } = await insertarFase(FASE.evento, fila);
    if (error) { $("#faError").textContent = error.message; return; }
    avisar("Fase creada.");
  }
  pantallaEntradas(FASE.evento);
}

/* `orden` fijo en 0 empataba, y `fase_vigente()` desempataba por `id`: la
   fase que vendía dependía de un uuid al azar. 0017 le puso un unique
   (evento_id, orden) para que no vuelva a pasar, pero ese unique convierte
   la carrera en un 23505: dos personas creando una fase a la vez leen el
   mismo máximo y la segunda rebota. Se reintenta releyendo el máximo, que
   es lo que un `select max()+1` sin transacción no puede prometer solo. */
async function insertarFase(eventoId, fila) {
  let ultimo = null;
  for (let intento = 0; intento < 3; intento++) {
    const { data: ult } = await sb.from("evento_fase").select("orden")
      .eq("evento_id", eventoId).order("orden", { ascending: false }).limit(1);
    const orden = (ult && ult[0] ? ult[0].orden : -1) + 1;
    const { error } = await sb.from("evento_fase").insert({
      organizador_id: S.yo.organizador_id, evento_id: eventoId, ...fila, orden });
    if (!error) return { error: null };
    if (error.code !== "23505") return { error };
    ultimo = error;
  }
  return { error: { ...ultimo,
    message: "Alguien más está creando fases al mismo tiempo. Probá de nuevo." } };
}

/* El choque, dicho entero: quién con quién, en qué pedazo de tiempo, y
   cuál de las dos va a vender ahí. Sin la última línea el aviso sería
   "ojo, se pisan" — cierto e inútil, porque lo que el organizador tiene
   que decidir es si le sirve que la otra sea la que cobre. */
function avisoChoque(propuesta, choques) {
  return `<div class="choque">
    <h4>Se pisa con ${choques.length === 1 ? "otra fase" : `otras ${choques.length} fases`}</h4>
    <ul>${choques.map(o => {
      const gana = ganaFase(propuesta, o);
      const d = Math.max(propuesta.desde ? Date.parse(propuesta.desde) : -Infinity,
                         o.desde ? Date.parse(o.desde) : -Infinity);
      const h = Math.min(propuesta.hasta ? Date.parse(propuesta.hasta) : Infinity,
                         o.hasta ? Date.parse(o.hasta) : Infinity);
      const tramo = `${d === -Infinity ? "desde siempre" : `del ${fechaHoraBO(new Date(d).toISOString())}`}
                     ${h === Infinity ? "en adelante" : `al ${fechaHoraBO(new Date(h).toISOString())}`}`;
      const pierde = gana === propuesta ? o : propuesta;
      return `<li><b>«${esc(o.nombre)}»</b> <i>(${esc(ventana(o))})</i><br>
        Se cruzan ${esc(tramo)}. En ese tramo vende
        <b>«${esc(gana.nombre)}»</b> y «${esc(pierde.nombre)}» no vende nada:
        el precio que cobra la página es el de la que gana.</li>`;
    }).join("")}</ul>
    <p>Sale por el orden en que se crearon las fases, no por la fecha. Si querés
      que mande la otra, cerrá ésta antes de que la otra abra: poneles el mismo
      día y la de arriba que termine donde la de abajo empieza.</p>
  </div>`;
}

/* Borrar solo si no vendió nada, y la cuenta la hace la base
   (`borrar_fase`, 0043): el `if` de acá es para no hacer un viaje en vano
   y para poder avisar del caso que la base no puede ver — que la fase que
   se está por borrar es la única abierta, o sea que después de esto la
   página pública deja de vender. */
async function borrarFase() {
  const f = FASE.fase;
  if (!f) return;
  const sola = f.id === FASE.vigente;
  if (!confirm(`¿Borrar la fase «${f.nombre}»?\n\n` +
      `Se van también los precios que cargaste en su columna.` +
      (sola ? `\n\nOJO: es la fase que está vendiendo AHORA. Sin ninguna fase abierta,
la página pública deja de vender hasta que abras otra.` : "") +
      `\n\nSi ya vendió algo, no se va a borrar.`)) return;

  const { data, error } = await sb.rpc("borrar_fase", { p_fase: f.id });
  if (error) { $("#faError").textContent = sinCodigo(error.message); return; }
  if (!data || !data.ok) {
    $("#faError").textContent = "No se borró nada. Recargá y fijate cómo quedó.";
    return;
  }
  avisar(data.motivo);
  pantallaEntradas(FASE.evento);
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


/* ══ bajar un CSV ═════════════════════════════════════════════════
   Las reglas del formato viven en csv.js. Acá está lo otro que un export
   necesita para no mentir: traer TODAS las filas.

   Las funciones de 0040 paginan y devuelven `total` contado sin el tope.
   Esto pide de a mil hasta juntar ese total. No es paranoia de escala: es
   que PostgREST corta en 1000 sin decirlo en ningún lado de la respuesta,
   y un archivo con 1000 de 1400 filas nadie lo nota — el que cuadra la
   caja cuenta lo que ve y le da bien.

   Si algo sale mal, sale mal FUERTE: tira y el que llama avisa. Un
   archivo a medias no se baja, porque un archivo a medias es el único
   resultado peor que ninguno.

   El deduplicado por id no sobra. El offset se corre sobre un orden
   estable, pero la bitácora se escribe mientras alguien exporta —se anula
   una compra a las tres de la mañana— y una fila nueva arriba empuja a
   todas las demás una posición: sin dedupe, la fila del borde de página
   sale dos veces. */
async function traerTodo(fn, args, tope = 1000) {
  const filas = [], vistos = new Set();
  let off = 0, total = 0, vueltas = 0;
  for (;;) {
    const { data, error } = await sb.rpc(fn, { ...args, p_desde: off, p_tope: tope });
    if (error) throw new Error(sinCodigo(error.message));
    const lote = (data && data.filas) || [];
    total = Number((data && data.total) || 0);
    lote.forEach(f => { if (!vistos.has(f.id)) { vistos.add(f.id); filas.push(f); } });
    off += lote.length;
    if (!lote.length || off >= total) break;
    if (++vueltas > 60) throw new Error(
      "Son demasiadas filas para bajarlas de una sola vez. Avisá al equipo antes de usar este archivo.");
  }
  return { filas, total };
}

/* El link que se le manda al que dice "compré y no me llegó nada". El
   uuid de la orden ES la credencial de esa página (ver app/orden/orden.js):
   impredecible y sin login, porque en la puerta, con la fila atrás, nadie
   se acuerda de una clave.
   Se arma con `location` y no con una constante: el panel y /orden/ se
   sirven del mismo origen, así que en localhost sale localhost y en
   producción sale producción, sin una URL más que mantener. */
const linkOrden = id => `${location.origin}/orden/?id=${encodeURIComponent(id)}`;

/* Bajar puede tardar —son varias vueltas a la base— y un botón que no
   cambia invita a apretarlo de nuevo, que son dos archivos iguales en
   Descargas. */
async function conBoton(btn, txt, fn) {
  if (!btn || btn.disabled) return;
  const antes = btn.textContent;
  btn.disabled = true;
  btn.textContent = txt;
  try { await fn(); }
  catch (err) { avisar(err.message || String(err)); }
  finally { btn.disabled = false; btn.textContent = antes; }
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
    sb.from("eventos").select("id,nombre,slug,fecha,estado").eq("id", eventoId).single(),
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
          <span class="bajadas">
            <button type="button" class="btn plano chico" id="btnCsvLiq">Bajar la liquidación</button>
            <button type="button" class="btn plano chico" id="btnReabrir">Reabrir</button>
          </span>
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
  const bl = $("#btnCsvLiq"); if (bl) bl.onclick = () => conBoton(bl, "Armando…", bajarLiquidacion);
  document.querySelectorAll("#main [data-pagar]").forEach(b =>
    b.onclick = () => pedirPago(b.dataset.pagar));
}

/* ── el CSV de la liquidación ──
   Dos bloques en un archivo, separados por una línea en blanco: arriba la
   foto con la que se cerró, abajo una línea por relacionador. Es raro
   para un CSV y es a propósito — lo que se le manda al contador no es una
   tabla, es un comprobante: primero cuánto se vendió y cuánto queda, y
   después a quién hay que pagarle. Partirlo en dos archivos garantiza que
   uno de los dos se pierda por el camino.

   Sale la FOTO, no los datos de hoy. Es con esos números con los que se
   pagó; si después se anuló algo, esa diferencia va abajo dicha con todas
   las letras en vez de recalcular en silencio un archivo que ya se mandó. */
function bajarLiquidacion() {
  const d = LIQ.datos, foto = d.foto, hoy = d.hoy || {};
  if (!foto) { avisar("Este evento todavía no está cerrado, así que no hay liquidación que bajar."); return; }
  const filas = [
    ["Evento", LIQ.ev.nombre],
    ["Fecha del evento", CSV.f(LIQ.ev.fecha)],
    ["Versión de la liquidación", CSV.ent(foto.version)],
    ["Cerrada el", CSV.fh(foto.cerrada_at)],
    ["La cerró", foto.cerrada_por || ""],
    ["Motivo del cierre", foto.motivo || ""],
    [],
    ["Concepto", "Monto (Bs)"],
    ["Se vendió", CSV.bs(foto.bruto)],
    ["Servicio de TICKETAZO", CSV.bs(foto.fee)],
    ["Pasó por la pasarela", CSV.bs(foto.cobrado)],
    ["Comisiones de relacionadores", CSV.bs(-Number(foto.comisiones || 0))],
    ["Para el organizador", CSV.bs(foto.neto)],
    ["Manillas", CSV.ent(foto.entradas)],
    ["Compras", CSV.ent(foto.ordenes)],
  ];
  if (foto.difiere) {
    const dif = foto.diferencia || {};
    filas.push([],
      ["Los datos de hoy ya no coinciden con esta liquidación. No se recalcula: es con la que se pagó."],
      ["Diferencia en lo vendido (Bs)", CSV.bs(dif.bruto)],
      ["Diferencia en comisiones (Bs)", CSV.bs(dif.comisiones)],
      ["Diferencia en manillas", CSV.ent(dif.entradas)],
      ["Hoy el evento suma (Bs)", CSV.bs(hoy.bruto)]);
  }
  const lineas = foto.lineas || [];
  filas.push([], ["Relacionador", "Código", "Manillas", "Recaudado (Bs)",
                  "Comisión unitaria (Bs)", "Comisión (Bs)", "Estado",
                  "Pagado (Bs)", "Pendiente (Bs)", "Pagada el", "La marcó", "Nota del pago"]);
  lineas.forEach(l => filas.push([
    l.nombre || "", l.slug || "", CSV.ent(l.entradas), CSV.bs(l.recaudado),
    CSV.bs(l.comision_unitaria), CSV.bs(l.comision),
    l.pagada ? "Pagada" : "Pendiente",
    CSV.bs(l.pagada ? l.pagado_monto : 0),
    CSV.bs(l.pagada ? 0 : l.comision),
    CSV.fh(l.pagada_at), l.pagada_por || "", l.pagado_nota || "",
  ]));
  const debe = lineas.filter(l => !l.pagada).reduce((a, l) => a + Number(l.comision || 0), 0);
  const pago = lineas.filter(l => l.pagada).reduce((a, l) => a + Number(l.pagado_monto || 0), 0);
  filas.push(["Total", "", CSV.ent(lineas.reduce((a, l) => a + Number(l.entradas || 0), 0)), "", "",
              CSV.bs(foto.comisiones), "", CSV.bs(pago), CSV.bs(debe), "", "", ""]);

  CSV.bajar(CSV.nombre("liquidacion", LIQ.ev), filas);
  avisar(`Bajó la liquidación con ${lineas.length} ` +
         `${lineas.length === 1 ? "relacionador" : "relacionadores"}.`);
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
    evs.push({ id: e.id, nombre: e.nombre, fecha: e.fecha, slug: e.slug });
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
    const cual = id => evs.find(e => e.id === id) || evs[0];
    if (sel) sel.onchange = () => montarSalon(sel.value,
      { editar: puedeEditar(), ev: cual(sel.value) });
    montarSalon(evs[0].id, { editar: puedeEditar(), ev: evs[0] });
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
  const ev = await sb.from("eventos").select("id,nombre,slug,fecha").eq("id", eventoId).single();
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
    ${puedeEditar() ? `<section id="zonaPorteros"></section>` : ""}
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
    montarSalon(eventoId, { editar: puedeEditar(), ev: ev.data,
                            alCambiar: () => Promise.all([refrescarResumen(eventoId),
                                                          refrescarRegistro(eventoId)]) }),
    refrescarPorteros(eventoId),
    refrescarRegistro(eventoId),
  ]);
}

/* ══ la puerta, portero por portero ═══════════════════════════════
   Van a ser cuatro personas escaneando y hasta acá el panel no tenía
   dónde ver quién hizo qué: la bitácora muestra el detalle —mil filas de
   una noche— y sacar de ahí el resumen es contar a ojo, o sea que en la
   práctica ese número no existía.

   La columna que manda es «Deshizo», y por eso está al final y en color:
   validar consume una manilla que estaba vendida y rechazar no toca
   nada, pero deshacer devuelve una manilla ya consumida al estado
   `valida` — o sea la vuelve a hacer utilizable. Es el único movimiento
   de la puerta con el que alguien de adentro puede hacer entrar gente de
   más. Tres en una noche son dedos gordos; cuarenta son otra cosa, y esa
   diferencia tiene que estar al lado de las demás y no escondida en el
   detalle. El «de otro portero» que va debajo afina la misma pregunta:
   corregirse a uno mismo no es lo mismo que deshacer lo que marcó el
   compañero. */
async function refrescarPorteros(eventoId) {
  const z = $("#zonaPorteros");
  if (!z) return;
  const { data, error } = await sb.rpc("resumen_puerta", { p_evento: eventoId });
  if (error) { z.innerHTML = `<p class="error">${esc(sinCodigo(error.message))}</p>`; return; }
  /* {} en vez de error: resumen_puerta() contesta lo mismo para "no es de
     tu organizador" que para "no existe", igual que resumen_evento(). Sin
     este corte la pantalla diría "todavía nadie escaneó", que es afirmar
     algo que no sabe. */
  if (!data || !data.total) {
    z.innerHTML = `<p class="vacio">No hay datos de puerta de este evento.</p>`;
    return;
  }
  const filas = data.porteros || [];
  const t = data.total;

  z.innerHTML = `
    <div class="cab-bloque sep">
      <h3 class="titulo-bloque">Puerta</h3>
      <span class="conteo">${filas.length
        ? `${num(t.ingresos)} ${Number(t.ingresos) === 1 ? "manilla" : "manillas"} por ${
            num(filas.length)} ${filas.length === 1 ? "persona" : "personas"}`
        : ""}</span>
    </div>
    ${filas.length ? `
      <p class="ayuda bajo-titulo">Deshacer devuelve una manilla ya usada a válida:
        es el único movimiento con el que se puede hacer entrar a alguien de más.
        Unos pocos en la noche son escaneos corregidos; muchos son otra cosa.</p>
      <div class="grilla-envoltorio">
        <table class="tabla tabla-porteros">
          <thead><tr>
            <th>Portero</th><th>Turno</th>
            <th class="n">Dejó pasar</th><th class="n">Rechazó</th><th class="n">Deshizo</th>
          </tr></thead>
          <tbody>${filas.map(filaPortero).join("")}</tbody>
          ${filas.length > 1 ? `<tfoot><tr>
            <td class="dato">Los ${num(filas.length)}</td>
            <td class="dato">${esc(turnoTxt(t.primero_at, t.ultimo_at))}</td>
            <td class="n">${num(t.ingresos)}</td>
            <td class="n">${num(t.rechazadas)}</td>
            <td class="n${Number(t.deshechas) ? " deshechos" : ""}">${num(t.deshechas)}</td>
          </tr></tfoot>` : ""}
        </table>
      </div>`
      : `<p class="vacio">Todavía nadie escaneó una manilla en este evento. Cuando
           empiece la puerta, acá va lo que hizo cada uno.</p>`}`;
}

function filaPortero(f) {
  const des = Number(f.deshechas) || 0;
  const aj  = Number(f.deshechas_ajenas) || 0;
  const rei = Number(f.reingresos) || 0;
  return `<tr>
    <td><span class="prod-nombre">${esc(f.portero)}</span>
      <i>${esc(f.rol || "")}${f.activo === false ? " · desactivado" : ""}</i></td>
    <td class="dato">${esc(turnoTxt(f.primero_at, f.ultimo_at))}</td>
    <td class="n">${num(f.ingresos)}${rei
      ? `<em>${num(rei)} ${rei === 1 ? "reingreso" : "reingresos"}</em>` : ""}</td>
    <td class="n">${num(f.rechazadas)}</td>
    <td class="n${des ? " deshechos" : ""}">${num(des)}${aj
      ? `<em>${num(aj)} de otro portero</em>` : ""}</td>
  </tr>`;
}

/* El turno REAL, que casi nunca es el anunciado. Si empezó y terminó el
   mismo día se dice la fecha una sola vez: repetirla en las dos puntas
   ocupa el ancho que necesita la columna de al lado. */
function turnoTxt(desde, hasta) {
  if (!desde) return "—";
  const d1 = partesBO(desde).fecha, d2 = partesBO(hasta).fecha;
  return d1 === d2
    ? `${fechaBO(desde)} · ${horaBO(desde)} → ${horaBO(hasta)}`
    : `${fechaHoraBO(desde)} → ${fechaHoraBO(hasta)}`;
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
    /* El evento entero y no solo su id: el nombre del archivo que se baja
       lleva el slug y la fecha, y sin eso todos los CSV de la carpeta de
       Descargas se llaman igual. */
    ev: (opts && opts.ev) || { id: eventoId },
    compras: [], mesas: [], busca: "", sel: null, asignando: null,
    anulando: null, abierta: null, manillas: {}, anulandoEntrada: null,
    link: null,
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
      ${SALON.compras.length ? `<span class="bajadas">
        <button type="button" class="btn plano chico" id="btnCsvCompradores">Bajar compradores</button>
        ${SALON.editar ? `<button type="button" class="btn plano chico" id="btnCsvEntradas"
          >Bajar entradas</button>` : ""}</span>` : ""}
    </div>
    ${error ? `<p class="error">${esc(error.message)}</p>` : ""}
    ${SALON.compras.length ? `
      <div class="grilla-envoltorio">
        <table class="tabla tabla-compras">
          <thead><tr>
            <th>Comprador</th><th>Contacto</th><th>Compró</th>
            <th class="n">Manillas</th><th class="n">Pagó</th>
            <th>Relacionador</th><th>Mesa</th>
            <th class="col-accion"></th>
          </tr></thead>
          <tbody id="filasCompradores"></tbody>
        </table>
      </div>`
      : error ? "" : `<p class="vacio">Todavía no hay compras pagadas en este evento.</p>`}`;

  const bc = $("#btnCsvCompradores");
  if (bc) bc.onclick = () => conBoton(bc, "Armando…", bajarCompradores);
  const be = $("#btnCsvEntradas");
  if (be) be.onclick = () => conBoton(be, "Buscando…", bajarEntradas);

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
    : `<tr><td class="sin-nada" colspan="8">
         Nadie con ese nombre ni ese teléfono en este evento.</td></tr>`;
}

/* ── los dos CSV de esta lista ──
   El de compradores baja SIEMPRE la lista entera, no lo que quedó
   filtrado en pantalla. Bajar lo filtrado suena cómodo hasta que alguien
   deja un nombre escrito en el buscador, exporta y manda un archivo con
   tres filas: nadie lo nota, porque un CSV con tres filas se ve igual de
   bien que uno con trescientas.

   Y no vuelve a la base: `compradores_evento` ya trajo todo en un jsonb
   —sin paginado que pueda comerse una fila— y ya decidió qué ve quién.
   Un relacionador que aprieta este botón baja SUS compras, porque eso es
   lo que la función le dio; el recorte no lo hace este archivo. */
function bajarCompradores() {
  const cab = ["Comprador", "Teléfono", "Correo", "Compró", "Unidades", "Manillas",
               "Manillas usadas", "Manillas anuladas", "Pagó (Bs)", "Servicio (Bs)",
               "Total (Bs)", "Relacionador", "Canal", "Mesa", "Fecha de la compra",
               "Link de recuperación"];
  const filas = SALON.compras.map(c => {
    const m = mesaDeCompra(c);
    return [
      c.comprador || "", c.telefono || "", c.email || "", c.detalle || "",
      CSV.ent(c.unidades), CSV.ent(c.manillas),
      CSV.ent(c.manillas_usadas), CSV.ent(c.manillas_anuladas),
      CSV.bs(c.pagado), CSV.bs(c.fee), CSV.bs(c.total),
      c.rrpp_nombre || "", c.canal === "rrpp" ? "Relacionador" : "Público",
      m ? `${m.etiqueta} (${PLANTA_TXT[m.planta] || m.planta})` : "",
      CSV.fh(c.fecha), linkOrden(c.orden_id),
    ];
  });
  CSV.bajar(CSV.nombre("compradores", SALON.ev), [cab, ...filas]);
  avisar(`Bajaron ${filas.length} ${filas.length === 1 ? "compra" : "compras"}.`);
}

/* La lista que se imprime por si la puerta se queda sin señal. Va con las
   anuladas adentro y marcadas: una lista de papel que las esconde deja
   entrar justo a la que se anuló. */
async function bajarEntradas() {
  const { filas, total } = await traerTodo("entradas_evento", { p_evento: SALON.evento });
  if (!total) { avisar("Este evento todavía no tiene ninguna manilla emitida."); return; }
  const cab = ["Código", "A nombre de", "Tipo", "Canal", "Estado", "Entró", "Portero",
               "Mesa", "Comprador", "Teléfono", "Relacionador", "Precio (Bs)"];
  CSV.bajar(CSV.nombre("entradas", SALON.ev), [cab, ...filas.map(e => [
    e.code, e.cliente || "", e.tipo || "", CANAL_UNO[e.canal] || e.canal,
    (ESTADO_MANILLA[e.estado] || {}).txt || e.estado,
    CSV.fh(e.used_at), e.portero || "", e.mesa || "",
    e.comprador || "", e.telefono || "", e.rrpp || "", CSV.bs(e.precio),
  ])]);
  avisar(`Bajaron ${filas.length} de ${total} ${total === 1 ? "manilla" : "manillas"}.`);
}

/* En singular: acá una fila es UNA manilla. El CANAL_TXT de los
   desgloses está en plural porque allá una fila es un montón. */
const CANAL_UNO = { publico: "Público", rrpp: "Relacionador",
                    puerta: "Puerta", cortesia: "Cortesía" };

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
    <td class="col-accion">${accionesCompra(c, m)}</td>
  </tr>`;
}

/* La columna de acciones existe ahora también sin `editar`. El único
   botón que sobrevive ahí es el del link, y no es una concesión: el
   relacionador es el primero que recibe el "compré y no me llegó nada",
   y hasta hoy lo único que podía hacer era reenviarlo a la oficina. */
function accionesCompra(c, m) {
  const link = `<button type="button" class="btn plano chico" data-link="${esc(c.orden_id)}"
      >${SALON.link === c.orden_id ? "Ocultar" : "Link"}</button>`;
  if (!SALON.editar) return link;
  if (SALON.asignando === c.orden_id) return selectorDeMesas(c, m);
  const mesa = m
    ? `<button type="button" class="btn plano chico" data-abrir="${esc(c.orden_id)}">Cambiar</button>
       <button type="button" class="btn plano chico" data-liberar="${esc(c.orden_id)}">Liberar</button>`
    : `<button type="button" class="btn plano chico" data-abrir="${esc(c.orden_id)}">Asignar mesa</button>`;
  /* "Link" antes que "Manillas" y "Manillas" antes que "Anular": el link
     es lo que se pide todos los días —"compré y no me llegó nada"—, la
     manilla suelta es lo que pasa a veces, y anular la compra entera es
     lo que no se deshace. El orden de los botones es el orden de la
     frecuencia, no el del código. */
  return `${mesa}${link}
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
  const abre = SALON.anulando === c.orden_id || SALON.abierta === c.orden_id
            || SALON.link === c.orden_id;
  if (!abre) return "";
  return `<tr class="fila-detalle"><td colspan="8">
    ${SALON.link === c.orden_id ? bloqueLink(c) : ""}
    ${SALON.anulando === c.orden_id ? formAnularCompra(c) : ""}
    ${SALON.abierta === c.orden_id ? listaManillas(c) : ""}
  </td></tr>`;
}

/* ── el link de una compra ──
   Lo que se le da al que escribe "compré y no me llegó nada". El botón de
   copiar es el que anda HOY y por eso va primero y es el primario: el
   correo todavía no está configurado en este proyecto (no existe
   RESEND_API_KEY) y la Edge Function `enviar-entradas`, cuando falta,
   contesta `enviado:false` con el link adentro en vez de fallar.

   De ahí sale la regla de esta pantalla: acá NO se escribe "se envió" en
   ninguna parte hasta que la función conteste `enviado:true`. Prometer un
   correo que no salió es peor que no ofrecerlo — el comprador se queda
   esperando y el que atiende cree que ya está resuelto.

   El día que alguien cargue la clave de Resend, este mismo botón manda el
   correo de verdad y el aviso cambia solo. No hay nada que tocar acá. */
function bloqueLink(c) {
  const id = c.orden_id;
  return `<div class="link-compra">
    <p class="ayuda">El link no pide clave: el uuid de la compra es la
      credencial. Mandáselo por WhatsApp al que dice que no le llegó nada.</p>
    <p class="link-publico">
      <code id="lkOrden">${esc(linkOrden(id))}</code>
      <button type="button" class="btn primario chico" data-copiar="lkOrden"
              data-que="El link">Copiar</button>
    </p>
    ${c.email
      ? `<div class="acciones">
           <button type="button" class="btn plano chico" data-mail="${esc(id)}"
             >Mandarle el correo a ${esc(c.email)}</button>
         </div>
         ${S.correoOff ? `<p class="ayuda">La última vez que se intentó, el envío de
            correos no estaba configurado en este servidor. El botón sigue ahí por si
            ya lo configuraron; mientras tanto, el link de arriba es lo que funciona.</p>` : ""}`
      : `<p class="ayuda">Esta compra no dejó correo, así que no hay a dónde mandarlo:
           queda el link.</p>`}
    <p class="mail-resultado" id="mailResultado"></p>
  </div>`;
}

/* La única fuente de verdad de lo que pasó es la respuesta de la función:
   `enviado` es booleano y no se interpreta. Si dice false, se dice que no
   se mandó y se repite el link, que es lo que sí sirve. */
async function mandarCorreo(ordenId) {
  pintarMail("", null);
  const { data, error } = await sb.functions.invoke("enviar-entradas", { body: { orden: ordenId } });
  if (error || !data || data.ok === false) {
    const m = (data && data.motivo) || (error && error.message) || "No se pudo llegar al servidor.";
    pintarMail(`No se mandó ningún correo. ${sinCodigo(m)} Copiá el link de arriba y mandáselo vos.`, false);
    return;
  }
  if (data.enviado) {
    S.correoOff = false;
    pintarMail(`Salió el correo. Si igual no le llega, que mire el spam — o mandale el link de arriba.`, true);
    return;
  }
  /* Que el correo no esté configurado no es un problema de esta compra:
     es el estado del servidor. Se recuerda para el resto de la sesión y
     las próximas compras lo avisan ANTES de que alguien toque el botón. */
  if (/no está configurado/i.test(String(data.motivo || ""))) S.correoOff = true;
  pintarMail(`No se mandó ningún correo. ${sinCodigo(data.motivo || "El servidor no lo mandó.")} ` +
             `Copiá el link de arriba y mandáselo vos.`, false);
}

function pintarMail(txt, ok) {
  const z = $("#mailResultado");
  if (!z) { if (txt) avisar(txt); return; }
  z.textContent = txt;
  if (ok === null) delete z.dataset.ok; else z.dataset.ok = ok ? "1" : "0";
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
                             "button[data-anular-manilla],button[data-link]," +
                             "button[data-copiar],button[data-mail]");
  if (!b) return;
  const d = b.dataset;
  /* Copiar y mandar no repintan la lista: si repintaran, el resultado del
     correo —lo único que dice qué pasó de verdad— desaparecería en el
     mismo clic que lo produjo. */
  if (d.copiar) return copiarNodo(document.getElementById(d.copiar), d.que);
  if (d.mail) return conBoton(b, "Mandando…", () => mandarCorreo(d.mail, b));
  if (d.link) {
    SALON.link = SALON.link === d.link ? null : d.link;
    pintarFilasCompradores(); return;
  }
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

/* ══ la bitácora ══════════════════════════════════════════════════
   Todo lo que se decidió y todo lo que pasó en la puerta ya estaba
   guardado con autor, hora y motivo, en dos tablas append-only que nadie
   puede editar ni borrar. Lo que faltaba era poder leerlo sin un PAT.

   Es la pantalla que se abre cuando alguien pregunta "¿quién anuló esta
   compra?" o "¿por qué esta manilla figura sin usar si yo la escaneé?".
   Esas dos preguntas no se contestan con una tabla: se contestan con una
   historia. Por eso acá no hay grilla — hay una línea por hecho, agrupada
   por día, en el orden en que pasaron las cosas, y el MOTIVO en grande.
   El motivo es el campo que la base hace obligatorio para anular; que
   quede escondido en la cuarta columna de una tabla es tirarlo.

   ── las dos fuentes ──
   `bitacora_admin` trae las decisiones del escritorio: anulaciones,
   cortesías, revisiones, cierres y pagos. `bitacora_puerta` trae lo que
   le pasó a cada manilla en el ingreso. Se muestran juntas y ordenadas
   por hora porque así fue como pasaron: una manilla que se escaneó a las
   23:40 y se anuló a las 23:50 cuenta una sola historia, no dos.

   ── el permiso lo decide la base, y no se rehace acá ──
   `bitacora_admin` exige puede_editar(): a un portero le contesta "Sin
   permiso" y esta pantalla no lo muestra como un error, simplemente no
   trae ese bloque. `bitacora_puerta` SIN puede_editar() devuelve solo lo
   que hizo quien pregunta —un portero no audita a los otros porteros— y
   lo dice en `alcance`. Acá se lee ese campo y se escribe el cartel; no
   se mira el rol para decidir nada, porque el día que las dos lógicas se
   desincronicen la pantalla va a mentir con total convicción. */
const ACCION_TXT = {
  orden_anulada:       "Compra anulada",
  entrada_anulada:     "Manilla anulada",
  cortesias_emitidas:  "Cortesías emitidas",
  revision_confirmada: "Revisión confirmada",
  evento_cerrado:      "Evento cerrado",
  evento_reabierto:    "Evento reabierto",
  comision_pagada:     "Comisión pagada",
};

const PUERTA_TXT = {
  validada:  "Entró",
  reingreso: "Volvió a entrar",
  deshecha:  "Se deshizo el ingreso",
  rechazada: "Rechazada en el filtro",
};

/* Las dos respuestas se aplanan a la MISMA forma antes de dibujar nada.
   Con dos formas distintas hay dos plantillas, y dos plantillas es cómo
   una fuente termina mostrando el motivo y la otra olvidándoselo. */
function sucesoAdmin(f) {
  return { id: "a" + f.id, at: f.ocurrio_at, fuente: "panel",
           que: ACCION_TXT[f.accion] || f.accion,
           sobre: detalleRegistro(f), motivo: f.motivo || "",
           quien: f.actor || "—", donde: "en el panel" };
}

function sucesoPuerta(f) {
  const nota = [];
  if (f.accion === "deshecha" || f.accion === "reingreso") {
    if (f.used_at_previo) nota.push(`había entrado ${fmtFH(f.used_at_previo)}`);
    if (f.portero_previo_nombre) nota.push(`lo marcó ${f.portero_previo_nombre}`);
  }
  if (f.accion === "rechazada") nota.push(`estaba ${ESTADO_PREVIO_TXT[f.estado_previo] || f.estado_previo}`);
  return { id: "p" + f.id, at: f.ocurrio_at, fuente: "puerta",
           que: PUERTA_TXT[f.accion] || f.accion,
           sobre: [f.code, f.cliente].filter(Boolean).join(" · "),
           /* La puerta no pide motivo y acá no se le inventa uno: un
              escaneo no es una decisión con explicación, es un hecho.
              Lo que sí va es qué había antes, que es la mitad del dato
              que hace falta para reclamarle a alguien. */
           motivo: "", nota: nota.join(" · "),
           quien: f.actor || "—", donde: "en la puerta" };
}

const ESTADO_PREVIO_TXT = { valida: "válida", usada: "ya usada", anulada: "anulada" };

/* Trae las dos fuentes sin dejar que una tumbe a la otra: al portero,
   `bitacora_admin` le tira "Sin permiso" y eso NO es un error de
   pantalla, es la respuesta correcta. Por eso allSettled y no all. */
async function traerBitacora(eventoId, tope) {
  const [ra, rp] = await Promise.all([
    sb.rpc("bitacora_admin",  { p_evento: eventoId, p_desde: 0, p_tope: tope }),
    sb.rpc("bitacora_puerta", { p_evento: eventoId, p_entrada: null, p_desde: 0, p_tope: tope }),
  ]);
  const admin  = ra.error ? null : (ra.data || {});
  const puerta = rp.error ? null : (rp.data || {});
  const sucesos = [
    ...((admin  && admin.filas)  || []).map(sucesoAdmin),
    ...((puerta && puerta.filas) || []).map(sucesoPuerta),
  ].sort((x, y) => (x.at < y.at ? 1 : x.at > y.at ? -1 : 0));
  return { admin, puerta, sucesos,
           errores: [ra.error, rp.error].filter(Boolean).map(e => sinCodigo(e.message)) };
}

const DIA_LARGO = t => new Date(t).toLocaleDateString("es-BO",
  { weekday: "long", day: "numeric", month: "long" });
const HORA = t => new Date(t).toLocaleTimeString("es-BO",
  { hour: "2-digit", minute: "2-digit", hour12: false });

/* Agrupada por día y con la hora al costado: "el jueves a las 23:50" es
   como se acuerda una noche, no "2026-08-29T23:50:12.331Z". */
function historia(sucesos) {
  let dia = null;
  return `<ol class="bitacora">${sucesos.map(s => {
    const d = DIA_LARGO(s.at);
    const cab = d === dia ? "" : `<li class="bit-dia">${esc(d)}</li>`;
    dia = d;
    return cab + `
      <li class="bit-suceso bit-${s.fuente}">
        <span class="bit-hora">${esc(HORA(s.at))}</span>
        <div class="bit-cuerpo">
          <p class="bit-que"><b>${esc(s.que)}</b>${s.sobre ? ` — ${esc(s.sobre)}` : ""}</p>
          ${s.motivo ? `<p class="bit-motivo">“${esc(s.motivo)}”</p>` : ""}
          ${s.nota ? `<p class="bit-nota">${esc(s.nota)}</p>` : ""}
          <p class="bit-quien">${esc(s.quien)} · ${esc(s.donde)}</p>
        </div>
      </li>`;
  }).join("")}</ol>`;
}

/* La pantalla entera. `volver` viene de quien la abre: desde el evento se
   vuelve al evento y desde la puerta se vuelve a la puerta — con la
   cámara apagada de antes, porque un <video> huérfano sigue comiendo
   batería toda la noche. */
async function pantallaBitacora(eventoId, opts) {
  const volver = (opts && opts.volver) || (() => abrirEvento(eventoId));
  BIT.evento = eventoId;
  BIT.volver = volver;
  $("#main").innerHTML = `<p class="cargando">Cargando la bitácora…</p>`;

  const ev = await sb.from("eventos").select("id,nombre,slug,fecha").eq("id", eventoId).single();
  /* Se vuelve por donde se vino y no a "eventos": el portero que llega
     acá desde la puerta no tiene esa pestaña, y mandarlo ahí lo deja
     mirando una pantalla en blanco. */
  if (ev.error || !ev.data) { avisar("Ese evento ya no existe."); volver(); return; }
  BIT.ev = ev.data;
  const atras = (opts && opts.volverTxt) || BIT.ev.nombre;

  const b = await traerBitacora(eventoId, 500);
  const sinNada = !b.sucesos.length;
  const soloMios = b.puerta && b.puerta.alcance === "mios";
  const cortada = (b.admin && b.admin.cortada) || (b.puerta && b.puerta.cortada);

  $("#main").innerHTML = `
    <div class="cab-seccion">
      <button class="btn plano chico" id="btnVolver">← ${esc(atras)}</button>
      <h2>Bitácora</h2>
      ${b.admin ? `<button type="button" class="btn plano chico" id="btnCsvBit"
        >Bajar la bitácora</button>` : ""}
    </div>
    <p class="ayuda bajo-titulo">Qué pasó, quién y por qué. Se escribe sola, no se
      puede editar ni borrar, y va de lo más nuevo a lo más viejo.${
      soloMios ? " Acá ves solo lo que hiciste vos: un portero no audita a los otros porteros." : ""}${
      cortada ? ` En pantalla entran las últimas 500; el archivo las trae todas.` : ""}</p>
    ${b.errores.length && !b.admin && !b.puerta
      ? `<p class="error">${esc(b.errores[0])}</p>` : ""}
    ${sinNada
      /* Con alcance 'mios' la frase no puede hablar del evento: el
         portero no está viendo el evento, está viendo lo suyo, y decirle
         "no pasó nada" sería afirmar algo que esta pantalla no sabe. */
      ? soloMios
        ? `<p class="vacio">Todavía no escaneaste ninguna manilla en este evento.
             Acá va quedando lo tuyo: cada ingreso, cada deshacer y cada rechazo.</p>`
        : `<p class="vacio">Todavía no pasó nada en este evento: no se anuló ni se regaló
             nada, y nadie escaneó una manilla.</p>`
      : historia(b.sucesos)}`;

  $("#btnVolver").onclick = () => volver();
  const bc = $("#btnCsvBit");
  if (bc) bc.onclick = () => conBoton(bc, "Armando…", bajarBitacora);
}

const BIT = { evento: null, ev: null, volver: null };

/* El archivo trae las dos fuentes completas, no las 500 de la pantalla:
   se baja justo cuando hay que reconstruir una noche entera, que es
   cuando 500 no alcanzan. Si algo se corta, `traerTodo` tira y no se baja
   nada — un CSV de auditoría al que le faltan filas es el peor archivo
   posible, porque se lee como si estuviera completo. */
async function bajarBitacora() {
  const [a, p] = await Promise.all([
    traerTodo("bitacora_admin",  { p_evento: BIT.evento }),
    traerTodo("bitacora_puerta", { p_evento: BIT.evento, p_entrada: null }),
  ]);
  const sucesos = [...a.filas.map(sucesoAdmin), ...p.filas.map(sucesoPuerta)]
    .sort((x, y) => (x.at < y.at ? 1 : x.at > y.at ? -1 : 0));
  if (!sucesos.length) { avisar("Todavía no hay nada anotado en este evento."); return; }
  CSV.bajar(CSV.nombre("bitacora", BIT.ev), [
    ["Cuándo", "Dónde", "Qué pasó", "Sobre", "Motivo", "Quién"],
    ...sucesos.map(s => [CSV.fh(s.at), s.fuente === "panel" ? "Panel" : "Puerta",
                         s.que, s.sobre || "", s.motivo || s.nota || "", s.quien]),
  ]);
  avisar(`Bajaron ${sucesos.length} ${sucesos.length === 1 ? "movimiento" : "movimientos"}.`);
}

/* ── el asomo del tablero ──
   Abajo de todo y no arriba: no es una alerta, es lo que se mira cuando
   algo ya pasó y hay que explicarlo. Van las últimas cinco decisiones y
   un botón: el que llega hasta acá abajo quiere ver si hay algo raro, y
   si lo hay entra a la bitácora entera. Cinco líneas contestan la primera
   pregunta sin empujar el resto del tablero fuera de la pantalla. */
async function refrescarRegistro(eventoId) {
  const z = $("#zonaRegistro");
  if (!z) return;
  const { data, error } = await sb.rpc("bitacora_admin",
    { p_evento: eventoId, p_desde: 0, p_tope: 5 });
  if (error) { z.innerHTML = `<p class="error">${esc(sinCodigo(error.message))}</p>`; return; }
  const filas = (data && data.filas) || [];
  const total = Number((data && data.total) || 0);
  z.innerHTML = `
    <div class="cab-bloque sep">
      <h3 class="titulo-bloque">Decisiones</h3>
      <span class="conteo">${total ? `${num(total)} en total` : ""}</span>
      <span class="bajadas">
        <button type="button" class="btn plano chico" id="btnVerBitacora">Ver la bitácora →</button>
      </span>
    </div>
    ${filas.length
      ? historia(filas.map(sucesoAdmin))
      : `<p class="vacio">Todavía no se anuló ni se regaló nada en este evento.</p>`}`;
  $("#btnVerBitacora").onclick = () => pantallaBitacora(eventoId);
}

/* La línea chica de cada hecho: lo que la decisión tocó, en el vocabulario
   de cada acción. Un "3" suelto no dice nada; "3 manillas · 1 ya había
   entrado" es lo que hace falta para entender una anulación vieja. */
function detalleRegistro(f) {
  const d = f.detalle || {};
  if (f.accion === "orden_anulada") {
    const usadas = Number(d.usadas_incluidas) || 0;
    return [
      d.comprador || f.comprador || "sin nombre",
      manillasTxt(d.entradas_anuladas || 0),
      usadas ? `${num(usadas)} ya ${usadas === 1 ? "había" : "habían"} entrado` : "",
      d.mesa_liberada ? "mesa liberada" : "",
      d.estado_previo === "revision_manual" ? "venía de una revisión" : "",
    ].filter(Boolean).join(" · ");
  }
  if (f.accion === "entrada_anulada") {
    return [d.code || f.code, d.cliente, d.estado_previo === "usada" ? "ya había entrado" : "",
            d.devuelve_cupo ? "devolvió su lugar" : ""].filter(Boolean).join(" · ");
  }
  if (f.accion === "cortesias_emitidas") {
    return [`${num(d.cantidad)} × ${d.tipo || ""}`, `para ${d.para || "—"}`].join(" · ");
  }
  if (f.accion === "revision_confirmada") {
    return [d.comprador || f.comprador || "sin nombre", manillasTxt(d.entradas || 0),
            d.monto_cobrado != null ? `cobrado ${bs(d.monto_cobrado)} de ${bs(d.total)}` : "",
            d.pago_ref ? `ref ${d.pago_ref}` : ""].filter(Boolean).join(" · ");
  }
  if (f.accion === "evento_cerrado") {
    return [`versión ${d.version}`, `${bs(d.bruto)} vendidos`,
            `${bs(d.comisiones)} en comisiones`].filter(Boolean).join(" · ");
  }
  if (f.accion === "evento_reabierto") {
    const n = Number(d.comisiones_ya_pagadas) || 0;
    return n ? `${num(n)} ${n === 1 ? "comisión ya pagada" : "comisiones ya pagadas"} contra la foto anterior`
             : "no había ninguna comisión pagada todavía";
  }
  if (f.accion === "comision_pagada") {
    return [d.nombre, d.monto != null ? bs(d.monto) : "",
            d.entradas != null ? manillasTxt(d.entradas) : ""].filter(Boolean).join(" · ");
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

const EQ = { gente: [], editando: null, alta: false, clave: null, eventos: [] };

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
  const [gente, evs] = await Promise.all([
    sb.from("perfiles")
      .select("id,nombre,rol,activo,slug,comision_entrada")
      .eq("organizador_id", S.yo.organizador_id)
      .order("activo", { ascending: false })
      .order("nombre"),
    /* Los eventos a la venta, para poder armar acá el link de cada
       relacionador. El admin es el que da de alta a la persona y el que se
       la manda por WhatsApp; obligarlo a entrar con la cuenta de esa
       persona para copiarle su propio link es la clase de vuelta que
       termina en que le pase el link pelado y la venta no sea de nadie. */
    sb.from("eventos").select("id,slug,nombre,fecha")
      .eq("estado", "publicado").order("fecha", { ascending: true }),
  ]);
  if (gente.error) { $("#main").innerHTML = `<p class="error">${esc(gente.error.message)}</p>`; return; }
  EQ.gente = gente.data || [];
  EQ.eventos = evs.error ? [] : (evs.data || []);
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
    ${p.rol === "rrpp" && p.slug ? zonaLinksDe(p) : ""}
    ${editando ? formEdicion(p, yo) : ""}
  </li>`;
}

/* El link de venta de una persona, listo para copiar y mandar. Uno por
   evento a la venta: el ?r= es de la persona, pero el link es de un evento
   concreto y mandar el del evento equivocado vende otra cosa. */
function zonaLinksDe(p) {
  if (!EQ.eventos.length) return `<div class="persona-links vacio-links">
    Cuando haya un evento a la venta, acá aparece el link de ${esc(p.nombre)}.</div>`;
  return `<div class="persona-links">
    ${EQ.eventos.map((e, i) => {
      const url = `${location.origin}/${S.orgSlug}/${e.slug}` +
                  `?r=${encodeURIComponent(p.slug)}`;
      const id = `lk-${p.id}-${i}`;
      return `<p class="link-publico">
        ${EQ.eventos.length > 1 ? `<span class="link-evento-nombre">${esc(e.nombre)}</span>` : ""}
        <code id="${id}">${esc(url)}</code>
        <button type="button" class="btn plano chico" data-copiar="${id}"
          data-que="El link de ${esc(p.nombre)}">Copiar</button>
      </p>`;
    }).join("")}
  </div>`;
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

/* `bitacora` se expone para la puerta: el portero necesita poder revisar
   sus propios escaneos sin salir de su pestaña, y la pantalla es la misma
   —lo que ve cada uno lo decide bitacora_puerta() adentro, no esto. */
window.ADMIN = { S, sb, mostrar, avisar, esc, bitacora: pantallaBitacora };
})();
