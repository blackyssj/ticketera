# Ticketera — vistas internas: administración, relacionador y puerta

**Fecha:** 2026-08-28 · **Estado:** aprobado en brainstorming, sin implementar
**Base:** [2026-08-27-ticketera-design.md](2026-08-27-ticketera-design.md) — bloque 1 desplegado y andando

Lo que falta del producto. La venta pública funciona en
`ticketera-coral.vercel.app`; no existe ninguna pantalla interna y `auth.users`
tiene cero filas.

---

## 1. La guardia cambia de lugar

Es la decisión que ordena todo lo demás.

| | Público | Staff |
|---|---|---|
| Quién | anónimo (`anon`) | autenticado |
| Guardia | **Edge Functions** con `service_role` | **RLS**, directo contra PostgREST |
| Por qué | no hay identidad que filtrar, así que filtra el servidor | la identidad ES el filtro: `organizador_id = mi_organizador()` |

El público necesita funciones porque no hay nada que lo identifique: sin ellas,
cualquier permiso a `anon` es un permiso a internet. El staff no: tiene sesión,
y las 9 policies por tenant ya están puestas y probadas. Meter Edge Functions
también del lado interno duplicaría cada validación en dos lugares, y el día que
se desincronicen gana la que nadie miró.

**Una sola excepción: crear usuarios necesita `service_role`.** Va por Edge
Function (`crear-usuario`), y es la única del lado interno.

---

## 2. Acceso

`usuario` + clave, sin correo. Mismo patrón que Puerta:
`signInWithPassword({ email: usuario + "@ticketera.local", password })`.

Se eligió sabiendo el costo: **sin correo no hay recuperación posible**. Si
alguien olvida la clave se la resetea un admin, siempre. A cambio, entra gente
que no usa correo — que en un boliche es la mitad del equipo.

`disable_signup: true` no lo estorba: bloquea `signUp`, no el login. Las cuentas
las crea un admin desde la pantalla de Equipo. La primera se crea por API.

**Los roles ya existen** en `perfiles.rol`: `admin`, `staff`, `rrpp`. Falta uno:
**`portero`**, para la puerta. Se agrega al `check` en su migración.

| Rol | Puede |
|---|---|
| `admin` | todo lo de su organizador, incluido crear usuarios |
| `staff` | ver y editar eventos, no toca usuarios |
| `rrpp` | solo lo suyo: su link, sus ventas, su comisión |
| `portero` | solo escanear en la puerta |

---

## 3. Administración

**Las tres vistas internas son UNA sola app** en `app/admin/`, dentro del mismo
proyecto de Vercel — queda en `/admin/`. Un deploy, un dominio, y la landing
pública no engorda: es otra página, no otro bundle.

El rol decide qué se ve, igual que en Puerta: el `admin` entra a todo, el `rrpp`
solo a su pantalla, el `portero` solo al escáner. **Eso es comodidad de
interfaz, no seguridad** — la garantía son las policies, porque el rol se puede
falsear en el navegador pero la fila de `perfiles` no.

### 3a — Eventos, entradas y publicación

Con esto el organizador deja de depender de que alguien escriba SQL.

1. **Entrar** — usuario, clave.
2. **Eventos** — lista con estado (borrador / publicado / cerrado) y lo
   recaudado. Crear y editar.
3. **Evento › Entradas** — los tipos y las fases, con precio y cupo **en el
   cruce**. Es la pantalla que más piensa: hay que dejar obvio que "General"
   cuesta 120 en Preventa y 150 en General sin que parezca un error. Se resuelve
   con una grilla de fases × tipos, no con dos listas separadas.
4. **Publicar** — pone el evento a la venta. No publica si no hay al menos una
   fase abierta y un tipo con precio: sin eso la landing responde
   `SIN_FASE` y el organizador no entiende por qué.

Todo esto es `select`/`insert`/`update` directo con la sesión del usuario. Cero
funciones nuevas.

### 3b — El editor de planimetría

**Mismo sistema de coordenadas que la vista pública**: porcentajes sobre el
lienzo, `x/y/w` tal cual están en la tabla. Cero traducción entre lo que edita
el organizador y lo que ve el comprador — si hubiera dos sistemas, el plano se
vería distinto de cada lado y nadie sabría cuál es el bueno.

- Arrastrar para mover, panel de propiedades al costado (etiqueta, categoría,
  precio, personas, planta).
- Ajuste a grilla, para que no queden mesas a medio píxel.
- Deshacer.
- **Guardado explícito, nunca automático.** Mover una mesa de un evento
  publicado le cambia el plano a quien está comprando en ese momento.
- **Una mesa `bloqueada`, `reservada` o `pagada` no se mueve ni se borra.** El
  editor la muestra anclada y dice por qué. Del lado de la base, un trigger lo
  garantiza: la interfaz es comodidad, el trigger es la garantía.

### 3c — Ventas y equipo

- **Evento › Ventas** — órdenes con su estado, entradas emitidas, mesas
  vendidas, y las que quedaron en `revision_manual` (monto que no coincidió),
  que es lo único que pide una decisión humana.
- **Equipo** — alta de usuarios y su rol. Única pantalla que llama a una Edge
  Function.

---

## 4. Relacionador

El diferencial contra Ticketeg, que **no tiene concepto de vendedor**: se buscó
`vendedor`, `seller`, `comision` en su bundle y aparecen cero veces.

**El link.** Cada relacionador tiene un slug propio; su link es
`/<organizador>/<evento>?r=<slug>`. La landing lo guarda y lo manda en
`crear-orden`; la función lo resuelve contra `perfiles` y lo escribe en
`ordenes.rrpp_id`, que ya existe y hoy está sin usar. **La atribución la resuelve
el servidor, no el navegador**: si viniera un `rrpp_id` del cliente, cualquiera
se atribuiría las ventas ajenas.

**La comisión es un monto fijo por entrada, no un porcentaje.** Esto no es una
preferencia: en Puerta la comisión estaba atada al precio y durante siete
eventos nadie lo notó porque con la manilla a 60 y 50/50 daba justo 15. HOLIDAY
PARTY salió a 70 y la comisión se fue sola a 17,50. Acá nace como dato:

```
perfiles.comision_entrada   numeric   -- acuerdo particular de la persona
eventos.comision_entrada    numeric   -- el default del evento
```

Prioridad al calcular: la de la persona, si no la del evento. Sin tercera opción
ni cuenta derivada del precio.

**Pantalla del relacionador:** su link con botón de copiar, sus ventas, y su
comisión acumulada. Nada más — no ve las ventas de los demás ni el total del
evento. Eso es una policy, no un `if` en el frontend.

---

## 5. Puerta

Lo más barato de los tres: el QR ya sale con el payload `EVT:<evento>:<code>`,
idéntico al de Bowie y BurTown.

**La validación es un `update` condicional**, el mismo patrón que la toma de
mesa:

```sql
update entradas set estado = 'usada', used_at = now(), portero_id = auth.uid()
 where evento_id = p_evento and code = upper(trim(p_code)) and estado = 'valida'
returning * into e;
```

Si vuelve fila, **este** escaneo la consumió. Si no vuelve, hay que averiguar
por qué y responder distinto: `usada` (con la hora del primer ingreso, para
poder discutirlo en la puerta) o `no_existe`. Preguntar primero y actualizar
después es una carrera: dos porteros escanean el mismo QR y los dos lo dan por
bueno.

**Modo filtro.** Rechaza sin consumir: la entrada queda válida y la persona ve
el mismo cartel que una entrada falsa. Sirve para no dejar entrar a alguien sin
quemarle el ticket. Es `marcar_filtro_entrada`, aparte de `validar_entrada`.

**Deshacer el ingreso.** `descheckin_entrada` devuelve la entrada a `valida`. En
la puerta se escanea de más y sin esto la única salida es tocar la base.

**Cámara.** `jsQR` sobre el video, igual que Puerta. Con búsqueda por código a
mano como respaldo: en la puerta de un boliche la cámara falla y la fila no
espera.

**Lo que la puerta necesita del bloque 1 y no tiene:** el rol `portero`, y las
tres funciones — `validar_entrada`, `marcar_filtro_entrada`,
`descheckin_entrada`. Ninguna existe todavía en esta base.

---

## 6. La pasarela, de punta a punta

Hoy `PASARELA=simulada`: el flujo entero corre y no cobra. Lo que cambia al
poner `v2pro` y por qué está armado así.

**Lo verificado del código de v2pro:**

- `solicitudpagos` tiene `so_extra1/2/3` libres → ahí viaja el `orden_id`. Sin
  tabla puente.
- `consulta_transaccion_v2.php` devuelve `so_estado` dado el `id_transaccion`
  más las credenciales del comercio.
- El callback (`notificaciones/<comercio_id>.php`) es un `curl`
  **fire-and-forget**: sin firma, sin reintento. Con 1xbet salieron **0 de 7
  aceptados**.

**Por eso el callback no es la fuente de verdad y no se le cree el contenido.**
Llega sin autenticar: quien lo mande podría ser cualquiera. Es un aviso de "andá
a mirar", nunca el dato.

**Los tres caminos a emitir, y ninguno confía en el otro:**

| Camino | Cuándo salva la venta |
|---|---|
| El comprador vuelve del pago (`estado-orden`) | el caso normal |
| El callback de la pasarela (`callback-pago`) | el comprador cerró la pestaña |
| El barrido (`vencer_ordenes` + consulta) | los dos anteriores fallaron |

`emitir_orden()` es idempotente por `client_key`, así que los tres pueden
llegar juntos y sale una sola emisión.

**Lo que falta construir para prender el cobro real:**

1. **`callback-pago`** — Edge Function pública que recibe el aviso de v2pro.
   Toma solo el `id_transaccion`, **descarta el resto del cuerpo**, consulta
   `consulta_transaccion_v2.php` y recién ahí llama a `emitir_orden()` con el
   monto que devolvió la pasarela. Hoy no existe.
2. **El job del barrido** — `vencer_ordenes()` existe pero no lo corre nadie.
   Cada 2 minutos, y las órdenes que vuelven en `a_confirmar` se consultan
   antes de anular: anular una vencida sin preguntar es cobrarle a alguien y no
   darle la entrada.
3. **Las credenciales del comercio** — `V2PRO_LLAVE`, `V2PRO_USUARIO`,
   `V2PRO_PASS`. Empezar por `1518` BeePlay Stage.
4. **Registrar la URL del callback** en el comercio, del lado de v2pro.

**El monto se compara siempre.** Si `monto_cobrado` no coincide con
`ordenes.total`, no se emite nada y la orden va a `revision_manual`. Emitir por
un monto distinto al cobrado no se deshace: la persona ya entró.

**Cuidado heredado:** el endpoint de consulta de la pasarela tiene una
debilidad conocida en el armado de su SQL. Mandando solo un UUID nuestro no la
tocamos, pero es superficie ajena que estaríamos usando. El detalle está en las
notas internas, fuera del repo.

---

## 7. En qué orden y qué deja cada bloque

| Bloque | Deja funcionando | Depende de |
|---|---|---|
| **4a** Acceso, eventos y entradas | El organizador arma y publica un evento solo | — |
| **4b** Editor de planimetría | Carga y edita sus mesas | 4a |
| **4c** Ventas y equipo | Ve lo vendido y da de alta a su gente | 4a |
| **5** Relacionador | Links con atribución y comisiones | 4c (necesita crear usuarios) |
| **6** Puerta | Escaneo y control de ingreso | 4c |
| **7** Pasarela real | Cobra de verdad | credenciales del comercio |

El 7 no depende de los otros: se puede prender apenas lleguen las credenciales.

---

## 8. Decisiones abiertas

1. **¿BeePay puede cobrarle a un organizador ajeno al grupo?** Sigue sin
   resolver desde el spec anterior. Legal, no técnica. No bloquea el código;
   bloquea vender afuera.
2. **~~¿La puerta necesita funcionar sin señal?~~ Resuelto: hay señal.** El
   escáner trabaja en línea contra `validar_entrada`. Queda anotado el costo de
   la decisión: si un evento futuro cae en un predio sin cobertura, el bloque 6
   no sirve tal cual y hay que agregarle caché de códigos, cola de ingresos y
   resolución de conflictos. Preguntarlo por evento, no asumirlo.
3. **¿Quién puede anular una entrada ya emitida?** Hoy `entradas.estado` admite
   `anulada` y nada la escribe. Hace falta cuando alguien pide reembolso.

---

## 9. Fuera de alcance

- Liquidación y reportes contables.
- Reventa o transferencia de entradas.
- Reembolsos automáticos: `revision_manual` deja la orden marcada, la plata se
  devuelve a mano.
- Multi-idioma.
