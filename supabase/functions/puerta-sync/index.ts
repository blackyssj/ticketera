/* puerta-sync — el espejo de Bowie y BurTown con Plataforma Puerta (0103).

   Puerta es la casa de esas fechas: allá se crean, allá se fija el precio y
   allá está la puerta que escanea. TICKETAZO solo las vende. Esta función
   es el ida y vuelta, en cuatro pasos que no dependen uno del otro:

     1. eventos     — trae de Puerta las fechas publicadas desde el corte y
                      crea / actualiza / cierra los espejos.
     2. entradas    — manda a Puerta las entradas pagadas acá (la cola
                      puerta_envio), a nombre del relacionador josemenacho2.
     3. estados     — trae de Puerta qué pasó en la puerta (entró, la filtró
                      Seguridad, la anularon) y lo copia acá.
     4. anulaciones — manda a Puerta lo que se anuló en el panel de acá y lo
                      que rechazó el filtro de Seguridad allá (el paso 3 lo
                      encola); esas se anulan acá cuando Puerta confirma.

   Un paso que falla no frena a los otros: si Puerta no contesta la lista de
   eventos, las entradas ya cobradas tienen que llegar igual. Cada error
   queda en la fila de la cola (ultimo_error) y en puerta_config.ultima_corrida.

   La llama pg_cron cada minuto (0103) y, en el acto, estado-orden,
   barrer-pagos y crear-orden cuando emiten una orden de un espejo (con
   {"solo":"envios"}: solo el paso 2, para que la entrada esté en Puerta en
   segundos y no al minuto). Las dos pueden pisarse: la cola reserva filas
   con skip locked y Puerta es idempotente por ref, así que no se duplica.

   Pide la cabecera x-barrido, el mismo secreto que barrer-pagos: sin ella
   cualquiera con la URL podría hacerle consultar a Puerta a discreción.

   Secrets: PUERTA_URL (https://<proyecto>.supabase.co de Puerta; si se
   carga con /functions/v1/ticketazo al final también anda, se recorta) y
   TICKETAZO_SECRETO (el que Puerta compara en x-ticketazo-secreto). Se
   cargan con scripts/secretos.py. */
const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-barrido",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (b: unknown, s = 200) =>
  new Response(JSON.stringify(b), { status: s, headers: { ...CORS, "Content-Type": "application/json" } });

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

const CLAVE   = Deno.env.get("BARRIDO_CLAVE") ?? "";
/* Las instrucciones de despliegue del lado Puerta dan la URL completa de la
   función y las de acá la base del proyecto. Se aceptan las dos: con la
   completa, sin este recorte, la llamada iba a /functions/v1/ticketazo
   dos veces seguidas. */
const PUERTA  = (Deno.env.get("PUERTA_URL") ?? "").trim().replace(/\/+$/, "")
  .replace(/\/functions\/v1\/ticketazo$/, "");
const SECRETO = Deno.env.get("TICKETAZO_SECRETO") ?? "";

/* El cron corta a los 20 s (pg_net). PLAZO_MS deja margen para cerrar el
   informe; cada llamada a Puerta tiene su propio tope para que un Puerta
   lento no se coma la corrida entera. Lo que no entra, entra al minuto. */
const PLAZO_MS = 15000, TOPE_PUERTA_MS = 7000, LOTE = 50, RONDAS = 4;
/* Puerta contesta 413 a más de 200 eventos por pedido de estados. Hoy son
   un puñado, pero la lista no tiene techo acá (todo espejo desde anteayer
   con una entrada ya enviada): sin partirla, el día que pase de 200 el
   paso de estados fallaría para siempre. */
const LOTE_ESTADOS = 100;

const msg = (e: unknown) => String((e as Error)?.message ?? e).slice(0, 300);

/* Lo que Puerta manda de la noche y del lugar desde su v5.9 (ver 0104): el
   club con su dirección y las listas, de donde sale el free cover. Se deja
   en UNA forma antes de pasarlo a la base, que lee solo esa:
       club:   { nombre, lugar, direccion, lat, lng, maps_url }
       listas: [{ nombre, orden, ingreso_hasta, registro_hasta_local }]
   ingreso_hasta es hasta qué hora entra gratis el anotado ("HH:MM:SS") y
   registro_hasta_local hasta cuándo uno se anota, "YYYY-MM-DD HH:MM" en
   hora de Bolivia: es lo que manda v5.9 por lista. eventos.lista_hasta de
   Puerta NO viene (v5.9 lo dejó afuera: allá no corta nada) y no se busca.
   Por qué acá y no en la base: el lado Puerta se escribió en paralelo y
   puede mandar el club anidado o en campos sueltos (club_lugar, …), y la
   lista como lista_tipos o con `hasta`. Aceptar las variantes en un solo
   lugar evita que un nombre de campo distinto deje a Bowie sin dirección
   sin que nada avise.

   Y se recorta a lo que la base usa. v5.9 manda por lista solo nombre,
   orden, ingreso_hasta y las registro_* (crudas y _local), todas estables;
   pero lista_tipos también tiene cupos, y si Puerta un día los sumara,
   cambiarían con cada anotado: moverían la huella del evento
   (puerta_evento.hash) y lo reaplicarían entero cada minuto por nada.

   Si Puerta no manda nada de esto (un Puerta sin v5.9), el evento pasa
   sin las claves y la base deja todo como estaba: lugar = nombre del
   organizador, sin dirección ni free cover. */
type Json = Record<string, unknown>;
const esObj = (v: unknown): v is Json => !!v && typeof v === "object" && !Array.isArray(v);
const vacio = (v: unknown) => v === undefined || v === null || v === "";

/* Hasta cuándo se anota uno en una lista, en hora de Bolivia y con día
   ("2026-10-10 22:00"). Vale la que Puerta arma (registro_hasta_local).
   Si un día viniera solo la cruda (registro_hasta, timestamptz en UTC: la
   de MADNESS/Invitados es "…T02:00:00+00:00"), se pasa acá con su zona —
   Bolivia es UTC−4 todo el año, sin horario de verano. Una hora sin zona
   que no sea la _local no se adivina: null, y la página dice "en lista".
   La base vuelve a rechazar cualquier cosa con zona (puerta_momento). */
const CON_ZONA = /(?:Z|[+-]\d{2}(?::?\d{2})?)$/i;
function horaBolivia(local: unknown, cruda: unknown): string | null {
  const l = typeof local === "string" ? local.trim() : "";
  if (/^\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}/.test(l) && !CON_ZONA.test(l)) {
    return l.slice(0, 16).replace("T", " ");
  }
  const c = typeof cruda === "string" ? cruda.trim() : "";
  if (!/^\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}/.test(c) || !CON_ZONA.test(c)) return null;
  const t = Date.parse(c.replace(" ", "T").replace(/([+-]\d{2})$/, "$1:00"));
  if (!Number.isFinite(t)) return null;
  return new Date(t - 4 * 3600_000).toISOString().slice(0, 16).replace("T", " ");
}

function normalizarEvento(ev: unknown): unknown {
  if (!esObj(ev)) return ev;
  const out: Json = { ...ev };

  const c: Json = esObj(ev.club) ? ev.club : {
    nombre: ev.club_nombre, lugar: ev.club_lugar, direccion: ev.club_direccion,
    lat: ev.club_lat, lng: ev.club_lng, maps_url: ev.club_maps_url,
  };
  const club = {
    nombre: c.nombre ?? null, lugar: c.lugar ?? null, direccion: c.direccion ?? null,
    lat: c.lat ?? null, lng: c.lng ?? null, maps_url: c.maps_url ?? c.mapa ?? null,
  };
  if (Object.values(club).some((v) => !vacio(v))) out.club = club;
  else delete out.club;

  const crudas = Array.isArray(ev.listas) ? ev.listas
    : Array.isArray(ev.lista_tipos) ? ev.lista_tipos : null;
  if (crudas) {
    out.listas = crudas
      .map((l: unknown) => typeof l === "string" ? { nombre: l } : l)
      .filter(esObj)
      .map((l: Json) => ({ nombre: l.nombre ?? null, orden: l.orden ?? null,
                           ingreso_hasta: l.ingreso_hasta ?? l.hasta ?? null,
                           registro_hasta_local: horaBolivia(l.registro_hasta_local, l.registro_hasta) }));
  } else {
    delete out.listas;
  }
  delete out.lista_tipos;
  return out;
}

/* Comparación en tiempo constante, la misma de pago-callback y liquidar:
   con `!==` la respuesta tarda distinto según cuántos caracteres del
   principio acertó quien prueba, y x-barrido es el mismo secreto que abre
   barrer-pagos. */
function igual(a: string, b: string) {
  if (a.length !== b.length) return false;
  let d = 0;
  for (let i = 0; i < a.length; i++) d |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return d === 0;
}

async function puerta(cuerpo: Record<string, unknown>, inicio: number) {
  const resta = PLAZO_MS - (Date.now() - inicio);
  if (resta < 1500) throw new Error("sin tiempo en esta corrida");
  const r = await fetch(`${PUERTA}/functions/v1/ticketazo`, {
    method: "POST",
    signal: AbortSignal.timeout(Math.min(TOPE_PUERTA_MS, resta)),
    headers: { "Content-Type": "application/json", "x-ticketazo-secreto": SECRETO },
    body: JSON.stringify(cuerpo),
  });
  const t = await r.text();
  let j: any = null;
  try { j = t ? JSON.parse(t) : null; } catch { j = null; }
  if (!r.ok) throw new Error(`Puerta ${r.status}: ${String(j?.motivo ?? j?.error ?? t).slice(0, 200)}`);
  if (!j || typeof j !== "object") throw new Error(`Puerta contestó algo que no es JSON: ${t.slice(0, 120)}`);
  return j;
}

type Fila = { id: number; ref: string; evento_id: string; code?: string;
              cliente?: string; precio?: number; fase_id?: string | null;
              forzar_precio?: boolean };

/* Una vuelta de la cola: tomar → mandar → registrar. Si Puerta no contesta,
   el lote entero vuelve a la cola con el error y espera creciente; si
   contesta pero se olvida de una ref, esa sola vuelve. Las filas tomadas
   SIEMPRE se registran: una que quedara 'tomado' esperaría dos minutos a
   que otra corrida la rescate. Una que Puerta rebotó por 'precio_distinto'
   vuelve a la cola con forzar_precio y sale en la ronda siguiente. */
async function vaciarCola(tipo: "entrada" | "anular", inicio: number) {
  const total = { tomadas: 0, hechos: 0, rechazados: 0, reintentos: 0, forzados: 0, anuladas_aca: 0 };
  for (let ronda = 0; ronda < RONDAS; ronda++) {
    if (Date.now() - inicio > PLAZO_MS - 1500) break;
    const lote: Fila[] = (await rpc("puerta_tomar_envios", { p_tipo: tipo, p_limite: LOTE })) ?? [];
    if (!lote.length) break;
    total.tomadas += lote.length;

    let resultados: Array<Record<string, unknown>>;
    try {
      const r = tipo === "entrada"
        ? await puerta({ accion: "entradas", entradas: lote.map((x) => ({
            ref: x.ref, evento_id: x.evento_id, code: x.code, cliente: x.cliente,
            precio: x.precio, fase_id: x.fase_id ?? null,
            ...(x.forzar_precio ? { forzar_precio: true } : {}) })) }, inicio)
        : await puerta({ accion: "anular", refs: lote.map((x) => x.ref) }, inicio);
      const porRef = new Map<string, any>(
        (Array.isArray(r.resultados) ? r.resultados : []).map((x: any) => [String(x?.ref), x]));
      resultados = lote.map((x) => {
        const p = porRef.get(x.ref);
        return p
          ? { id: x.id, resultado: p.resultado ?? null, puerta_id: p.puerta_id ?? null,
              motivo: p.motivo ?? null }
          : { id: x.id, resultado: "error", motivo: "Puerta no devolvió esta ref" };
      });
    } catch (e) {
      console.error(`puerta-sync: ${tipo} — ${msg(e)}`);
      resultados = lote.map((x) => ({ id: x.id, resultado: "error", motivo: msg(e) }));
    }

    const reg = await rpc("puerta_registrar_envios", { p_resultados: resultados });
    total.hechos += Number(reg?.hechos ?? 0);
    total.rechazados += Number(reg?.rechazados ?? 0);
    total.reintentos += Number(reg?.reintentos ?? 0);
    total.forzados += Number(reg?.forzados ?? 0);
    total.anuladas_aca += Number(reg?.anuladas_aca ?? 0);
    if (Number(reg?.rechazados ?? 0) > 0)
      console.error(`puerta-sync: Puerta rechazó ${reg.rechazados} ${tipo === "entrada" ? "entradas PAGADAS" : "anulaciones"} — ver puerta_envio estado 'rechazado'`);
    if (lote.length < LOTE && !Number(reg?.forzados ?? 0)) break;
  }
  return total;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ ok: false, motivo: "Usá POST." }, 405);
  if (!CLAVE || !igual(req.headers.get("x-barrido") ?? "", CLAVE))
    return json({ ok: false, motivo: "No." }, 403);
  /* Sin la dirección o sin el secreto de Puerta no se toma nada de la cola:
     tomar y no poder mandar solo le sumaría intentos y espera a cada fila. */
  if (!PUERTA || !SECRETO) {
    console.error("puerta-sync: faltan PUERTA_URL o TICKETAZO_SECRETO");
    return json({ ok: false, motivo: "Faltan PUERTA_URL o TICKETAZO_SECRETO." }, 500);
  }

  const inicio = Date.now();
  const cuerpo = await req.json().catch(() => ({}));
  const informe: Record<string, unknown> = { inicio: new Date(inicio).toISOString() };
  let fallos = 0;
  const paso = async (nombre: string, fn: () => Promise<unknown>) => {
    try { informe[nombre] = await fn(); }
    catch (e) {
      fallos++;
      informe[nombre] = { error: msg(e) };
      console.error(`puerta-sync: paso ${nombre} falló — ${msg(e)}`);
    }
  };

  let cfg: any;
  try { cfg = await rpc("puerta_estado_sync", {}); }
  catch (e) { return json({ ok: false, motivo: `sin configuración: ${msg(e)}` }, 500); }

  // El aviso inmediato de una compra: solo la cola de entradas.
  if (cuerpo?.solo === "envios") {
    await paso("entradas", () => vaciarCola("entrada", inicio));
    return json({ ok: fallos === 0, ...informe }, fallos ? 502 : 200);
  }

  await paso("eventos", async () => {
    /* Apagado: no se le pregunta nada a Puerta; la base saca de la venta los
       espejos que quedan por delante. Los pasos 2 a 4 siguen igual: lo ya
       cobrado tiene que llegar a la puerta aunque el espejo esté apagado. */
    if (!cfg?.activo) return await rpc("puerta_aplicar_eventos", { p_eventos: null, p_ventana: cfg?.ventana });
    const r = await puerta({ accion: "eventos", desde: cfg.ventana }, inicio);
    /* Sin lista no se aplica nada: puerta_aplicar_eventos cierra lo que no
       viene, y una respuesta rota cerraría todas las fechas. */
    if (!Array.isArray(r.eventos)) throw new Error("Puerta no mandó la lista de eventos");
    return await rpc("puerta_aplicar_eventos",
                     { p_eventos: r.eventos.map(normalizarEvento), p_ventana: cfg.ventana });
  });

  await paso("entradas", () => vaciarCola("entrada", inicio));

  await paso("estados", async () => {
    const eventos: string[] = Array.isArray(cfg?.estados) ? cfg.estados : [];
    if (!eventos.length) return { eventos: 0 };
    const entradas: unknown[] = [];
    for (let i = 0; i < eventos.length; i += LOTE_ESTADOS) {
      const r = await puerta({ accion: "estados", eventos: eventos.slice(i, i + LOTE_ESTADOS) }, inicio);
      if (!Array.isArray(r.entradas)) throw new Error("Puerta no mandó la lista de entradas");
      entradas.push(...r.entradas);
    }
    return { eventos: eventos.length,
             ...(await rpc("puerta_aplicar_estados", { p_entradas: entradas })) };
  });

  await paso("anulaciones", () => vaciarCola("anular", inicio));

  informe.ms = Date.now() - inicio;
  informe.fallos = fallos;
  await rpc("puerta_registrar_corrida", { p_informe: informe })
    .catch((e) => console.error(`puerta-sync: no se pudo guardar el informe — ${msg(e)}`));
  return json({ ok: fallos === 0, ...informe }, fallos ? 502 : 200);
});
