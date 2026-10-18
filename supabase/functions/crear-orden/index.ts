/* crear-orden — el único camino de escritura del público.
   Corre con service_role, así que valida TODO antes de tocar la base: el
   evento se resuelve por slug y jamás se acepta un evento_id del cliente.
   La idempotencia la pone crear_orden(), por client_key. */
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
/* La anon key la inyecta el runtime igual que las otras dos. Sirve para
   reconocer cuándo el Authorization trae la anon key (un comprador sin
   cuenta) y cuándo trae el JWT de un comprador logueado. */
const ANON = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

async function rest(ruta: string, init: RequestInit = {}) {
  const r = await fetch(`${SB}/rest/v1/${ruta}`, { ...init, headers: { ...H, ...(init.headers ?? {}) } });
  const t = await r.text();
  const j = t ? JSON.parse(t) : null;
  if (!r.ok) throw new Error(j?.message ?? j?.hint ?? t);
  return j;
}
const uno = async (ruta: string) => (await rest(ruta))?.[0] ?? null;
const rpc = (fn: string, args: Record<string, unknown>) =>
  rest(`rpc/${fn}`, { method: "POST", body: JSON.stringify(args) });

const q = (s: string) => encodeURIComponent(s);

/* El hash de la IP, no la IP: alcanza para frenar abuso y no guardamos de
   quién es. Va a `ordenes.ip_hash`. */
async function hashIp(req: Request) {
  const ip = (req.headers.get("x-forwarded-for") ?? "").split(",")[0].trim() || "sin-ip";
  const b = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(ip + "|ticketera"));
  return Array.from(new Uint8Array(b)).slice(0, 12).map((x) => x.toString(16).padStart(2, "0")).join("");
}

/* ── el comprador logueado ──
   Si el comprador ya tiene cuenta (0049), el navegador manda su JWT en el
   Authorization en vez de la anon key, y la orden nace con dueño: aparece
   en "mis compras" sin que tenga que guardarla a mano después.

   El token se verifica contra /auth/v1/user y no se decodifica — un atob()
   lee lo que el token DICE sin comprobar quién lo firmó. Y si no vale
   (venció, es basura, es la anon key), la respuesta es null y la compra
   sigue EXACTAMENTE igual que sin cuenta: nunca se rechaza una venta por
   un problema de sesión. Por eso tampoco tira: cualquier error acá es
   "no hay comprador logueado". */
async function compradorLogueado(req: Request): Promise<string | null> {
  const cab = req.headers.get("Authorization") ?? "";
  const token = /^Bearer\s+(.+)$/i.exec(cab)?.[1]?.trim();
  if (!token || token === ANON) return null;
  try {
    const r = await fetch(`${SB}/auth/v1/user`, {
      headers: { apikey: KEY, Authorization: `Bearer ${token}` },
    });
    if (!r.ok) return null;
    const u = await r.json().catch(() => null);
    return typeof u?.id === "string" && UUID_RE.test(u.id) ? u.id : null;
  } catch {
    return null;
  }
}

/* Los errores de la base salen con prefijo (SIN_CUPO:, MESA_TOMADA:, …).
   El comprador no tiene por qué leer eso. */
function traducir(m: string) {
  if (m.includes("SIN_CUPO")) return "Se acabaron las entradas de ese tipo mientras elegías.";
  if (m.includes("MESA_TOMADA")) return "Alguien tomó esa mesa hace un momento. Elegí otra.";
  if (m.includes("TOPE:")) return "Pasaste el máximo de entradas por compra.";
  if (m.includes("DEMASIADAS_ORDENES")) return "Tenés varias compras sin terminar. Cerrá alguna y volvé a intentar.";
  if (m.includes("EVENTO_NO_PUBLICADO")) return "El evento todavía no está a la venta.";
  if (m.includes("SIN_FASE")) return "No hay ninguna fase de venta abierta.";
  if (m.includes("TIPO_NO_VENDIBLE")) return "Ese tipo de entrada no se vende en esta fase.";
  if (m.includes("UNA_MESA")) return UNA_MESA;
  if (m.includes("FALTA_TITULAR"))
    return "Para reservar una mesa poné el nombre y el carnet de la persona a cuyo nombre va.";
  if (m.includes("CI_INVALIDO")) return "El número de carnet no es válido.";
  return "No se pudo reservar. Probá de nuevo.";
}

const UNA_MESA = "Una mesa por compra. Si querés otra, hacé otra compra.";

/* ── el titular de la mesa (0107) ──
   Una mesa es una reserva para un grupo y en la puerta preguntan por la
   persona a cuyo nombre está, con su carnet. Se normaliza igual que en
   crear_orden —la base repite todo esto y tiene CHECK con la misma forma—
   para que un carnet mal escrito vuelva con una frase y no con un error
   de constraint.

   Carnet boliviano: 5 a 10 dígitos (sin puntos ni espacios), "E-" adelante
   si es de extranjero, y un complemento opcional de 2 caracteres (los
   duplicados del SEGIP, "1A") que se guarda pegado: 1234567-1A. La
   extensión es opcional porque los carnets nuevos de número único no la
   llevan; se aceptan los alias que la gente escribe (BE, PA, PN). */
const EXTENSIONES = new Set(["LP", "CB", "SC", "OR", "PT", "CH", "TJ", "BN", "PD"]);
const ALIAS_EXT: Record<string, string> = { BE: "BN", PA: "PD", PN: "PD" };

type Titular = { titular_nombre: string; titular_ci: string; titular_ci_ext: string | null };

function leerTitular(t: any): Titular | string {
  const nombre = String(t?.nombre ?? "").replace(/\s+/g, " ").trim().slice(0, 80).trim();
  if (!/^\S+( \S+)+$/.test(nombre))
    return "Poné nombre y apellido de la persona a cuyo nombre va la mesa.";
  // "E1234567" es el mismo carnet que "E-1234567"; y si el complemento
  // vino pegado al número (1234567-1A) también vale.
  const ci = String(t?.ci ?? "").toUpperCase().replace(/[\s.]/g, "").replace(/^-+|-+$/g, "")
    .replace(/^E(?=\d)/, "E-");
  const m = /^((?:E-)?[0-9]{5,10})(?:-([0-9A-Z]{2}))?$/.exec(ci);
  const comp = String(t?.complemento ?? "").toUpperCase().replace(/[\s.-]/g, "") || m?.[2] || "";
  let ext = String(t?.ext ?? "").toUpperCase().trim();
  ext = ALIAS_EXT[ext] ?? ext;
  if (!m || (comp && !/^[0-9A-Z]{2}$/.test(comp)) || (ext && !EXTENSIONES.has(ext)))
    return "Revisá el carnet de quien reserva la mesa.";
  return { titular_nombre: nombre, titular_ci: comp ? `${m[1]}-${comp}` : m[1],
           titular_ci_ext: ext || null };
}

/* Fechas de Bowie y BurTown (espejo de Plataforma Puerta, 0103): allá las
   escanean con el escáner de Puerta, así que la entrada recién emitida
   tiene que existir en la base de Puerta antes de que la persona llegue a
   la fila. El cron la manda al minuto; esto la manda en segundos. Se mira
   primero si quedó algo en la cola —barato— para no despertar a
   puerta-sync por cada entrada gratis de los otros clientes. Nunca demora
   la respuesta: si falla, el cron la levanta. */
function avisarPuerta() {
  const clave = Deno.env.get("BARRIDO_CLAVE") ?? "";
  if (!clave) return;
  const tarea = (async () => {
    const hay = await rest("puerta_envio?select=id&tipo=eq.entrada&estado=eq.pendiente&limit=1");
    if (!hay?.length) return;
    const r = await fetch(`${SB}/functions/v1/puerta-sync`, {
      method: "POST", headers: { ...H, "x-barrido": clave },
      body: JSON.stringify({ solo: "envios" }), signal: AbortSignal.timeout(15000),
    });
    if (!r.ok) console.error(`puerta-sync devolvió ${r.status} tras emitir gratis`);
  })().catch((e) => console.error(`aviso a puerta-sync falló: ${e}`));

  const rt = (globalThis as any).EdgeRuntime;
  if (rt && typeof rt.waitUntil === "function") rt.waitUntil(tarea);
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ ok: false, motivo: "Usá POST." }, 405);
  try {
    const b = await req.json();
    const { organizador, evento, items, comprador, client_key } = b ?? {};
    if (!organizador || !evento) return json({ ok: false, motivo: "Falta organizador o evento." }, 400);
    if (!Array.isArray(items) || items.length === 0)
      return json({ ok: false, motivo: "No elegiste nada." }, 400);
    if (items.length > 30) return json({ ok: false, motivo: "Demasiados ítems en una compra." }, 400);

    const nombre = String(comprador?.nombre ?? "").trim().slice(0, 80);
    const email  = String(comprador?.email  ?? "").trim().slice(0, 120);
    if (nombre.length < 3) return json({ ok: false, motivo: "Falta el nombre del comprador." }, 400);
    if (!/^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/.test(email))
      return json({ ok: false, motivo: "El correo no es válido." }, 400);
    /* Los términos se aceptan por orden, no por comprador: lo que vale es la
       versión vigente cuando se compró. El front manda la versión que mostró;
       si no viene, la compra no sigue —una orden sin aceptación registrada no
       sirve el día que haya que probarla. La versión se guarda tal cual llega
       (texto corto) para que un cambio de términos no reescriba la historia. */
    const tc = String(b?.tc ?? "").trim().slice(0, 40);
    if (!tc) return json({ ok: false, motivo: "Tenés que aceptar los términos para seguir." }, 400);

    const o = await uno(`organizadores?slug=eq.${q(organizador)}&activo=is.true&select=id`);
    if (!o) return json({ ok: false, motivo: "Ese organizador no existe." }, 404);
    const e = await uno(`eventos?organizador_id=eq.${o.id}&slug=eq.${q(evento)}&select=id`);
    if (!e) return json({ ok: false, motivo: "Ese evento no existe." }, 404);

    // La atribución la resuelve el servidor. El navegador manda un slug, no
    // un id: si mandara el id, cualquiera con la consola abierta se
    // acreditaría las ventas de otro. Y se busca dentro del organizador del
    // evento, porque el mismo slug puede existir en otro tenant.
    const r = String(b.r ?? "").trim().toLowerCase();
    /* Las mesas del evento (0107) se piden junto con el relacionador, en
       paralelo: casi siempre vuelve vacío y no le suma una vuelta a la
       compra. Sirve para contestar "una mesa por compra" y "falta el
       titular" con una frase antes de tocar la base; la que manda igual
       es crear_orden, que repite las dos reglas. */
    const [p, mesasEv] = await Promise.all([
      r && /^[a-z0-9-]{2,30}$/.test(r)
        ? uno(`perfiles?organizador_id=eq.${o.id}&slug=eq.${q(r)}&activo=is.true&select=id`)
        : Promise.resolve(null),
      // Si esta consulta falla, la compra no se cae por eso: decide la base.
      rest(`tipo_entrada?evento_id=eq.${e.id}&categoria=eq.mesa&select=id`).catch(() => null),
    ]);
    // La atribución, como siempre: un slug que no existe no rompe la venta.
    const rrpp_id: string | null = p?.id ?? null;

    const limpios = items.map((it) => it.mesa_id
      ? { mesa_id: String(it.mesa_id) }
      : { tipo_id: String(it.tipo_id), cantidad: Math.max(1, Math.min(50, Number(it.cantidad) || 1)) });

    const sabe = Array.isArray(mesasEv);
    const idsMesa = new Set((sabe ? mesasEv : []).map((t: { id: string }) => t.id));
    const mesas = limpios.reduce((n: number, it: any) =>
      n + (it.mesa_id ? 1 : idsMesa.has(it.tipo_id) ? it.cantidad : 0), 0);
    if (mesas > 1) return json({ ok: false, motivo: UNA_MESA }, 400);
    /* El titular viaja a la base solo si hay mesa: una compra de entradas
       no guarda el carnet de nadie aunque el navegador lo mande (y si lo
       mandara igual, crear_orden lo descarta). Sin la lista de mesas se
       pasa el que vino bien escrito y la base decide si hacía falta. */
    let titular: Titular | null = null;
    if (mesas === 1 || (!sabe && comprador?.titular)) {
      const t = leerTitular(comprador?.titular);
      if (typeof t !== "string") titular = t;
      else if (mesas === 1) return json({ ok: false, motivo: t }, 400);
    }

    let data;
    try {
      data = await rpc("crear_orden", {
        p_evento: e.id, p_items: limpios,
        p_comprador: { nombre, email, telefono: String(comprador?.telefono ?? "").slice(0, 30),
                       ...(titular ?? {}) },
        p_client_key: client_key ?? null, p_ip_hash: await hashIp(req), p_rrpp: rrpp_id,
      });
    } catch (err) {
      return json({ ok: false, motivo: traducir(String((err as Error).message)) }, 409);
    }

    /* El comprador vio un total y la base acaba de congelar otro: la tanda
       que miraba se agotó mientras llenaba sus datos. No se le cobra lo
       que no vio. La orden se da por vencida en el acto —si quedara
       pendiente apartaría el cupo diez minutos, y en la apertura de LÜMEN
       esas reservas fantasma fueron las que hicieron saltar la fase— y la
       página recarga el evento con el precio nuevo. Solo para órdenes
       nuevas: una repetida por client_key ya era del comprador. */
    const visto = Number(b.total_visto);
    if (data?.ok && data.orden && !data.repetida && Number.isFinite(visto) &&
        Math.abs(Number(data.total) - visto) > 0.5) {
      await rest(`ordenes?id=eq.${data.orden}&estado=eq.pendiente`, {
        method: "PATCH", headers: { Prefer: "return=minimal" },
        body: JSON.stringify({ estado: "vencida" }),
      }).catch((err) => console.error(`no se pudo vencer la orden ${data.orden}: ${err}`));
      return json({ ok: false, precio_cambio: true, total: Number(data.total),
                    motivo: `Mientras elegías cambió el precio: ahora el total es ${Number(data.total)} Bs ` +
                            `en vez de ${visto} Bs. Revisá tu compra antes de pagar.` }, 409);
    }

    /* El vínculo con la cuenta, si la hay. Va acá y no después del camino
       gratis para que una entrada de Bs 0 también quede guardada. Sólo si
       la orden todavía no tiene dueño: crear_orden es idempotente por
       client_key y puede devolver una orden que ya existía. Si el PATCH
       falla, la compra sigue: el comprador la puede guardar después con
       `vincular`, y una venta no se pierde por un vínculo. */
    if (data?.ok && data.orden) {
      /* La aceptación va en un PATCH aparte y no dentro de crear_orden para no
         tocar la firma de la RPC (0046). Sólo se escribe si la orden es nueva
         (tc_version aún nulo): crear_orden es idempotente por client_key. */
      try {
        await rest(`ordenes?id=eq.${data.orden}&tc_version=is.null`, {
          method: "PATCH", headers: { Prefer: "return=minimal" },
          body: JSON.stringify({ tc_version: tc, tc_aceptado_at: new Date().toISOString() }),
        });
      } catch (err) {
        console.error(`no se pudo registrar la aceptación en la orden ${data.orden}: ${err}`);
      }
      const uid = await compradorLogueado(req);
      if (uid) {
        try {
          await rest(`ordenes?id=eq.${data.orden}&comprador_user_id=is.null`, {
            method: "PATCH", headers: { Prefer: "return=minimal" },
            body: JSON.stringify({ comprador_user_id: uid }),
          });
        } catch (err) {
          console.error(`no se pudo vincular la orden ${data.orden} al comprador ${uid}: ${err}`);
        }
      }
    }

    /* Evento gratis. Si no hay nada que cobrar no hay pasarela que abrir: se
       emite acá mismo y el comprador salta del formulario a su entrada.
       Mandar una orden de Bs 0 a la pasarela devuelve un error del banco y
       deja al comprador mirando una pantalla de cobro por cero.

       Va acá y no en el navegador porque emitir es escribir, y el público no
       escribe: esta función corre con service_role del lado del servidor.

       emitir_orden es idempotente —si la orden ya estaba pagada devuelve las
       que hay— así que un doble envío del formulario no duplica entradas. */
    if (data?.ok && Number(data.total) === 0) {
      try {
        const em = await rpc("emitir_orden", {
          p_orden: data.orden, p_monto_cobrado: 0, p_pago_ref: "GRATIS",
        });
        if (em?.ok === true && em.repetida === false) avisarPuerta();
        return json({ ...data, gratis: true });
      } catch (err) {
        console.error(`no se pudo emitir la orden gratis ${data.orden}: ${err}`);
        return json({ ok: false, motivo: "No se pudo confirmar tu lugar. Probá de nuevo." }, 500);
      }
    }

    return json(data);
  } catch (err) {
    return json({ ok: false, motivo: String((err as Error).message ?? err) }, 500);
  }
});
