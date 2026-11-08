-- Enforce tagged-user friendship boundaries.
--
-- Tagged-profile visibility lets the tagged user, and that user's accepted
-- friends, read the post. Without a write-time guard, a malicious client could
-- tag a stranger and broadcast the post into that stranger's friend graph.
--
-- From here forward, every tagged user on a post must be an accepted direct
-- friend of the author. Existing invalid tags are removed once so old posts do
-- not keep widened visibility.

create or replace function public.validate_post_tagged_friends()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  invalid_tag_count integer;
begin
  -- Normalize client-provided arrays so duplicate IDs cannot fan out duplicate
  -- notifications and nulls cannot linger in the visibility predicate.
  select coalesce(array_agg(normalized.tagged_user_id order by normalized.first_ordinality), '{}'::uuid[])
  into new.tagged_user_ids
  from (
    select tagged.tagged_user_id, min(tagged.ordinality) as first_ordinality
    from unnest(coalesce(new.tagged_user_ids, '{}'::uuid[]))
      with ordinality as tagged(tagged_user_id, ordinality)
    where tagged.tagged_user_id is not null
    group by tagged.tagged_user_id
  ) normalized;

  select count(*)
  into invalid_tag_count
  from unnest(new.tagged_user_ids) as tagged(tagged_user_id)
  where tagged.tagged_user_id = new.author_id
    or not exists (
      select 1
      from public.friendships f
      where f.status = 'accepted'
        and (
          (f.user_id = new.author_id and f.friend_id = tagged.tagged_user_id)
          or (f.friend_id = new.author_id and f.user_id = tagged.tagged_user_id)
        )
    );

  if invalid_tag_count > 0 then
    raise exception 'Tagged users must be accepted friends of the post author.'
      using errcode = '23514';
  end if;

  return new;
end;
$$;

-- One-time cleanup: keep only accepted direct friends in existing tag arrays,
-- preserving the first occurrence order.
with normalized_tags as (
  select
    p.id as post_id,
    tagged.tagged_user_id,
    min(tagged.ordinality) as first_ordinality
  from public.posts p
  left join lateral unnest(coalesce(p.tagged_user_ids, '{}'::uuid[]))
    with ordinality as tagged(tagged_user_id, ordinality) on true
  where tagged.tagged_user_id is not null
    and tagged.tagged_user_id <> p.author_id
    and exists (
      select 1
      from public.friendships f
      where f.status = 'accepted'
        and (
          (f.user_id = p.author_id and f.friend_id = tagged.tagged_user_id)
          or (f.friend_id = p.author_id and f.user_id = tagged.tagged_user_id)
        )
    )
  group by p.id, tagged.tagged_user_id
),
sanitized_posts as (
  select
    p.id as post_id,
    coalesce(
      array_agg(nt.tagged_user_id order by nt.first_ordinality)
        filter (where nt.tagged_user_id is not null),
      '{}'::uuid[]
    ) as tagged_user_ids
  from public.posts p
  left join normalized_tags nt on nt.post_id = p.id
  group by p.id
)
update public.posts p
set tagged_user_ids = sp.tagged_user_ids
from sanitized_posts sp
where p.id = sp.post_id
  and p.tagged_user_ids is distinct from sp.tagged_user_ids;

delete from public.notifications n
using public.posts p
where n.post_id = p.id
  and n.kind = 'tagged'
  and not (n.user_id = any(coalesce(p.tagged_user_ids, '{}'::uuid[])));

drop trigger if exists posts_validate_tagged_friends on public.posts;
create trigger posts_validate_tagged_friends
before insert or update of author_id, tagged_user_ids on public.posts
for each row
execute function public.validate_post_tagged_friends();
