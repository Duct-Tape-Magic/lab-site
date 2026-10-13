-- Student lab photos live in the private bucket under photos/<user_id>/<lab_id>/<photo_id>.jpg.
-- A signed-in student manages only their own folder; admins already have select/delete on the private bucket.
drop policy if exists "student manages own photos" on storage.objects;
create policy "student manages own photos" on storage.objects for all to authenticated
  using (bucket_id = 'lab-files-private' and (storage.foldername(name))[1] = 'photos' and (storage.foldername(name))[2] = auth.uid()::text)
  with check (bucket_id = 'lab-files-private' and (storage.foldername(name))[1] = 'photos' and (storage.foldername(name))[2] = auth.uid()::text);
