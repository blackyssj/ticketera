-- ============================================================
-- 0014 — el arte de las entradas
--
-- Igual que en Bowie y BurTown: el organizador sube UNA imagen y todas las
-- entradas se dibujan encima. El QR va sobre el arte, no al lado.
--
-- El bucket es de lectura pública porque el navegador tiene que cargar la
-- imagen para dibujar el ticket. Pero NO se crea policy de `select` sobre
-- storage.objects: sin ella la lectura por URL sigue andando y el LISTADO
-- queda cerrado. Es la distinción que en Puerta faltó y dejó enumerables
-- 187 comprobantes bancarios.
--
-- Ruta: <organizador_slug>/<evento_slug>/<lo que sea>.png
-- La primera carpeta ata el archivo a su organizador, y la policy lo exige.
-- ============================================================

create or replace function mi_organizador_slug() returns text
  language sql stable security definer set search_path = public as $$
  select o.slug from organizadores o where o.id = mi_organizador()
$$;
revoke execute on function mi_organizador_slug() from anon, public;
grant execute on function mi_organizador_slug() to authenticated;

drop policy if exists "arte: sube el staff"    on storage.objects;
drop policy if exists "arte: reemplaza el staff" on storage.objects;
drop policy if exists "arte: borra el staff"   on storage.objects;

create policy "arte: sube el staff" on storage.objects for insert to authenticated
  with check (bucket_id = 'arte' and puede_editar()
              and (storage.foldername(name))[1] = mi_organizador_slug());

create policy "arte: reemplaza el staff" on storage.objects for update to authenticated
  using      (bucket_id = 'arte' and puede_editar()
              and (storage.foldername(name))[1] = mi_organizador_slug())
  with check (bucket_id = 'arte' and puede_editar()
              and (storage.foldername(name))[1] = mi_organizador_slug());

create policy "arte: borra el staff" on storage.objects for delete to authenticated
  using (bucket_id = 'arte' and puede_editar()
         and (storage.foldername(name))[1] = mi_organizador_slug());

-- El arte por fase ya existe (evento_fase.arte_url, migración 0004). Falta el
-- del evento, que es el que se usa cuando la fase no trae uno propio.
alter table eventos add column if not exists arte_url text;
comment on column eventos.arte_url is
  'Modelo de la entrada. El QR se dibuja encima. Si la fase abierta tiene su
   propio arte_url, gana el de la fase: una preventa se distingue a simple vista.';
