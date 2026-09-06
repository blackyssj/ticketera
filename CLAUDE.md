# TICKETAZO — cómo se trabaja acá

Ticketera multi-tenant boliviana, **en producción y vendiendo entradas reales**.
Antes de tocar algo, asumí que hay plata de verdad del otro lado.

- Sitio: https://ticketazo.com.bo · Panel: https://ticketazo.com.bo/admin
- Supabase `mjotxzcddhqqpuhkcetl` (sa-east-1), organización TICKETAZO
- Vercel: equipo `ticketazo`, proyecto `ticketera`, Root Directory `app`
- 51 migraciones · 13 Edge Functions · sin build, sin framework

## Las cuatro reglas que no se rompen

**1. `anon` no tiene un solo permiso.** No lee tablas, no escribe, no ejecuta
funciones. Todo lo del público pasa por una Edge Function con `service_role`.
Por eso la anon key puede vivir en `app/config.js`: sola no abre nada.

**2. Comprador y staff comparten el rol `authenticated`.** Toda función SQL
ejecutable por `authenticated` tiene que decidir por rol adentro
(`mi_organizador()`, `puede_editar()`, `es_portero()`, `auth.uid()`) o quedar
sólo para `service_role`. Un revisor encontró `emitir_orden` abierta: un
comprador podía emitirse entradas sin pagar. Después de cualquier migración que
cree funciones:

```sql
select * from chequeo_funciones_sin_guardia();  -- tiene que devolver vacío
```

**3. Las migraciones son la única fuente de verdad.** Nada de cambios a mano en
el panel de Supabase: ni tablas, ni funciones, ni crons. Si no está en
`supabase/migrations/`, no existe. Esto ya nos mordió — el cron `barrer_pagos`
vivió cuatro meses sólo en la base, y una reconstrucción desde el repo habría
quedado sin el trabajo que rescata al comprador que pagó y no volvió.

**4. Ningún secreto en el repo ni en una migración.** Los secrets de las
funciones van con `scripts/secretos.py` (toma un ARCHIVO, nunca el valor por
argumento: el argv es público en la máquina). Lo que una migración necesite leer
va en el vault: `select vault.create_secret('<valor>', '<nombre>')`.

## Cómo se despliega

**Front:** `git push origin main`. Vercel construye solo. Cada rama tiene su URL
de vista previa, así que probá ahí antes de mergear.

**Edge Functions:** no viajan con el push.

```bash
python3 scripts/desplegar-funciones.py evento crear-orden   # o sin argumentos, todas
```

**Migraciones:** una por una, en orden, y verificá el resultado.

```bash
python3 scripts/sql.py supabase/migrations/00XX_lo_que_sea.sql
```

`sql.py` toma un **archivo**, no una cadena. Para una consulta suelta, escribila
a un archivo temporal primero.

## Lo que necesitás para trabajar

Un PAT de Supabase tuyo (Account Settings → Access Tokens) en `~/.supabase_pat`.
Con eso andan todos los scripts. No compartas el de otro: si algo sale mal,
conviene saber quién fue.

## Estilo

- **HTML, CSS y JS planos.** Sin build, sin framework, sin CDN salvo Google
  Fonts. Si te dan ganas de sumar una dependencia, casi siempre hay una forma
  más corta sin ella.
- **Los comentarios explican el POR QUÉ, no el qué**, en español rioplatense.
  Mirá cualquier migración: cuentan qué problema resuelven y qué pasaría si se
  hiciera de la forma obvia. Esa es la vara.
- **La copia de la interfaz es en voseo** ("Entrá", "Guardá", "Poné tu nombre").
- Cambiaste un `.js` o un `.css` de `app/`? Subí el `?v=` en el HTML que lo
  carga, o el navegador sirve el viejo.

## Trampas conocidas

- **El certificado de BCP vence cada año** (el próximo, ~septiembre de 2027) y
  tumba los cobros por QR de todos los comercios. Síntoma: imagen rota en el
  checkout y 403 en `qr_log`. Ver `beepay-certificado-bcp` en las notas.
- **Órdenes simuladas:** `pago_ref` que empieza con `SIM-` son de la pasarela en
  modo prueba. Cuentan en el bruto del evento pero no habilitan retiros.
- **Storage sirve `no-cache`** aunque el objeto tenga `max-age`. Revalida por
  etag, así que la mejora grande está igual.
- **La función `evento` manda `fecha` y `hora_inicio` crudos** además de
  `fecha_txt`. Usá los crudos; el texto no trae año.
- **Los pagos de 4.000 Bs o más** al organizador quedan en aprobación manual del
  lado del liquidador. No es un error.

## Antes de decir que algo anda

Probalo contra producción, no contra tu cabeza. Los invariantes corren solos y
no escriben nada:

```bash
python3 scripts/sql.py supabase/tests/invariantes.sql
python3 scripts/sql.py supabase/tests/policies.sql
```

Si creaste datos de prueba en la base, **borralos y decilo**. Nunca borres
órdenes pagadas ni entradas de nadie.

## Dónde está el resto

`docs/diseno.md` (decisiones de producto), `docs/diseno-vistas-internas.md`
(panel, relacionador, puerta), y el README para la estructura de carpetas.
