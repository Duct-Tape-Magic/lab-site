alter table public.labs add column if not exists cover_zoom integer not null default 100;
alter table public.folders add column if not exists cover_zoom integer not null default 100;
