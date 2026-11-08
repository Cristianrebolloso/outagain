-- Allow the Swift client to clean up Supabase Storage media after deleting
-- posts/comments. Supabase protects direct deletes from SQL functions, so the
-- app must use the Storage API; Storage API deletes still require RLS policies
-- on storage.objects.

drop policy if exists "users can delete own post media" on storage.objects;
create policy "users can delete own post media"
on storage.objects
for delete
to authenticated
using (
  bucket_id = 'moments'
  and (storage.foldername(name))[1] = 'posts'
  and (storage.foldername(name))[2] = auth.uid()::text
);

drop policy if exists "users can delete own comment media" on storage.objects;
create policy "users can delete own comment media"
on storage.objects
for delete
to authenticated
using (
  bucket_id = 'moments'
  and (storage.foldername(name))[1] = 'comments'
  and (storage.foldername(name))[2] = auth.uid()::text
);

drop policy if exists "admins can delete moment media" on storage.objects;
create policy "admins can delete moment media"
on storage.objects
for delete
to authenticated
using (
  bucket_id = 'moments'
  and public.is_app_admin(auth.uid())
  and (storage.foldername(name))[1] in ('posts', 'comments')
);
