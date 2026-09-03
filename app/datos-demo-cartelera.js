/* ══════════════════════════════════════════════════════════════════
   La cartelera de demostración

   Existe por una razón comercial: con un solo evento en venta, la portada
   es honesta pero no muestra lo que la ticketera ES. El que la mira no ve
   una cartelera, ve una página con una entrada. Esto la llena para poder
   enseñarla.

   Vive DETRÁS de `?demo=1` y nunca toca la base. Los eventos de acá no se
   pueden comprar y no los ve nadie que no tenga el link con el parámetro:
   meter eventos falsos en la cartelera real —donde ahora mismo hay gente
   comprando— es la clase de atajo que termina con alguien pagando una
   entrada que no existe.

   Ninguno tiene flyer, y está bien: la tarjeta ya sabe dibujar un afiche
   cuando no hay imagen, con el día en grande y el nombre a tamaño de
   cartel. Lo único que se agrega es el color del papel, para que la pared
   no sean nueve carteles idénticos. En la cartelera de verdad ese lugar lo
   ocupa el flyer que cada organizador ya publicó en redes.
   ══════════════════════════════════════════════════════════════════ */
window.DEMO_CARTELERA = (() => {
  /* En mayúsculas porque así los manda la Edge Function que arma la
     cartelera de verdad, y la demo no puede verse mejor ni distinta de lo
     que la ticketera muestra: en minúscula, el renglón de la fecha tenía
     otro peso del que tiene en producción. */
  const DIAS = ["DOM", "LUN", "MAR", "MIÉ", "JUE", "VIE", "SÁB"];
  const MES3 = ["ENE", "FEB", "MAR", "ABR", "MAY", "JUN",
                "JUL", "AGO", "SEP", "OCT", "NOV", "DIC"];

  /* Fechas relativas a hoy: la demo no envejece. Una cartelera con eventos
     del mes pasado se lee como una ticketera abandonada. */
  const en = dias => {
    const d = new Date();
    d.setDate(d.getDate() + dias);
    return d;
  };

  /* La fecha se arma con los getters locales y no con `toISOString`, que
     devuelve el día en UTC: en Bolivia, después de las 20:00 el ISO ya es el
     día siguiente mientras `getDate()` sigue en el de hoy. La tarjeta se
     quedaba con el número de un día y la fecha de otro — y ahora que la
     portada dice "Hoy" comparando contra `fecha`, eso serían las nueve de la
     noche en que la demo empieza a mentir. */
  const dosDig = n => String(n).padStart(2, "0");

  const evento = (dias, hora, nombre, org, lugar, desde, venta, papel) => {
    const f = en(dias);
    const iso = `${f.getFullYear()}-${dosDig(f.getMonth() + 1)}-${dosDig(f.getDate())}`;
    return {
      url: "/amstel/red-circle?modo=demo",
      nombre, organizador_nombre: org, lugar, desde, venta,
      flyer_url: null, papel,
      fecha: iso,
      dia: String(f.getDate()),
      dia_semana: DIAS[f.getDay()],
      mes: MES3[f.getMonth()],
      hora,
    };
  };

  /* Nueve eventos, dos meses, tres estados de venta y precios de Bs 0 a 350
     — el rango real de una noche en Santa Cruz. El de Bs 0 está a propósito:
     enseña el evento gratis sin tener que explicarlo. Y los dos primeros son
     hoy y mañana, que es lo que hace visible el aviso en palabras: una demo
     que arranca dentro de tres días no puede mostrar la mitad de lo que la
     tarjeta sabe decir. */
  return [
    evento(  0, "22:00", "RED CIRCLE",        "Amstel",          "Fexpo · Santa Cruz",      120, "ultimas", ["#3A2478", "#231550"]),
    evento(  1, "21:30", "NOCHE BLANCA",      "Bowie",           "Equipetrol",              100, "abierta", ["#1E4A5F", "#12303E"]),
    evento(  9, "20:00", "APERTURA DE VERANO","BurTown",         "Av. San Martín",           80, "abierta", ["#5E2440", "#3A1428"]),
    evento( 12, "19:00", "CATA DE CERVEZA",   "Amstel",          "Manzana Uno",               0, "abierta", ["#2C4A2A", "#17301A"]),
    evento( 16, "23:00", "TECHNO SUBSUELO",   "Colectivo Norte", "Zona Norte",              150, "abierta", ["#4A3A16", "#2C220C"]),
    evento( 21, "21:00", "ANIVERSARIO 14",    "Living",          "Lugar secreto",           250, "ultimas", ["#3A2478", "#1D1240"]),
    evento( 27, "22:00", "CUMBIA DE ORO",     "Productora Sur",  "Coliseo Don Bosco",        90, "agotado", ["#5A3216", "#33200E"]),
    evento( 34, "20:30", "FESTIVAL PARQUE",   "Municipio",       "Parque Urbano",             0, "abierta", ["#1F4642", "#0F2C29"]),
    evento( 41, "23:30", "CIERRE DE MES",     "Bowie",           "Equipetrol",              350, "abierta", ["#4A1F2E", "#2A0F1B"]),
  ];
})();
