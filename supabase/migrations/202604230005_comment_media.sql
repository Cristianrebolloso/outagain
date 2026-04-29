alter table public.comments
  add column if not exists image_path text;

drop policy if exists "users can upload own comment photos" on storage.objects;
create policy "users can upload own comment photos"
on storage.objects
for insert
to authenticated
with check (
  bucket_id = 'moments'
  and (storage.foldername(name))[1] = 'comments'
  and (storage.foldername(name))[2] = auth.uid()::text
);
