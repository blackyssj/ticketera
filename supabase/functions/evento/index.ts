/* evento — lo único que el público puede leer, y lo lee por acá.
   No hay vistas públicas ni grants a `anon`: una vista puede perder
   security_invoker en un `create or replace` y quedar leyendo sin RLS (así se
   filtró v_stats_rrpp en Puerta). Una función no falla de esa manera.
   Devuelve la misma forma que datos-demo.js para que el frontend no distinga
   el modo demo del real.

   Un solo viaje a la base: `evento_publico()` (migración 0048) devuelve en
   un jsonb lo que antes se juntaba con siete pedidos en fila a PostgREST
   (organizador → evento → fase → precios → disponibilidad por tipo). Cada
   ida y vuelta costaba más que la consulta que llevaba adentro, y la
   página no podía pintar nada hasta que volviera el último. Acá queda
   sólo el armado de la respuesta; qué es vendible lo decide la base con
   las mismas funciones que usa crear_orden. */
const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, GET, OPTIONS",
};
const json = (b: unknown, s = 200) =>
  new Response(JSON.stringify(b), { status: s, headers: { ...CORS, "Content-Type": "application/json" } });

// service_role: estas funciones SON el guardián. La anon key no escribe nunca.
const SB  = Deno.env.get("SUPABASE_URL")!;
const KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const H = { apikey: KEY, Authorization: `Bearer ${KEY}`, "Content-Type": "application/json" };

async function rest(ruta: string, init: RequestInit = {}) {
  const r = await fetch(`${SB}/rest/v1/${ruta}`, { ...init, headers: { ...H, ...(init.headers ?? {}) } });
  const t = await r.text();
  const j = t ? JSON.parse(t) : null;
  if (!r.ok) throw new Error(j?.message ?? j?.hint ?? t);
  return j;
}
const rpc = (fn: string, args: Record<string, unknown>) =>
  rest(`rpc/${fn}`, { method: "POST", body: JSON.stringify(args) });

// El frontend tiene que poder decirle al comprador que esto todavía no cobra.
// Si el dato no viaja, la página parece una venta real y no lo es.
// Normalizado igual que en iniciar-pago y estado-orden (recortado,
// minúsculas): acá no se falla cerrado porque este endpoint solo informa,
// no cobra ni emite — pero si el valor no es ninguno de los dos esperados,
// mejor mostrar la variable cruda que fingir "simulada" en silencio.
const PASARELA = (Deno.env.get("PASARELA") ?? "").trim().toLowerCase() || "(sin configurar)";

// Igual de fail-open que PASARELA antes de su arreglo: si no hay
// RESEND_API_KEY, enviar-entradas nunca manda nada, así que la pantalla
// final no puede prometer un correo que no va a salir. El frontend usa
// este dato para no prometerlo.
const CORREO_CONFIGURADO = !!Deno.env.get("RESEND_API_KEY");

const MES = ["ENE","FEB","MAR","ABR","MAY","JUN","JUL","AGO","SEP","OCT","NOV","DIC"];
const DIA = ["DOM","LUN","MAR","MIÉ","JUE","VIE","SÁB"];

const DIA_LARGO = ["domingo","lunes","martes","miércoles","jueves","viernes","sábado"];

/* Una lista free cover de Puerta (0104) dicha como la diría el boliche.
   ingreso_hasta ('HH:MM') es hasta qué hora entra gratis el que está en la
   lista; registro_hasta ('YYYY-MM-DD HH:MM', hora de Bolivia) hasta cuándo
   uno se puede anotar. Son dos cosas distintas y no se mezclan: "hasta las
   22:00" a secas, con la hora de anotarse, haría llegar a las 22:30 a
   alguien que igual entraba gratis — o al revés. Sin ninguna de las dos,
   "en lista": es lo que Puerta sabe.

   El cierre de la lista lleva día cuando cae fuera de la noche (de las
   12:00 de la fecha a las 12:00 del día siguiente): en Puerta una lista se
   puede cerrar el jueves para el sábado, y "hasta las 20:00" a secas se
   leería como el sábado. Y si ya pasó, se dice: anotarse ya no se puede,
   pero el que está anotado sigue necesitando saber hasta qué hora entra.
   `ahora` va en el mismo formato y en hora de Bolivia, así que se compara
   como texto. */
function freeCoverTxt(f: Record<string, unknown>, fecha: string, ahora: string) {
  const entra = typeof f.ingreso_hasta === "string" && /^\d{2}:\d{2}/.test(f.ingreso_hasta)
    ? f.ingreso_hasta.slice(0, 5) : null;
  const reg = typeof f.registro_hasta === "string"
    && /^\d{4}-\d{2}-\d{2} \d{2}:\d{2}$/.test(f.registro_hasta) ? f.registro_hasta : null;
  let anota: string | null = null;
  if (reg && reg <= ahora) {
    anota = "lista cerrada";
  } else if (reg) {
    const d = new Date(reg.slice(0, 10) + "T12:00:00Z");
    const noche = new Date(fecha + "T12:00:00Z").getTime();
    const ms = new Date(reg.replace(" ", "T") + ":00Z").getTime();
    const esLaNoche = ms >= noche && ms < noche + 24 * 3600_000;
    anota = esLaNoche
      ? `en lista hasta las ${reg.slice(11)}`
      : `en lista hasta el ${DIA_LARGO[d.getUTCDay()]} ${d.getUTCDate()} a las ${reg.slice(11)}`;
  }
  if (entra) return `hasta las ${entra} · ${anota ?? "en lista"}`;
  return anota ?? "en lista";
}

/* Los cuatro motivos por los que la base no devuelve un evento, con el
   mismo texto y el mismo código que tenía cada uno cuando eran cuatro
   pedidos distintos. El comprador los ve en pantalla: "no existe" y
   "todavía no está a la venta" no son la misma noticia. */
const FALTA: Record<string, [string, number]> = {
  organizador: ["Ese organizador no existe.", 404],
  evento:      ["Ese evento no existe.", 404],
  publicado:   ["El evento todavía no está a la venta.", 404],
  fase:        ["No hay ninguna fase de venta abierta.", 409],
};

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  try {
    const u = new URL(req.url);
    let org = u.searchParams.get("organizador"), ev = u.searchParams.get("evento");
    if (req.method === "POST") {
      const b = await req.json().catch(() => ({}));
      org = b.organizador ?? org; ev = b.evento ?? ev;
    }
    if (!org || !ev) return json({ ok: false, motivo: "Falta organizador o evento." }, 400);

    const d = await rpc("evento_publico", { p_org: org, p_slug: ev });
    if (!d || d.falta || !d.evento) {
      const [motivo, status] = FALTA[d?.falta] ?? FALTA.evento;
      return json({ ok: false, motivo }, status);
    }
    const o = d.organizador, e = d.evento, fase = d.fase;

    // `disponible` viene null cuando el tipo no tiene tope: 9999 es el
    // "sin tope" que el front ya entiende. Con tope, lo que queda de verdad
    // (vendido + retenido + cortesías ya restados por la base).
    const tipos = [];
    for (const p of d.precios ?? []) {
      const t = p.tipo_entrada;
      if (!t?.activo) continue;
      tipos.push({ id: t.id, nombre: t.nombre, desc: t.descripcion ?? "",
                   incluye: t.incluye ?? null,
                   categoria: t.categoria ?? "entrada",
                   precio: Number(p.precio), antes: null,
                   cupo: p.cupo === null ? 9999 : Number(p.disponible ?? 0),
                   manillas: t.manillas ?? 1, orden: t.orden });
    }
    tipos.sort((a, b) => a.orden - b.orden);

    // El comprador ya no elige mesa en un plano: compra el producto y el
    // relacionador le asigna cuál. El dato del hero sale del cupo que queda
    // de los productos de mesa, NO de cuántas filas hay en `mesas`: ahí
    // están todas las del predio, vendidas incluidas, y el hero prometía 24
    // disponibles con cero para vender.
    const reservas = tipos.filter((t) => t.categoria === "mesa")
                          .reduce((n, t) => n + (t.cupo === 9999 ? 0 : t.cupo), 0);

    // el público ve tres estados y ninguno lleva el nombre de nadie
    const f = new Date(e.fecha + "T00:00:00-04:00");
    // Orden deliberado: la planta baja primero. Derivarlo del orden de las
    // mesas lo dejaba alfabético (A1 antes que M1) y abría en la alta.


    /* El título. Partido en dos renglones (marca_1 / marca_2) como lo
       espera la página. Con titulo_marca (0104, Bowie y BurTown) arriba va
       la marca de la casa en mayúsculas y abajo la noche: lo que vende es
       el boliche, y "CRUSH" en grande con "Bowie" de lugar se leía al revés.
       Se decide acá y no en el front para que el título del documento, el
       .ics, "Mis entradas" y el ticket sin arte digan todos lo mismo. */
    const marca = o.titulo_marca === true;
    const partes = marca
      ? [String(o.nombre).toUpperCase(), String(e.nombre)]
      : String(e.nombre).split(" ");
    /* Lo que la noche trae de Puerta (0104). Solo en espejos: en una fecha
       cargada acá el cierre es el default 06:00 que nadie eligió, y
       anunciarlo sería inventarlo. */
    const espejo = e.entrada_puerta === true;
    const hi = String(e.hora_inicio).slice(0, 5);
    const hf = espejo && e.hora_fin ? String(e.hora_fin).slice(0, 5) : null;
    const free: Record<string, unknown>[] = Array.isArray(e.free_cover)
      ? e.free_cover.filter((f: unknown) => f && typeof f === "object" && (f as any).nombre).slice(0, 6)
      : [];
    // Ahora en Bolivia (UTC−4 todo el año), con la forma de registro_hasta.
    const ahoraBo = new Date(Date.now() - 4 * 3600_000).toISOString().slice(0, 16).replace("T", " ");
    return json({
      ok: true,
      pasarela: PASARELA,
      correo_configurado: CORREO_CONFIGURADO,
      organizador: { nombre: o.nombre, fee_pct: Number(o.fee_pct),
                     fee_fijo: Number(o.fee_fijo_transaccion), fee_piso: Number(o.fee_piso),
                     /* 'adentro' = el cargo sale del precio publicado. La página
                        lo necesita para NO anunciar un cargo que el comprador no
                        va a pagar, y para que el total sea el precio de la lista. */
                     comision_modo: o.comision_modo ?? "sobre",
                     /* false = el organizador no quiere "Quedan N" en la
                        calle. El cupo viaja igual (el stepper lo necesita);
                        lo que cambia es que la página no lo pinta. */
                     muestra_cupo: o.muestra_cupo !== false,
                     /* Cuántas fechas del organizador están a la venta, esta
                        incluida. Con más de una, la página ofrece el camino
                        a la vidriera; con una sola no hay a dónde ir. */
                     fechas: Number(o.fechas ?? 1),
                     // Sólo el usuario (0102): la página arma el link.
                     instagram: o.instagram ?? null },
      evento: {
        id: e.id,
        marca_1: partes[0],
        marca_2: partes.slice(1).join(" "),
        /* true = marca_1 es la casa y marca_2 la noche (0104): la página
           los pinta como título y subtítulo y no como un nombre partido. */
        titulo_marca: marca,
        /* true = espejo de Plataforma Puerta: ticket.js dibuja la entrada
           IGUAL que Puerta (sus fuentes, sin la firma de TICKETAZO), porque
           va al mismo escáner y a los mismos chats que la del relacionador. */
        entrada_puerta: espejo,
        lugar: e.lugar ?? "",
        // El link de Google Maps del lugar (0104), para "Cómo llegar" cuando
        // no hay punto. Viene validado por la base: https y de Google.
        maps_url: e.maps_url ?? null,
        // Dónde queda (0086): la dirección en texto y el punto para el mapa
        // y el botón "Cómo llegar". Nulos si el organizador no los cargó;
        // la página esconde el bloque entero.
        direccion: e.direccion ?? null,
        lat: e.lat == null ? null : Number(e.lat),
        lng: e.lng == null ? null : Number(e.lng),
        // La fecha también cruda: el texto de abajo no trae año, y el front la
        // necesita entera para el .ics y para "Mis entradas". Sin esto el
        // cliente la reconstruye adivinando el año por el día de semana.
        fecha: e.fecha,
        hora_inicio: String(e.hora_inicio).slice(0,5),
        // Suelto además de en `datos`: el front decide con él si avisa "+18".
        edad_min: e.edad_min == null ? null : Number(e.edad_min),
        fecha_txt: `${DIA[f.getDay()]} ${f.getDate()} ${MES[f.getMonth()]} · ${String(e.hora_inicio).slice(0,5)}`,
        bajada: e.descripcion ?? "",
        // El dato de reservas solo aparece si hay reservas. "0 disponibles"
        // en un evento que no vende mesas no es un cero, es un renglón que
        // el comprador tiene que descartar solo.
        // Un evento gratis (todos los precios en 0) no tiene "Pago": tiene
        // inscripción. Y "Edad mínima 0" no es un dato, es un renglón vacío:
        // un congreso o un DevFest no piden edad.
        /* En un espejo, además, hasta qué hora es la noche y el free cover
           de Puerta, un renglón por lista ("Free Cover Mujeres · hasta las
           23:50 · en lista hasta las 22:00"). Van en el afiche, al lado de las puertas: es
           lo primero que se pregunta por WhatsApp antes de comprar. */
        datos: [["Puertas", hf ? `${hi} a ${hf}` : hi],
                ...(Number(e.edad_min) > 0 ? [["Edad mínima", String(e.edad_min)]] : []),
                ...free.map((f) => [String(f.nombre), freeCoverTxt(f, String(e.fecha), ahoraBo)]),
                ...(reservas > 0 ? [["Reservas", `${reservas} disponibles`]] : []),
                tipos.length && tipos.every((t) => Number(t.precio) === 0)
                  ? ["Inscripción", "Gratis"] : ["Pago", "Con QR"]],
        tope_entradas_orden: e.tope_entradas_orden,
        arte_url: e.arte_url ?? null,
        /* La marca del organizador (0062). Van los tres o no va ninguno:
           la base los valida como hexadecimal y acá se pasan tal cual —
           el front decide si pinta. Con null, la página sale con la
           paleta de TICKETAZO, que es lo que hacía siempre. */
        color_fondo: e.color_fondo ?? null,
        color_acento: e.color_acento ?? null,
        logo_url: e.logo_url ?? null,
        // El flyer va en el hero si lo hay (0097); la entrada usa arte_url.
        flyer_url: e.flyer_url ?? null,
      },
      // `hasta` en crudo para que el front diga "cierra en 3 días" sólo
      // cuando hay un cierre de verdad; `hasta_txt` sigue para el chip.
      /* `sello`: el nombre que Puerta imprime en la entrada cuando la fase
         no tiene arte propio (0104). Null en todo lo que no es una fase de
         Puerta, incluida la 'Online' que inventa el espejo. */
      fase: { nombre: fase?.nombre ?? "", arte_url: fase?.arte_url ?? null, sello: fase?.sello ?? null,
              hasta: fase?.hasta ?? null, hasta_txt: fase?.hasta
        ? "hasta el " + new Date(fase.hasta).toLocaleDateString("es-BO",
            { day: "numeric", month: "long", timeZone: "America/La_Paz" })
        : "" },
      tipos,
      /* Todas las fases públicas, en orden (0091): la página muestra la que
         vende, las agotadas como "sold out" y las próximas con su precio,
         para que se vea a cuánto sube cuando se acabe la de hoy. Qué
         estado tiene cada una lo decide la base, con el mismo criterio
         que fase_vigente(). */
      /* true = el evento existe y tiene fases, pero ahora no se vende nada
         (todavía no abrió, o se agotó y la próxima abre por fecha). La
         página se muestra igual, sin tarjetas de compra (0092). */
      sin_venta: d.sin_venta === true,
      fases: (d.fases ?? []).map((x: Record<string, unknown>) => ({
        nombre: String(x.nombre ?? ""), precio: Number(x.precio), varios: !!x.varios,
        estado: String(x.estado ?? ""), desde: x.desde ?? null, hasta: x.hasta ?? null })),
    });
  } catch (err) {
    return json({ ok: false, motivo: String((err as Error).message ?? err) }, 500);
  }
});
