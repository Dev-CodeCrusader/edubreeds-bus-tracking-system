-- EDUBREEDS 006: parent screens, admin screens.
-- Safe to run once. Run in Supabase -> SQL Editor.

-- 1. Plain lat/lng on the live position (the driver app now sends them), so parents get them in Realtime.
alter table live_positions add column if not exists lat double precision;
alter table live_positions add column if not exists lng double precision;

-- 2. Notifications arrive live in the parent app.
do $$
begin
  alter publication supabase_realtime add table notifications;
exception when duplicate_object then null;
end $$;

-- 3. When a parent marks the child absent while a trip of that day is already running,
--    the child's waiting stop on that trip is marked absent at once.
create or replace function on_absence_notice() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  update trip_stops ts
     set state = 'absent', done_at = now(), note = 'Parent notice'
    from trips t
   where ts.trip_id = t.id and t.state = 'active'
     and ts.student_id = new.student_id and ts.state = 'pending'
     and (new.mode is null or new.mode = t.mode)
     and (t.started_at at time zone 'Asia/Kolkata')::date = new.on_date;
  return new;
end $$;

drop trigger if exists trg_absence_notice on absence_notices;
create trigger trg_absence_notice after insert on absence_notices
  for each row execute function on_absence_notice();

-- 4. School admins may upload student photos.
drop policy if exists student_photos_insert on storage.objects;
create policy student_photos_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'student-photos' and auth_role() = 'school_admin');

-- 4b. Readable school position on routes (PostgREST returns PostGIS columns as hex).
alter table routes add column if not exists school_lat double precision generated always as (st_y(school_location::geometry)) stored;
alter table routes add column if not exists school_lng double precision generated always as (st_x(school_location::geometry)) stored;

-- 5. Parents may read the stops of their child's trip (needed for the map).
--    (stops are already readable by everyone in the same school, so nothing more is needed.)

-- 6. Let a school admin see the people of their school and a parent see their own row (already allowed).
--    Nothing to add: profile_admin already covers it.

notify pgrst, 'reload schema';
