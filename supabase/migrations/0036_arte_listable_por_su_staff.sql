-- ============================================================
-- 0036 — el staff puede ver los archivos de SU carpeta
--
-- 0014 dejó el bucket `arte` sin policy de `select` a propósito, y el
-- motivo sigue en pie: sin ella la lectura por URL funciona igual (el
-- bucket es público) y el LISTADO queda cerrado. Es la distinción que en
-- Plataforma Puerta faltó y dejó enumerables 187 comprobantes bancarios.
--
-- Lo que faltaba distinguir es a QUIÉN se le cierra. Ahí quedó cerrado
-- para todos, y eso tiene un costo que recién apareció al subir el arte
-- desde el panel: sin `select`, el navegador no puede hacer upsert
-- (`insert … on conflict` necesita leer para saber si hay conflicto),
-- no puede reemplazar con PUT, y `remove()` devuelve éxito sin borrar
-- nada. La única operación que le queda es un insert puro, así que cada
-- vez que alguien cambia el arte queda el anterior colgado en el bucket,
-- sin nada que lo apunte y sin forma de borrarlo desde el panel.
--
-- Esta policy NO es la de Puerta al revés. Aquella habría sido `to anon`.
-- Esta exige las tres cosas juntas: estar autenticado, ser admin o staff
-- (`puede_editar()`), y que la primera carpeta del archivo sea la del
-- organizador de la sesión. Un anónimo sigue sin poder listar nada, y un
-- staff de otro cliente tampoco ve esta carpeta. Lo que se abre es que
-- cada uno vea lo suyo, que es lo que hace falta para poder reemplazarlo
-- y borrarlo.
-- ============================================================

drop policy if exists "arte: lista el staff de su carpeta" on storage.objects;

create policy "arte: lista el staff de su carpeta" on storage.objects for select to authenticated
  using (bucket_id = 'arte' and puede_editar()
         and (storage.foldername(name))[1] = mi_organizador_slug());
