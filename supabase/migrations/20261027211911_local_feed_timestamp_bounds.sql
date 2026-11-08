CREATE OR REPLACE FUNCTION private.can_read_local_post(post_author_id uuid, post_latitude double precision, post_longitude double precision, posted_at timestamp with time zone)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select private.users_can_interact(auth.uid(),post_author_id)
    and posted_at between now()-interval '48 hours' and now()
    and exists(select 1 from private.discovery_context c where c.user_id=auth.uid()
      and c.location_updated_at >= now()-interval '24 hours'
      and private.distance_meters(c.latitude,c.longitude,post_latitude,post_longitude) <= 8046.72);
$function$;
