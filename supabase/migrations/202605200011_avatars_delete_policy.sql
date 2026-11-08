-- Allow users to delete their own avatar objects. Avatar uploads use fresh
-- UUID paths under `avatars/users/<uid>/`, so without this policy every avatar
-- change leaves the previous file orphaned in storage forever.

drop policy if exists "users can delete own avatars" on storage.objects;
create policy "users can delete own avatars"
on storage.objects
for delete
to authenticated
using (
  bucket_id = 'avatars'
  and (storage.foldername(name))[1] = 'users'
  and (storage.foldername(name))[2] = auth.uid()::text
);

drop policy if exists "admins can delete avatar media" on storage.objects;
create policy "admins can delete avatar media"
on storage.objects
for delete
to authenticated
using (
  bucket_id = 'avatars'
  and public.is_app_admin(auth.uid())
  and (storage.foldername(name))[1] = 'users'
);
