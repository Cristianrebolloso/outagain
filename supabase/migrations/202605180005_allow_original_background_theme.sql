alter table if exists public.profiles
  drop constraint if exists profiles_background_theme_check;

alter table if exists public.profiles
  add constraint profiles_background_theme_check
  check (
    background_theme is null
    or background_theme in (
      'standard',
      'original',
      'speakeasy',
      'night',
      'orange',
      'green',
      'pink',
      'blue'
    )
  );
