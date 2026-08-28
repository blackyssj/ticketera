# Ticketera — diseño

**Fecha:** 2026-08-27 · **Estado:** aprobado en brainstorming, sin implementar
**Origen:** [2026-08-20-ticketera-traspaso.md](2026-08-20-ticketera-traspaso.md)

Ticketera multi-tenant con landing pública de autoservicio: el comprador entra
por un link, elige entradas o mesa, paga con BeePay y recibe su QR sin que nadie
de adentro lo cargue.

---

## 1. Decisiones

Las cinco preguntas abiertas del traspaso, resueltas:

| # | Pregunta | Decisión |
|---|---|---|
| 1 | ¿Quién es el cliente? | **Los tres** — boliches, productoras y promociones. Multi-tenant desde el día uno |
| 2 | ¿Cómo se cobra? | **Service fee al comprador**: `%` sobre el subtotal + fijo por transacción, con piso. Parámetros por organizador |
| 3 | ¿BeePay puede cobrarle a un tercero? | **Sin resolver.** Legal, no técnica. Ver §8 |
| 4 | ¿Base nueva o la misma? | **Nueva.** Puerta sigue viva aparte, sin migración |
| 5 | ¿Y si abandona el pago con una mesa tomada? | **Hold de 10 minutos sobre la orden**, estado `bloqueada` en la mesa, liberación perezosa en la lectura |

**Por qué el fee lo paga el comprador.** Al organizador se le dice "cobrás tu
precio limpio", que es lo que cierra la venta. El costo de la pasarela y nuestro
margen se funden en una sola línea visible en vez de dos descuentos en la misma
liquidación. Y el precio de lista no se mueve, que importa cuando el mismo evento
también vende en puerta.

**Por qué la fórmula lleva un fijo.** El costo de pasarela es **por transacción,
no por entrada**. Con un `%` puro, una compra de seis entradas cobraría seis veces
un costo que se pagó una vez, y un 7% sobre una entrada de 20 Bs no cubre ni el
procesamiento.

```
fee = max( round(subtotal × fee_pct) + fee_fijo_transaccion , fee_piso )
```

Default: `7% + 3 Bs, piso 5 Bs`.

**Por qué base nueva.** Meterle `organizador_id` a 43 tablas, 83 policies y 127
funciones vivas significa tocar producción en cada paso y arrastrar los cuatro
agujeros de seguridad del traspaso §4 a un producto con vitrina pública. La
migración de Bowie/BurTown al sistema nuevo es un proyecto aparte, si alguna vez
se decide.

---

## 2. Arquitectura

**Enfoque: SPA pública + Edge Functions. La anon key nunca escribe.**

| Quién | Autenticación | Puede |
|---|---|---|
| Público | ninguna (`anon`) | leer tres vistas del evento publicado. Cero escritura, cero `execute` |
| Staff del organizador | `authenticated` | lo suyo, acotado por `organizador_id` vía RLS |
| Nosotros | `service_role`, solo dentro de Edge Functions | todo. Nunca toca el navegador |

Toda escritura del público pasa por una Edge Function. El secreto del callback y
las credenciales del comercio viven en variables de entorno de esas funciones,
nunca en el bundle.

**Lo descartado y por qué:**

- *Landing servida por v2pro (PHP).* Reusaría `layout/<comercio_id>/layout.html`,
  pero el repo de v2pro **no es la fuente del deploy** — verificado: `1513` está
  en producción y no en el repo, `1486`/`1487` al revés. Construir un producto
  nuevo sobre un deploy que no se puede diferenciar es firmar el problema. Además
  tira el know-how de `app.js`, incluido `ticketImage()`.
- *RPC directo con `anon` ejecutando funciones `security definer`.* Es
  exactamente lo que causó los agujeros del traspaso §4. Esas funciones no pasan
  por RLS: un `where` olvidado es una fuga pública. Ya pasó con `v_stats_rrpp` —
  2.410 filas legibles sin login.

**Raíz del tenant: `organizadores`.** Toda tabla lleva `organizador_id not null`,
sin excepciones; la excepción es el olvido que después no se ve.

```
organizadores
  id, slug, nombre, activo
  fee_pct, fee_fijo_transaccion, fee_piso
  comercio_id                          -- el de v2pro: 1511, 1518, ...
```

URL pública: `/<slug-organizador>/<slug-evento>`. El slug del organizador no es
decorativo: sin él, dos organizadores no pueden tener un evento `halloween`. Para
el staff, `organizador_id` sale del JWT, **nunca** de un parámetro del cliente.

**Cuatro reglas heredadas, no negociables:**

1. Cada vista pública lleva su `alter view … set (security_invoker=on)`
   inmediatamente debajo del `create`, en la misma migración. `create or replace
   view` borra las reloptions.
2. Cambiar la firma de una función es `drop function` + `create`. Nunca `create
   or replace` con parámetro nuevo: crea una segunda firma y PostgREST responde
   "could not choose a candidate function".
3. Toda lectura de lista pagina. `db_max_rows` corta en 1000 sin avisar.
4. Ninguna función `security definer` es ejecutable por `anon`.

**Registro de cuentas cerrado** (`disable_signup: true`) desde la primera hora.
Los organizadores entran por invitación. Que la landing sea pública no significa
que crear cuentas lo sea.

---

## 3. Modelo de datos

Cuatro cosas de Puerta no sobreviven al público tal como están:

| Qué | Por qué rompe |
|---|---|
| `eventos.precio_manilla` — **un** precio por evento | Hacen falta General / VIP / Palco. `evento_fase` da precio en el tiempo, no por tipo |
| `entradas.rrpp_id not null` | Una venta pública no tiene relacionador |
| `entradas.cliente text` — solo nombre | Al comprador anónimo hay que **entregarle** el QR |
| No existe el concepto de compra | Cuatro entradas en un pago son cuatro filas sueltas: no hay dónde colgar el hold, la `client_key` ni el reintento del callback |

### Los dos ejes de precio

`evento_fase` (ventana temporal) se reusa entero. Se le suma `tipo_entrada`
(categoría), y precio y cupo pasan al cruce:

```
tipo_entrada    id, organizador_id, evento_id, nombre, orden, activo
fase_precio     fase_id, tipo_id, precio, cupo        -- PK compuesta
```

Puerta pone precio y cupo en la fase porque solo hay un tipo. Con dos tipos, ahí
ya no entran.

### La columna vertebral: `ordenes`

```
ordenes
  id, organizador_id, evento_id
  estado        pendiente | pagada | vencida | anulada | revision_manual
  client_key    uuid, índice único parcial
  expira_at     timestamptz                 -- el hold
  comprador_nombre, comprador_email, comprador_telefono
  subtotal, fee, total                      -- congelados al crear
  pago_ref                                  -- id_transaccion de v2pro
  rrpp_id       nullable                    -- si vino por link de relacionador
  ip_hash                                   -- para el límite por IP

orden_items
  orden_id, tipo_id, fase_id, mesa_id, cantidad, precio_unitario
  -- un ítem es de entrada O de mesa, nunca las dos:
  -- check ((tipo_id is not null) <> (mesa_id is not null))
```

**Una mesa emite entradas.** El ítem de mesa genera tantas filas en `entradas`
como manillas incluya la mesa, con el mismo `orden_id`. El comprador recibe N QR,
no un comprobante de mesa: la puerta escanea personas, no muebles.

**El hold es la orden, no la mesa.** `expira_at = now() + 10 minutos` para el
público. Las 3 horas de `ventana_reserva()` en Puerta son otra cosa — un
relacionador cerrando por WhatsApp — y se quedan como están.

Las mesas ganan el estado **`bloqueada`**, separado de `reservada`: el organizador
tiene que poder distinguir "un desconocido está pagando ahora" de "el relacionador
la comprometió".

**Las entradas se emiten recién con el pago confirmado.** Antes del callback no
existe ninguna fila en `entradas`. El stock lo retiene la orden pendiente, no un
QR fantasma que después hay que anular.

`entradas` se reusa con tres cambios: `rrpp_id` nullable, `orden_id` nuevo, y
`canal` (`publico` | `rrpp` | `puerta`). `rrpp_id is null` significando "venta
pública" es el `NULL = NULL` esperando a morder.

---

## 4. Flujo de checkout

Verificado contra el código de v2pro:

- `solicitudpagos` tiene **`so_extra1/2/3`** libres → ahí viaja el `orden_id`. No
  hace falta tabla puente.
- `consulta_transaccion_v2.php` devuelve `so_estado` dado `id_transaccion` más las
  credenciales del comercio. Es la vía de reconciliación.
- El callback (`notificaciones/<comercio>.php`) es un `curl` fire-and-forget: sin
  firma, sin reintento. Con 1xbet salieron **0 de 7 aceptados**.

Por eso: **el callback no es la fuente de verdad y no se le cree el contenido.**
Llega sin autenticar; el que lo mande podría ser cualquiera.

```
1. GET  /<org>/<evento>     → vistas públicas. Sin escritura.
2. POST ef-crear-orden      → valida cupo, calcula fee, inserta
                              orden(pendiente, expira_at=now()+10min),
                              marca la mesa bloqueada. Devuelve orden_id.
3. POST ef-iniciar-pago     → solicitud_pago.php con so_extra1=orden_id.
                              Devuelve la URL de cobro.
4a. callback → ef-callback-pago: NO lee el monto del body. Toma el
               id_transaccion, consulta consulta_transaccion_v2.php,
               y si so_estado=pagado → emitir(orden).
4b. retorno del comprador → ef-estado-orden → mismo emitir(orden).
4c. barrido cada 2 min → órdenes pendientes vencidas: consulta ANTES
               de anular. Una que pagó y no avisó nadie, se emite igual.
5. emitir(orden) → entradas + QR. Idempotente por client_key.
```

**Tres caminos llegan a `emitir()` y ninguno confía en el otro.** Si el callback
se pierde —y se pierde— lo salva el retorno del navegador; si el comprador cierra
la pestaña, lo salva el barrido.

**El barrido consulta antes de anular.** Anular una orden vencida sin preguntarle
a la pasarela es cobrarle a alguien y no darle la entrada.

**Entrega del QR.** `ticketImage()` dibuja en canvas del lado del cliente: cero
egress de imágenes generadas. Para sobrevivir a cerrar la pestaña, la orden tiene
URL propia con token largo, `/orden/<uuid>`, servida por Edge Function. Email
después; el link primero, que es lo que no falla.

---

## 5. Errores, concurrencia y abuso

**Sobreventa de cupo.** Contar y después insertar es una carrera. La orden se crea
dentro de una función que primero hace `select … from fase_precio where fase_id =
$1 and tipo_id = $2 for update`. Ese bloqueo serializa a todos los compradores de
ese tipo en esa fase, y recién después se cuenta. La contención queda en el grano
correcto.

**Doble reserva de mesa.** Sin bloqueo explícito: `update mesas set estado =
'bloqueada' where id = $1 and estado = 'disponible' returning id` es en sí mismo
la exclusión. Cero filas significa que alguien llegó primero. La condición viaja
**dentro** del `update`, nunca en un `if` previo.

**Disponibilidad correcta aunque el barrido esté caído.** La consulta de
disponibilidad cuenta pendientes con `expira_at > now()`, así que una orden
vencida deja de retener cupo en el instante en que vence, la haya barrido alguien
o no. El barrido libera la mesa visualmente y cierra la orden; la corrección no
depende de que corra. Importa porque en Puerta el barrido lo dispara un usuario
logueado al abrir la pantalla, y acá no hay ningún usuario garantizado —
`liberar_reservas_vencidas()` arranca con `if auth.uid() is null then raise`.

**Doble emisión.** `client_key` con índice único parcial, y el `insert` dentro de
un bloque que ante violación de unicidad devuelve la orden original en lugar de
fallar. Patrón probado en `migracion-v5.5.sql`. Detalle heredado:
`set_config(…, is_local => true)` se revierte al capturar una excepción; hay que
reaplicarlo después de cada `exception when others`.

**Monto que no coincide.** Si `monto_cobrado` difiere de `ordenes.total`, no se
emite nada y la orden pasa a `revision_manual`. Emitir por un monto distinto al
cobrado es un error que después no se deshace, porque la persona ya entró.

**Abuso desde afuera.** Hay que asumir que alguien va a intentar bloquear las 40
mesas de un evento con un script. Tres frenos, en orden de costo:

1. Tope de entradas por orden, configurable por evento, default 10.
2. Máximo 5 órdenes pendientes vivas por IP.
3. El hold de 10 minutos, que acota el daño de lo que pase los dos anteriores.

CAPTCHA queda anotado para cuando haya abuso real: agrega fricción al comprador
legítimo y los tres frenos cubren el caso previsible.

**Qué no ve el público, nunca.** `ordenes` y `entradas` no tienen `grant` alguno
al rol `anon`. La página `/orden/<uuid>` la sirve una Edge Function, **no una
vista**: si mañana alguien hace `create or replace view` y se lleva puesto el
`security_invoker`, una vista expondría todas las compras del sistema. Una Edge
Function no tiene esa forma de fallar.

Las vistas públicas exponen tres cosas: el evento publicado, sus tipos y precios
vigentes, y la disponibilidad como **número agregado**. Nunca un nombre de
comprador, nunca el ocupante de una mesa.

---

## 6. Verificación

**Invariantes** — bloques SQL que fallan la migración si no se cumplen. Son más
valiosos que cualquier test de caso, porque los errores caros de Puerta fueron
todos de la misma familia:

1. Ninguna vista de `public` sin `security_invoker=on` en sus `reloptions`.
2. `anon` no ejecuta ninguna función ni escribe ninguna tabla.
3. Ninguna función con dos firmas vivas.
4. Toda tabla del modelo con `organizador_id not null`.

La 1 y la 3 son las trampas del traspaso §5 convertidas en algo que grita solo.

**Pruebas de flujo**, patrón `TEST_OK` / `TEST_FAIL` en transacción, como en
`docs/superpowers/plans/2026-08-15-barra-bloque1-pos.md`:

| Qué se prueba | Cómo falla si está mal |
|---|---|
| Última butaca, dos órdenes concurrentes | 2 órdenes en vez de 1 |
| Segunda orden sobre mesa ya bloqueada | la mesa termina con dos dueños |
| `emitir()` dos veces con la misma `client_key` | 2 entradas, 1 pago |
| Orden vencida deja de retener cupo **sin correr el barrido** | el evento se ve agotado y no lo está |
| `monto_cobrado` ≠ `total` | emite por un monto que no se cobró |
| Fee `7% + 3`, piso 5 | cobra de menos en entradas baratas |
| El barrido consulta antes de anular | anula una orden que sí pagó |

La concurrencia se prueba con dos sesiones y `pg_sleep` entre el `select for
update` y el `insert`. Un test secuencial de una carrera no prueba nada.

**La pata del pago se prueba contra el comercio `1518` BeePlay Stage**, que ya
existe. Nada de mocks para el camino feliz: el punto entero de §4 es que el
callback se pierde en producción, y eso solo se ve contra la pasarela real.

**Los tests primero.** Cada invariante se escribe y se lo ve fallar antes de que
exista la tabla que lo satisface.

---

## 7. Prototipo

`ticketera/demo/index.html` — landing pública con marca **Amstel Ferial**, sin
backend: entradas por fase con cupo, planimetría de dos plantas donde cada mesa es
una chapa (`mesas.x/y/w` reales), los cuatro estados de mesa, el fee de servicio
como línea visible, y el hold de 10 minutos con vencimiento que libera la
selección. Sirve para discutir el flujo, no es código de producción.

Se sirve local (`.claude/launch.json`, puerto 4173) y **no se publica**: una página
con marca ajena y botón de pago, colgada en una URL, funciona como la venta real
aunque diga demo.

---

## 8. Supuestos y riesgos

**Supuesto que bloquea el negocio, no el código.** El diseño asume que BeePay
puede procesar cobros de un organizador ajeno al grupo. Si la respuesta legal es
no, todo lo de acá sigue funcionando para organizadores propios; lo que no se
puede es vender el producto afuera. Resolver antes de prometerle nada a un
cliente externo.

**Cupo de Supabase.** El plan free permite dos proyectos activos y hoy
`sitcom-cafe` y `barra-demo` se turnan. Este sería el tercero: o se pausa uno, o
esto arranca pagando.

**Superficie ajena que estaríamos usando.** `consulta_transaccion_v2.php:25` arma
el SQL interpolando la variable directo en el string. Mandando solo un UUID
nuestro en `so_extra1` no lo tocamos, pero queda anotado. No se arregla en este
proyecto.

**Deuda heredada que no se hereda.** Los cuatro agujeros del traspaso §4
(`v_stats_rrpp` sin `security_invoker`, signup abierto, bucket `comprobantes`
público y listable, `SUPABASE_PAT` sin rotar) son de Puerta y **no se arrastran**
acá porque la base es nueva. Siguen abiertos en Puerta y siguen pendientes.

---

## 9. Fuera de alcance

- Migrar Bowie/BurTown al sistema nuevo.
- Reventa o transferencia de entradas.
- Planimetría dibujable por el organizador: las mesas se cargan por CSV o a mano.
- App de puerta nueva: el escaneo reusa el modelo de Puerta, no se rediseña.
- Facturación fiscal.
