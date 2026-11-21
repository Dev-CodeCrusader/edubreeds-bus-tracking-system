-- PostgREST returns PostGIS columns as hex text, which the app cannot read.
-- Add plain latitude / longitude columns that always follow `location`.
alter table stops
  add column if not exists lat double precision generated always as (st_y(location::geometry)) stored,
  add column if not exists lng double precision generated always as (st_x(location::geometry)) stored;

-- make PostgREST notice the new columns right away
notify pgrst, 'reload schema';
