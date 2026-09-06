/* liquidar — le paga al organizador lo que lleva vendido.

   La plata de las entradas entra por la pasarela y queda en el monedero del
   comercio de TICKETAZO. Desde ahí el liquidador de BeePay deposita a
   cualquier banco boliviano. Esta función es el puente entre la cuenta que
   ya sabía hacer la base (0039, 0052) y ese depósito.

   Tres pasos, en este orden y no en otro:
     1. `pedir_pago_organizador` CON EL TOKEN DE QUIEN LLAMA. La base decide
        si puede, si hay saldo y si hay cuenta cargada; nosotros no repetimos
        esa decisión acá. La fila nace en estado 'pedido'.
     2. El pedido al liquidador, con service_role. El clientRequestId es el id
        de esa fila: si esto se reintenta, del otro lado es el mismo pago.
     3. `confirmar_pago_organizador`, que sólo puede llamar service_role —
        marcar un pago como hecho no puede salir de una pantalla.

   Si el paso 2 falla, la fila queda en 'pedido' y sigue reservando saldo. Es
   a propósito: un pago que no sabemos si salió no puede liberar plata para
   que alguien la retire otra vez. Se resuelve mirándolo, no adivinando. */
const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
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

/* 1005 es el BCP y va por PROV; todo lo demás va por ACH, que además exige
   la ciudad. Es la misma regla que aplica el liquidador adentro; acá se
   repite sólo para mandar los campos que ACH necesita. */
const ES_BCP = (codigo: string) => String(codigo) === "1005";

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

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ ok: false, motivo: "Usá POST." }, 405);

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
  if (!H2H_KEY || !H2H_SECRET) {
    console.error("liquidar: faltan H2H_API_KEY / H2H_API_SECRET");
    return json({ ok: false, motivo: "Los pagos automáticos no están configurados." }, 500);
  }

  let pago: string | null = null;
  try {
    const { evento, monto } = await req.json();
    if (!evento) return json({ ok: false, motivo: "Falta el evento." }, 400);

    /* Con el token de quien llama: la base aplica puede_editar(), el tope de
       anticipo y el candado por evento. Un 401/403 de acá es la respuesta
       correcta y no hay que traducirla. */
    const pedido = await rpc("pedir_pago_organizador",
      { p_evento: evento, p_monto: monto ?? null }, token);
    if (!pedido?.ok) return json(pedido ?? { ok: false, motivo: "No se pudo pedir el pago." }, 409);

    pago = pedido.pago;
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
    // La extensión sólo la pide el BCP cuando el documento es CI.
    if (ES_BCP(b.banco_codigo) && b.documento_tipo === "CI" && b.documento_extension) {
      cuerpo.documentExtension = b.documento_extension;
    }
    // ACH no sale sin ciudad. El BCP va por PROV y no la usa.
    if (!ES_BCP(b.banco_codigo)) cuerpo.cityCode = b.ciudad_codigo;

    const r = await fetch(`${H2H}/api/h2h/on-demand/payouts`, {
      method: "POST",
      headers: { "Content-Type": "application/json",
                 "X-Api-Key": H2H_KEY, "X-Api-Secret": H2H_SECRET },
      body: JSON.stringify(cuerpo),
    });
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
        return json({ ok: false, pago, estado: "rechazado", motivo }, 409);
      }
      console.error(`liquidar: ${pago} quedó en duda — ${r.status} ${txt.slice(0, 200)}`);
      await rpc("confirmar_pago_organizador",
        { p_pago: pago, p_estado: "pedido", p_respuesta: resp ?? {},
          p_motivo: `Sin respuesta del liquidador (${r.status}). Verificar antes de reintentar.` });
      return json({ ok: false, pago, estado: "pedido", en_duda: true,
        motivo: "No pudimos confirmar el pago. Está registrado: revisalo antes de volver a intentar." }, 502);
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

    return json({ ok: true, pago, estado, monto: pedido.monto,
      motivo: estado === "aprobacion_manual"
        ? `Pedido ${pedido.monto} Bs. Por el monto, queda esperando aprobación manual.`
        : `Enviados ${pedido.monto} Bs a ${b.nombres} ${b.apellido}.` });
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
