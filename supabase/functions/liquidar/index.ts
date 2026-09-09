/* liquidar — le paga al organizador lo que lleva vendido.

   La plata de las entradas entra por la pasarela y queda en el monedero del
   comercio de TICKETAZO. Desde ahí el liquidador de BeePay deposita a
   cualquier banco boliviano. Esta función es el puente entre la cuenta que
   ya sabía hacer la base (0039, 0052) y ese depósito.

   ── dos formas de entrar, un solo lugar donde sale la plata ──

   1. A MANO. Alguien aprieta "Pagar" en el panel y llega con su token.
      La base decide con `pedir_pago_organizador` si puede, si hay saldo y
      si hay cuenta cargada; nosotros no repetimos esa decisión acá.

   2. SOLO. El cron llama con la cabecera compartida y sin cuerpo. Recorre
      `eventos_a_pagar()` —los organizadores que tienen el automático
      puesto y hoy pasan su mínimo— y usa `pedir_pago_auto` para cada uno.

   Los dos caminos terminan en la MISMA función `enviar()`. Tener dos
   copias del pedido al liquidador es cómo una de las dos se queda sin el
   manejo del 5xx, y esa es justo la rama que decide si una plata que
   quizás salió vuelve a quedar disponible para que la retiren de nuevo.

   El orden es siempre el mismo y no otro:
     1. la fila nace en 'pedido' (la base, con candado por evento)
     2. el pedido al liquidador, con service_role. El clientRequestId es
        el id de esa fila: si esto se reintenta, del otro lado es el mismo
        pago y no se paga dos veces.
     3. `confirmar_pago_organizador`, que sólo puede llamar service_role —
        marcar un pago como hecho no puede salir de una pantalla.

   Si el paso 2 falla con 5xx, la fila queda en 'pedido' y sigue reservando
   saldo. Es a propósito: un pago que no sabemos si salió no puede liberar
   plata para que alguien la retire otra vez. Se resuelve mirándolo, no
   adivinando.                                                            */
const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-auto",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (b: unknown, s = 200) =>
  new Response(JSON.stringify(b), { status: s, headers: { ...CORS, "Content-Type": "application/json" } });

const SB  = Deno.env.get("SUPABASE_URL")!;
const KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const H = { apikey: KEY, Authorization: `Bearer ${KEY}`, "Content-Type": "application/json" };

/* El liquidador. La URL por defecto es la de producción; las llaves NO
   tienen default a propósito: sin ellas la función se niega a hacer nada en
   vez de intentar un pago sin identificarse. */
const H2H        = Deno.env.get("H2H_URL") ?? "https://admin.justbeesolutions.com";
const H2H_KEY    = Deno.env.get("H2H_API_KEY") ?? "";
const H2H_SECRET = Deno.env.get("H2H_API_SECRET") ?? "";

/* La llave del cron. Sin ella el modo automático no se abre: contesta 503.
   Una puerta que manda plata sola no puede depender de que alguien se
   acuerde de cargar un secret. */
const AUTO_CLAVE = Deno.env.get("AUTO_CLAVE") ?? "";

/* Cuántos pagos como mucho por corrida. El cron vuelve en quince minutos;
   lo que no entró en esta tanda sale en la siguiente. Sin tope, una base
   con veinte eventos vencidos deja la función corriendo hasta el timeout y
   los últimos quedan a medio camino. */
const TOPE_POR_CORRIDA = 10;

/* 1005 es el BCP y va por PROV; todo lo demás va por ACH, que además exige
   la ciudad. Es la misma regla que aplica el liquidador adentro; acá se
   repite sólo para mandar los campos que ACH necesita. */
const ES_BCP = (codigo: string) => String(codigo) === "1005";

/* Comparación en tiempo constante, igual que en pago-callback: un `===`
   corta en el primer carácter distinto y esa diferencia, repetida, deja
   adivinar el secreto de a un carácter. */
function igual(a: string, b: string) {
  if (a.length !== b.length) return false;
  let d = 0;
  for (let i = 0; i < a.length; i++) d |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return d === 0;
}

async function rpc(nombre: string, cuerpo: unknown, token?: string) {
  const r = await fetch(`${SB}/rest/v1/rpc/${nombre}`, {
    method: "POST",
    headers: token
      ? { apikey: KEY, Authorization: `Bearer ${token}`, "Content-Type": "application/json" }
      : H,
    body: JSON.stringify(cuerpo),
  });
  const t = await r.text();
  const j = t ? JSON.parse(t) : null;
  if (!r.ok) throw new Error(j?.message ?? j?.hint ?? t);
  return j;
}

type Salida = { cuerpo: Record<string, unknown>; http: number };

/* El pedido al liquidador y lo que se anota según cómo conteste. Recibe la
   fila ya creada: quién la creó —una persona o el cron— acá no importa, y
   eso es justamente lo que permite que haya un solo camino. */
async function enviar(pedido: any, evento: string): Promise<Salida> {
  const pago = pedido.pago;
  const b = pedido.beneficiario;

  const cuerpo: Record<string, unknown> = {
    clientRequestId: pago,
    amount: Number(pedido.monto),
    currency: "BOB",
    bankCode: b.banco_codigo,
    accountNumber: b.cuenta,
    firstNames: b.nombres,
    firstLastName: b.apellido,
    documentType: b.documento_tipo,
    documentNumber: b.documento_numero,
    firstDetail: `TICKETAZO ${String(evento).slice(0, 8)}`,
    /* A dónde avisar cuando el banco termine. Va en cada pedido además de
       estar registrada del lado del liquidador: si algún día alguien toca
       esa configuración, el pago sigue sabiendo a dónde contestar. Tiene
       que ser la MISMA URL registrada, porque de eso depende que el
       liquidador le adjunte la cabecera compartida. */
    callbackUrl: `${SB}/functions/v1/pago-callback`,
  };
  /* El segundo apellido va separado, no pegado al primero: el banco
     compara campo por campo y devuelve la transferencia si no coincide.
     Se manda sólo si lo hay — una empresa con NIT no tiene ninguno. */
  if (b.apellido2) cuerpo.secondLastName = b.apellido2;

  /* La extensión la EXIGE el liquidador para el BCP con carnet, y lo
     valida antes de hablar con el banco. La cuenta no se puede guardar sin
     ella (0059), así que llegar acá sin extensión sería una cuenta cargada
     antes de esa migración: se manda igual y el 4xx dice qué falta. */
  if (ES_BCP(b.banco_codigo) && b.documento_tipo === "CI" && b.documento_extension) {
    cuerpo.documentExtension = b.documento_extension;
  }
  // ACH no sale sin ciudad. El BCP va por PROV y no la usa.
  if (!ES_BCP(b.banco_codigo)) cuerpo.cityCode = b.ciudad_codigo;

  let r: Response;
  try {
    r = await fetch(`${H2H}/api/h2h/on-demand/payouts`, {
      method: "POST",
      headers: { "Content-Type": "application/json",
                 "X-Api-Key": H2H_KEY, "X-Api-Secret": H2H_SECRET },
      body: JSON.stringify(cuerpo),
    });
  } catch (err) {
    /* Ni siquiera se pudo preguntar. Como el 5xx: queda en duda y sigue
       reservando, porque el pedido pudo haber llegado igual. */
    const msg = String((err as Error).message ?? err);
    console.error(`liquidar: ${pago} no se pudo mandar — ${msg}`);
    await rpc("confirmar_pago_organizador",
      { p_pago: pago, p_estado: "pedido", p_respuesta: {},
        p_motivo: `No se pudo hablar con el liquidador: ${msg}` }).catch(() => {});
    return { http: 502, cuerpo: { ok: false, pago, estado: "pedido", en_duda: true,
      motivo: "No pudimos confirmar el pago. Está registrado: revisalo antes de reintentar." } };
  }

  const txt = await r.text();
  let resp: any = null;
  try { resp = txt ? JSON.parse(txt) : null; } catch { resp = { crudo: txt.slice(0, 400) }; }

  if (!r.ok) {
    /* Un 4xx es del pedido —cuenta mal escrita, saldo insuficiente— y no
       se va a arreglar reintentando: se marca rechazado y el saldo vuelve.
       Un 5xx o un timeout es del otro lado: la fila queda en 'pedido',
       reservando, porque el pago PODRÍA haber salido. */
    const motivo = resp?.message ?? resp?.error ?? `El liquidador respondió ${r.status}.`;
    if (r.status >= 400 && r.status < 500) {
      await rpc("confirmar_pago_organizador",
        { p_pago: pago, p_estado: "rechazado", p_respuesta: resp ?? {}, p_motivo: motivo });
      return { http: 409, cuerpo: { ok: false, pago, estado: "rechazado", motivo } };
    }
    console.error(`liquidar: ${pago} quedó en duda — ${r.status} ${txt.slice(0, 200)}`);
    await rpc("confirmar_pago_organizador",
      { p_pago: pago, p_estado: "pedido", p_respuesta: resp ?? {},
        p_motivo: `Sin respuesta del liquidador (${r.status}). Verificar antes de reintentar.` });
    return { http: 502, cuerpo: { ok: false, pago, estado: "pedido", en_duda: true,
      motivo: "No pudimos confirmar el pago. Está registrado: revisalo antes de volver a intentar." } };
  }

  /* Pasado el umbral, el liquidador no lo manda solo: queda esperando que
     alguien lo apruebe. No es un error, pero tampoco es "pagado", y la
     pantalla tiene que poder decir la diferencia. */
  const estadoH2H = String(resp?.status ?? resp?.state ?? "").toUpperCase();
  const estado = estadoH2H.includes("PENDING_BATCH_APPROVAL") ? "aprobacion_manual" : "enviado";
  await rpc("confirmar_pago_organizador",
    { p_pago: pago, p_estado: estado,
      p_referencia: String(resp?.id ?? resp?.transactionId ?? resp?.payoutId ?? ""),
      p_respuesta: resp ?? {} });

  return { http: 200, cuerpo: { ok: true, pago, estado, monto: pedido.monto,
    motivo: estado === "aprobacion_manual"
      ? `Pedido ${pedido.monto} Bs. Por el monto, queda esperando aprobación manual.`
      : `Enviados ${pedido.monto} Bs a ${b.nombres} ${b.apellido}.` } };
}

/* ── el modo automático ────────────────────────────────────────────
   Una corrida no se corta porque un evento haya fallado: el que falló ya
   quedó anotado con su motivo, y frenar ahí dejaría sin cobrar a todos
   los que venían atrás por un problema que no es de ellos. */
async function corridaAutomatica(): Promise<Response> {
  if (!AUTO_CLAVE) {
    console.error("liquidar: falta AUTO_CLAVE, el modo automático no se abre");
    return json({ ok: false, motivo: "No configurado." }, 503);
  }
  const lista = await rpc("eventos_a_pagar", {});
  const pendientes = (lista?.eventos ?? []).slice(0, TOPE_POR_CORRIDA);
  const hechos: unknown[] = [];

  for (const it of pendientes) {
    try {
      const pedido = await rpc("pedir_pago_auto", { p_evento: it.evento });
      /* Que no se pueda pedir NO es una falla que valga la pena gritar: el
         caso normal es que entre la lista y esta línea la plata dejó de
         alcanzar, o alguien apagó el interruptor. */
      if (!pedido?.ok) { hechos.push({ evento: it.evento, ok: false, motivo: pedido?.motivo }); continue; }
      const r = await enviar(pedido, it.evento);
      hechos.push({ evento: it.evento, ...r.cuerpo });
    } catch (err) {
      const msg = String((err as Error).message ?? err);
      console.error(`liquidar auto: ${it.evento} falló — ${msg}`);
      hechos.push({ evento: it.evento, ok: false, motivo: msg });
    }
  }

  const pagados = hechos.filter((h: any) => h.ok).length;
  if (pagados) console.log(`liquidar auto: ${pagados} de ${pendientes.length} mandados`);
  return json({ ok: true, candidatos: (lista?.eventos ?? []).length,
                intentados: pendientes.length, pagados, detalle: hechos });
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ ok: false, motivo: "Usá POST." }, 405);

  if (!H2H_KEY || !H2H_SECRET) {
    console.error("liquidar: faltan H2H_API_KEY / H2H_API_SECRET");
    return json({ ok: false, motivo: "Los pagos automáticos no están configurados." }, 500);
  }

  /* El cron entra por acá y no trae sesión de nadie. Se mira ANTES del
     token: si trae la llave del cron, no hay persona que verificar. */
  const auto = req.headers.get("x-auto");
  if (auto !== null) {
    if (!AUTO_CLAVE || !igual(auto, AUTO_CLAVE)) {
      console.warn("liquidar: rechazado, cabecera automática incorrecta");
      return json({ ok: false, motivo: "No autorizado." }, 401);
    }
    return await corridaAutomatica();
  }

  const token = /^Bearer\s+(.+)$/i.exec(req.headers.get("Authorization") ?? "")?.[1]?.trim();
  if (!token) return json({ ok: false, motivo: "Entrá de nuevo: no llegó tu sesión." }, 401);
  /* Que sea un token de PERSONA, no la anon key: la reja del gateway acepta
     cualquier JWT firmado por el proyecto, y la anon key es uno. Se le
     pregunta a /auth/v1/user, igual que en `equipo`. El rol no se mira acá
     —de eso se encarga puede_editar() adentro de la base— pero un token que
     no es de nadie tiene que morir antes de tocar una tabla. */
  const quien = await fetch(`${SB}/auth/v1/user`, {
    headers: { apikey: KEY, Authorization: `Bearer ${token}` },
  }).then((r) => (r.ok ? r.json() : null)).catch(() => null);
  if (!quien?.id) return json({ ok: false, motivo: "Tu sesión venció. Entrá de nuevo." }, 401);

  let pago: string | null = null;
  try {
    const { evento, monto, plataforma } = await req.json();
    if (!evento) return json({ ok: false, motivo: "Falta el evento." }, 400);

    /* Dos puertas para el mismo trámite. `pedir_pago_organizador` es la del
       cliente girándose a sí mismo (guardia: puede_editar sobre SU
       organizador). `pedir_pago_plataforma` es la de TICKETAZO girándole a
       un cliente sin entrar con sus credenciales (guardia: es_plataforma).

       Quién puede usar cuál lo decide la BASE, no esta bandera: las dos
       funciones corren con el token de quien llama y tienen su propia
       guardia adentro. Mandar `plataforma: true` sin ser operador no abre
       nada, devuelve "Sin permiso". La bandera acá sólo elige a qué puerta
       tocar. */
    const fn = plataforma === true ? "pedir_pago_plataforma" : "pedir_pago_organizador";

    /* Con el token de quien llama: la base aplica la guardia, el tope de
       anticipo y el candado por evento. Un 401/403 de acá es la respuesta
       correcta y no hay que traducirla. */
    const pedido = await rpc(fn, { p_evento: evento, p_monto: monto ?? null }, token);
    if (!pedido?.ok) return json(pedido ?? { ok: false, motivo: "No se pudo pedir el pago." }, 409);

    pago = pedido.pago;
    const r = await enviar(pedido, evento);
    return json(r.cuerpo, r.http);
  } catch (err) {
    const msg = String((err as Error).message ?? err);
    console.error(`liquidar falló: ${msg}`);
    if (pago) {
      await rpc("confirmar_pago_organizador",
        { p_pago: pago, p_estado: "pedido", p_respuesta: {},
          p_motivo: `Se cortó en el medio: ${msg}` }).catch(() => {});
      return json({ ok: false, pago, estado: "pedido", en_duda: true,
        motivo: "Se cortó en el medio. El pago quedó registrado: revisalo antes de reintentar." }, 500);
    }
    return json({ ok: false, motivo: msg }, 500);
  }
});
