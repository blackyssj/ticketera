/* ══════════════════════════════════════════════════════════════════
   CSV para el Excel del contador.

   Vive aparte de admin.js por lo mismo que puerta.js: no es una pantalla,
   es una herramienta que usan varias. Y porque las tres decisiones que
   hay acá adentro son las tres formas conocidas de que un export salga
   mal sin que nadie se entere.

   ── 1. la fórmula que viene en el nombre del comprador ──

   Excel, Numbers y LibreOffice EJECUTAN el contenido de una celda que
   empieza con `=`, `+`, `-` o `@` — y también con tab o retorno de carro,
   que corren el arranque a lo que sigue. No es una curiosidad: los
   nombres de los compradores salen de un formulario PÚBLICO, cualquiera
   puede llamarse `=HYPERLINK("http://…","Hacé clic")` o
   `=cmd|'/c calc'!A0`, y el archivo lo abre el contador del boliche en su
   máquina. Se llama CSV injection y es la forma más barata que hay de
   pasar de un formulario de venta a la computadora de otra persona.

   Por eso todo campo que arranque con uno de esos caracteres sale con un
   apóstrofo adelante: `'=HYPERLINK(…)`. La celda queda como texto, se lee
   igual y no se ejecuta.

   La única excepción es un número puro (`-300` o `-300,50`): un menos
   seguido solo de dígitos es un número negativo, no una fórmula, y
   Excel lo muestra igual de las dos formas. Sin esa excepción cada monto
   negativo de la liquidación saldría como texto y no se podría sumar,
   que es exactamente para lo que el contador abre el archivo.

   Ojo con lo que NO es excepción: un teléfono `+591 700 12345` SÍ se
   neutraliza, y está bien que se neutralice. Excel evalúa `+591 700-12345`
   como una resta y muestra un número que no es el teléfono de nadie. El
   apóstrofo ahí no es una molestia: es lo que hace que el teléfono llegue
   entero.

   ── 2. el separador y el encoding ──

   Excel en español (es-BO, es-ES, es-AR) usa `;` como separador de lista,
   no `,`. Un archivo con comas se abre TODO en una sola columna y el que
   lo recibe tiene que ir a "Texto en columnas" — o pedirlo de nuevo por
   WhatsApp. Va `;`.

   Con `;` de separador, la coma queda libre para lo que en castellano es:
   el separador decimal. Los montos salen `4030,00`. Escritos `4030.00`,
   el Excel español los lee como texto o —peor, y en silencio— como
   403000.

   Y va BOM (EF BB BF) al principio. Sin BOM, Excel abre el CSV con la
   codificación de la máquina (Windows-1252) y "Áñez" llega como "Ã¡Ã±ez".
   El BOM es lo único que le dice a Excel "esto es UTF-8" al hacer doble
   clic, sin pasar por el asistente de importación.

   Fin de línea CRLF, que es lo que espera Excel.

   ── 3. el archivo tiene que estar completo ──

   Eso no se resuelve acá sino en quien arma las filas: las funciones de
   0040 paginan y dicen `total`, y los exportadores de admin.js juntan
   hasta llegar a ese total. Acá solo queda dicho para que no se pierda:
   un CSV con 1000 de 1400 filas es peor que no tener CSV, porque nadie
   lo nota y el contador cuadra mal.
   ══════════════════════════════════════════════════════════════════ */
(() => {
"use strict";

const SEP = ";";
const FIN = "\r\n";
const BOM = "\uFEFF";

/* Tab y los dos retornos entran a la lista porque corren el arranque de
   la celda: Excel los ignora al principio y evalúa lo que sigue. */
const PELIGRO = /^[=+\-@\t\r\n]/;
const NUMERO  = /^-?\d+(,\d+)?$/;

function campo(v) {
  let s = v === null || v === undefined ? "" : String(v);
  /* Los saltos de línea de adentro de un motivo se aplanan: un CSV los
     soporta entre comillas, pero medio Excel viejo y todo grep parten la
     fila ahí y el archivo pasa a tener filas que no existen. */
  s = s.replace(/\r\n|\r|\n/g, " ").replace(/\t/g, " ");
  let forzada = false;
  if (PELIGRO.test(s) && !NUMERO.test(s)) { s = "'" + s; forzada = true; }
  if (forzada || s.includes(SEP) || s.includes('"') || s !== s.trim())
    s = '"' + s.replace(/"/g, '""') + '"';
  return s;
}

/* Una fila vacía (`[]`) sale como línea en blanco. Es lo que separa los
   dos bloques del CSV de liquidación: primero la foto, después una línea
   por relacionador. */
const texto = filas => BOM + filas.map(f => f.map(campo).join(SEP)).join(FIN) + FIN;

/* ── los formatos ──
   Nada de toLocaleString acá: el archivo se abre en otra máquina, con
   otra configuración regional, y tiene que verse igual. Los tres
   formatos de abajo son los que el Excel español entiende sin ayuda. */
const bs  = n => Number(n || 0).toFixed(2).replace(".", ",");
const ent = n => String(Math.trunc(Number(n || 0)));

/* Bolivia entera está en UTC-4 y no tiene horario de verano. Se fija la
   zona a mano: si el que exporta está de viaje, la hora de ingreso de una
   manilla no puede cambiar de valor según dónde abrió el panel. */
const FH = new Intl.DateTimeFormat("es-BO", {
  timeZone: "America/La_Paz", day: "2-digit", month: "2-digit", year: "numeric",
  hour: "2-digit", minute: "2-digit", hour12: false });
const F = new Intl.DateTimeFormat("es-BO", {
  timeZone: "America/La_Paz", day: "2-digit", month: "2-digit", year: "numeric" });

const fh = t => t ? FH.format(new Date(t)).replace(", ", " ") : "";
/* Una fecha AAAA-MM-DD sin hora (eventos.fecha) es un día del calendario,
   no un instante: se le pega el mediodía de Bolivia para que ninguna zona
   la corra al día anterior. */
const f = d => d ? F.format(new Date(String(d).length === 10 ? d + "T12:00:00-04:00" : d)) : "";

/* El nombre del archivo lleva qué es y de qué evento, con la fecha del
   evento: en la carpeta de Descargas conviven los exports de tres
   fiestas y "compradores.csv" y "compradores (2).csv" no se distinguen
   sin abrirlos. */
function nombre(que, ev) {
  const limpio = s => String(s || "")
    .normalize("NFD").replace(/[\u0300-\u036f]/g, "")
    .toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "");
  return [que, limpio(ev && (ev.slug || ev.nombre)) || "evento",
          (ev && ev.fecha) || new Date().toISOString().slice(0, 10)].join("-") + ".csv";
}

/* La descarga en sí. El objectURL se suelta enseguida: si no, el Blob
   entero —que en un evento grande son megas— queda vivo hasta que se
   recarga la página. */
function bajar(nombreArchivo, filas) {
  const url = URL.createObjectURL(
    new Blob([texto(filas)], { type: "text/csv;charset=utf-8" }));
  const a = document.createElement("a");
  a.href = url;
  a.download = nombreArchivo;
  document.body.appendChild(a);
  a.click();
  a.remove();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
}

window.CSV = { texto, bajar, nombre, bs, ent, fh, f, campo };
})();
