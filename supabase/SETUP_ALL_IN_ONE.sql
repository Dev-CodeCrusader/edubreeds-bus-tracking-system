-- ================= 001_core_schema.sql =================
-- EDUBREEDS School Bus Tracking & Safety System
-- Phase 1 core schema for Supabase (Postgres + PostGIS)
-- Run in the Supabase SQL editor, or save as supabase/migrations/001_core_schema.sql

create extension if not exists postgis;
create extension if not exists pgcrypto;

-- ---------------------------------------------------------------- enums
create type user_role   as enum ('super_admin', 'school_admin', 'driver', 'parent', 'caretaker');
create type trip_mode   as enum ('pickup', 'drop');
create type trip_state  as enum ('active', 'completed', 'cancelled');
create type stop_state  as enum ('pending', 'picked_up', 'dropped', 'absent', 'not_available', 'no_one_at_stop');
create type remark_kind as enum ('on_time', 'van_delayed', 'student_delayed');

-- ---------------------------------------------------------------- tenants
-- app_groups = one shared app for several schools (white-label type 1).
create table app_groups (
  id         uuid primary key default gen_random_uuid(),
  name       text not null,
  theme      jsonb not null default '{}',          -- logo, colors, app name
  created_at timestamptz not null default now()
);

create table schools (
  id             uuid primary key default gen_random_uuid(),
  group_id       uuid references app_groups(id),
  name           text not null,
  city           text,
  logo_url       text,
  theme          jsonb not null default '{}',
  photos_enabled boolean not null default true,    -- child-privacy toggle (student + stop pictures)
  plan           text not null default 'pilot',
  created_at     timestamptz not null default now()
);

-- ---------------------------------------------------------------- people
create table profiles (
  id         uuid primary key references auth.users(id) on delete cascade,
  school_id  uuid references schools(id),          -- null for super_admin
  role       user_role not null,
  full_name  text not null,
  phone      text,
  active     boolean not null default true,
  created_at timestamptz not null default now()
);
create index on profiles (school_id, role);

create table students (
  id         uuid primary key default gen_random_uuid(),
  school_id  uuid not null references schools(id),
  full_name  text not null,
  class_name text,
  photo_url  text,                                  -- hidden by the app when schools.photos_enabled = false
  active     boolean not null default true,
  created_at timestamptz not null default now()
);
create index on students (school_id);

create table guardians (
  student_id uuid not null references students(id) on delete cascade,
  parent_id  uuid not null references profiles(id) on delete cascade,
  primary key (student_id, parent_id)
);

create table consents (
  id           uuid primary key default gen_random_uuid(),
  student_id   uuid not null references students(id) on delete cascade,
  parent_id    uuid references profiles(id),
  document_url text not null,                       -- signed consent form in Storage
  signed_at    date not null,
  revoked_at   timestamptz
);

-- ---------------------------------------------------------------- fleet and routes
create table buses (
  id        uuid primary key default gen_random_uuid(),
  school_id uuid not null references schools(id),
  reg_no    text not null,
  capacity  int,
  driver_id uuid references profiles(id),           -- change for a substitute driver
  unique (school_id, reg_no)
);

create table routes (
  id              uuid primary key default gen_random_uuid(),
  school_id       uuid not null references schools(id),
  bus_id          uuid references buses(id),
  name            text not null,
  mode            trip_mode not null,
  school_location geography(point, 4326),
  school_arrival  time                              -- expected arrival at school (pickup)
);

create table stops (
  id             uuid primary key default gen_random_uuid(),
  route_id       uuid not null references routes(id) on delete cascade,
  seq            int  not null,
  name           text not null,
  location       geography(point, 4326) not null,
  radius_m       int  not null default 50,          -- arrival geofence
  scheduled_time time,                              -- scheduled pickup / drop time
  photo_url      text,                              -- hidden when photos are disabled
  unique (route_id, seq)
);
create index on stops using gist (location);

create table stop_students (
  stop_id    uuid not null references stops(id) on delete cascade,
  student_id uuid not null references students(id) on delete cascade,
  primary key (stop_id, student_id)
);

-- ---------------------------------------------------------------- trips
create table trips (
  id         uuid primary key default gen_random_uuid(),
  school_id  uuid not null references schools(id),
  route_id   uuid not null references routes(id),
  driver_id  uuid not null references profiles(id),
  mode       trip_mode not null,
  state      trip_state not null default 'active',
  selfie_url text not null,                         -- shift-start selfie
  started_at timestamptz not null default now(),
  ended_at   timestamptz
);
create index on trips (school_id, started_at desc);
create index on trips (route_id, state);

create table trip_stops (
  id             uuid primary key default gen_random_uuid(),
  trip_id        uuid not null references trips(id) on delete cascade,
  stop_id        uuid not null references stops(id),
  student_id     uuid not null references students(id),
  state          stop_state not null default 'pending',
  van_arrived_at timestamptz,
  done_at        timestamptz,                       -- picked up / dropped time
  remark         remark_kind,
  note           text,
  unique (trip_id, student_id)
);

create table proof_photos (
  id           uuid primary key default gen_random_uuid(),
  trip_stop_id uuid not null references trip_stops(id) on delete cascade,
  image_url    text not null,
  location     geography(point, 4326),              -- GPS stamp
  taken_at     timestamptz not null default now()
);

-- one row per active trip, updated every few seconds; parents subscribe via Realtime
create table live_positions (
  trip_id    uuid primary key references trips(id) on delete cascade,
  location   geography(point, 4326) not null,
  speed_kmh  real,
  heading    real,
  updated_at timestamptz not null default now()
);

-- history for disputes; delete rows older than ~30 days with a scheduled job
create table location_pings (
  id          bigint generated always as identity primary key,
  trip_id     uuid not null references trips(id) on delete cascade,
  location    geography(point, 4326) not null,
  recorded_at timestamptz not null default now()
);
create index on location_pings (trip_id, recorded_at);

-- ---------------------------------------------------------------- parent absence + notifications
create table absence_notices (
  id         uuid primary key default gen_random_uuid(),
  student_id uuid not null references students(id) on delete cascade,
  on_date    date not null,
  mode       trip_mode,                             -- null = both pickup and drop
  created_by uuid not null references profiles(id),
  created_at timestamptz not null default now(),
  unique (student_id, on_date, mode)
);

create table device_tokens (
  token      text primary key,                      -- FCM token
  user_id    uuid not null references profiles(id) on delete cascade,
  platform   text not null default 'android',
  updated_at timestamptz not null default now()
);

create table notifications (
  id              uuid primary key default gen_random_uuid(),
  school_id       uuid not null references schools(id),
  recipient_id    uuid not null references profiles(id),
  kind            text not null,                    -- trip_started, stop_before, arrived, alert, absent_proof, ...
  payload         jsonb not null default '{}',
  sent_at         timestamptz not null default now(),
  acknowledged_at timestamptz
);
create index on notifications (recipient_id, sent_at desc);

-- ---------------------------------------------------------------- row-level security helpers
create function auth_role() returns user_role
language sql stable security definer set search_path = public as
$$ select role from profiles where id = auth.uid() $$;

create function auth_school() returns uuid
language sql stable security definer set search_path = public as
$$ select school_id from profiles where id = auth.uid() $$;

create function is_super() returns boolean
language sql stable as $$ select auth_role() = 'super_admin' $$;

create function is_staff() returns boolean
language sql stable as $$ select auth_role() in ('school_admin', 'driver', 'caretaker') $$;

create function is_guardian_of(sid uuid) returns boolean
language sql stable security definer set search_path = public as
$$ select exists (select 1 from guardians where student_id = sid and parent_id = auth.uid()) $$;

-- ---------------------------------------------------------------- row-level security policies
alter table app_groups      enable row level security;
alter table schools         enable row level security;
alter table profiles        enable row level security;
alter table students        enable row level security;
alter table guardians       enable row level security;
alter table consents        enable row level security;
alter table buses           enable row level security;
alter table routes          enable row level security;
alter table stops           enable row level security;
alter table stop_students   enable row level security;
alter table trips           enable row level security;
alter table trip_stops      enable row level security;
alter table proof_photos    enable row level security;
alter table live_positions  enable row level security;
alter table location_pings  enable row level security;
alter table absence_notices enable row level security;
alter table device_tokens   enable row level security;
alter table notifications   enable row level security;

-- super admin: everything
do $$
declare t text;
begin
  foreach t in array array['app_groups','schools','profiles','students','guardians','consents','buses',
    'routes','stops','stop_students','trips','trip_stops','proof_photos','live_positions',
    'location_pings','absence_notices','device_tokens','notifications']
  loop
    execute format('create policy super_all on %I for all using (is_super()) with check (is_super())', t);
  end loop;
end $$;

-- schools and profiles
create policy school_read    on schools  for select using (id = auth_school());
create policy school_update  on schools  for update using (id = auth_school() and auth_role() = 'school_admin');
create policy group_read     on app_groups for select using (id = (select group_id from schools where id = auth_school()));
create policy profile_self   on profiles for select using (id = auth.uid());
create policy profile_school on profiles for select using (school_id = auth_school() and is_staff());
create policy profile_admin  on profiles for all    using (school_id = auth_school() and auth_role() = 'school_admin')
                                                    with check (school_id = auth_school());

-- students, guardians, consents
create policy student_staff  on students for select using (school_id = auth_school() and is_staff());
create policy student_parent on students for select using (is_guardian_of(id));
create policy student_admin  on students for all    using (school_id = auth_school() and auth_role() = 'school_admin')
                                                    with check (school_id = auth_school());
create policy guardian_self  on guardians for select using (parent_id = auth.uid());
create policy guardian_admin on guardians for all using (auth_role() = 'school_admin' and
  exists (select 1 from students s where s.id = student_id and s.school_id = auth_school()));
create policy consent_read   on consents for select using (is_guardian_of(student_id) or auth_role() = 'school_admin');
create policy consent_admin  on consents for all using (auth_role() = 'school_admin' and
  exists (select 1 from students s where s.id = student_id and s.school_id = auth_school()));

-- fleet and routes: staff read, admin write
create policy bus_staff   on buses  for select using (school_id = auth_school() and is_staff());
create policy bus_admin   on buses  for all    using (school_id = auth_school() and auth_role() = 'school_admin')
                                               with check (school_id = auth_school());
create policy route_read  on routes for select using (school_id = auth_school());
create policy route_admin on routes for all    using (school_id = auth_school() and auth_role() = 'school_admin')
                                               with check (school_id = auth_school());
create policy stop_read   on stops  for select using (exists (select 1 from routes r where r.id = route_id and r.school_id = auth_school()));
create policy stop_admin  on stops  for all    using (auth_role() = 'school_admin' and
  exists (select 1 from routes r where r.id = route_id and r.school_id = auth_school()));
create policy ss_read     on stop_students for select using (is_staff() or is_guardian_of(student_id));
create policy ss_admin    on stop_students for all using (auth_role() = 'school_admin' and
  exists (select 1 from students s where s.id = student_id and s.school_id = auth_school()));

-- trips: driver writes own; staff read school; parents read trips of their children
create policy trip_staff  on trips for select using (school_id = auth_school() and is_staff());
create policy trip_parent on trips for select using (exists (
  select 1 from trip_stops ts where ts.trip_id = trips.id and is_guardian_of(ts.student_id)));
create policy trip_driver on trips for all using (driver_id = auth.uid()) with check (driver_id = auth.uid() and school_id = auth_school());

create policy tstop_staff  on trip_stops for select using (is_staff() and
  exists (select 1 from trips t where t.id = trip_id and t.school_id = auth_school()));
create policy tstop_parent on trip_stops for select using (is_guardian_of(student_id));
create policy tstop_driver on trip_stops for all using (
  exists (select 1 from trips t where t.id = trip_id and t.driver_id = auth.uid()));

create policy proof_read   on proof_photos for select using (
  exists (select 1 from trip_stops ts where ts.id = trip_stop_id and (is_guardian_of(ts.student_id) or auth_role() = 'school_admin')));
create policy proof_driver on proof_photos for all using (
  exists (select 1 from trip_stops ts join trips t on t.id = ts.trip_id where ts.id = trip_stop_id and t.driver_id = auth.uid()));

-- live position: anyone tied to the trip reads; the driver writes
create policy live_read on live_positions for select using (
  exists (select 1 from trips t where t.id = trip_id and t.school_id = auth_school() and (is_staff() or
    exists (select 1 from trip_stops ts where ts.trip_id = t.id and is_guardian_of(ts.student_id)))));
create policy live_driver on live_positions for all using (
  exists (select 1 from trips t where t.id = trip_id and t.driver_id = auth.uid()));
create policy ping_driver on location_pings for insert with check (
  exists (select 1 from trips t where t.id = trip_id and t.driver_id = auth.uid()));
create policy ping_admin  on location_pings for select using (auth_role() = 'school_admin' and
  exists (select 1 from trips t where t.id = trip_id and t.school_id = auth_school()));

-- absence notices: parents create for own children; staff read
create policy absence_parent on absence_notices for all using (is_guardian_of(student_id)) with check (is_guardian_of(student_id) and created_by = auth.uid());
create policy absence_staff  on absence_notices for select using (is_staff());

-- own device tokens and notifications
create policy token_self  on device_tokens  for all    using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy notif_self  on notifications  for select using (recipient_id = auth.uid());
create policy notif_ack   on notifications  for update using (recipient_id = auth.uid());
create policy notif_admin on notifications  for select using (school_id = auth_school() and auth_role() = 'school_admin');

-- ---------------------------------------------------------------- Realtime
-- Enable Realtime for live tracking and status changes.
alter publication supabase_realtime add table live_positions, trip_stops, trips;

-- ---------------------------------------------------------------- pilot seed: the two schools in one shared app
insert into app_groups (id, name) values ('00000000-0000-0000-0000-0000000000a1', 'N K Public School');
insert into schools (group_id, name, city) values
  ('00000000-0000-0000-0000-0000000000a1', 'N K Public School, Bhubaneswar', 'Bhubaneswar'),
  ('00000000-0000-0000-0000-0000000000a1', 'N K Public School, Daspalla',    'Daspalla');

-- ================= 002_driver_functions.sql =================
-- EDUBREEDS driver-side server rules (Supabase). Run after 001_core_schema.sql.
-- The driver app calls these functions so the rules (alert time-gate, notifications,
-- remarks, who may do what) live on the server and cannot be bypassed from the phone.
-- They only WRITE rows into `notifications`; actual push delivery (FCM) is a later
-- step: a Supabase Database Webhook on `notifications` -> Edge Function -> FCM.

-- ---------------------------------------------------------------- storage
insert into storage.buckets (id, name, public)
values ('trip-photos', 'trip-photos', false), ('student-photos', 'student-photos', false)
on conflict (id) do nothing;

-- Pilot-level policies: any signed-in user may upload / read. Tighten per school before go-live.
create policy trip_photos_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'trip-photos');
create policy trip_photos_read on storage.objects for select to authenticated
  using (bucket_id in ('trip-photos', 'student-photos'));

-- ---------------------------------------------------------------- helpers
create function ist_now_time() returns time
language sql stable as $$ select (now() at time zone 'Asia/Kolkata')::time $$;

create function ist_today() returns date
language sql stable as $$ select (now() at time zone 'Asia/Kolkata')::date $$;

-- write one notification per guardian of a student
create function notify_guardians(p_school uuid, p_student uuid, p_kind text, p_payload jsonb)
returns void language sql security definer set search_path = public as $$
  insert into notifications (school_id, recipient_id, kind, payload)
  select p_school, g.parent_id, p_kind, p_payload from guardians g where g.student_id = p_student
$$;

-- the trip must belong to the calling driver
create function assert_my_trip(p_trip uuid) returns trips
language plpgsql security definer set search_path = public as $$
declare t trips;
begin
  select * into t from trips where id = p_trip and driver_id = auth.uid();
  if not found then raise exception 'not your trip'; end if;
  return t;
end $$;

-- ---------------------------------------------------------------- start a shift
-- p_student_ids: for DROP, the students the driver selected as being in the van.
-- For PICKUP leave it null (everyone assigned to the route; students with a parent
-- absence notice for today start as 'absent').
create function start_trip(p_route uuid, p_selfie_path text, p_student_ids uuid[] default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare r routes; t_id uuid; s record;
begin
  if auth_role() <> 'driver' then raise exception 'drivers only'; end if;
  select * into r from routes where id = p_route and school_id = auth_school();
  if not found then raise exception 'route not found'; end if;

  -- close any trip this driver left open
  update trips set state = 'completed', ended_at = now() where driver_id = auth.uid() and state = 'active';

  insert into trips (school_id, route_id, driver_id, mode, selfie_url)
  values (r.school_id, r.id, auth.uid(), r.mode, p_selfie_path) returning id into t_id;

  for s in
    select ss.stop_id, ss.student_id from stop_students ss
    join stops st on st.id = ss.stop_id
    join students stu on stu.id = ss.student_id and stu.active
    where st.route_id = r.id and (p_student_ids is null or ss.student_id = any (p_student_ids))
  loop
    insert into trip_stops (trip_id, stop_id, student_id, state)
    values (t_id, s.stop_id, s.student_id,
      case when r.mode = 'pickup' and exists (
        select 1 from absence_notices a
        where a.student_id = s.student_id and a.on_date = ist_today() and (a.mode is null or a.mode = 'pickup'))
      then 'absent'::stop_state else 'pending'::stop_state end);
    if (select state from trip_stops where trip_id = t_id and student_id = s.student_id) = 'pending' then
      perform notify_guardians(r.school_id, s.student_id, 'trip_started',
        jsonb_build_object('trip_id', t_id, 'mode', r.mode, 'text', 'School transportation has started.'));
    end if;
  end loop;
  return t_id;
end $$;

-- ---------------------------------------------------------------- van reached a stop (geofence)
create function mark_arrived(p_trip uuid, p_stop uuid)
returns void language plpgsql security definer set search_path = public as $$
declare t trips; ts record;
begin
  t := assert_my_trip(p_trip);
  for ts in select * from trip_stops where trip_id = p_trip and stop_id = p_stop and state = 'pending' loop
    update trip_stops set van_arrived_at = coalesce(van_arrived_at, now()) where id = ts.id;
    perform notify_guardians(t.school_id, ts.student_id, 'arrived',
      jsonb_build_object('trip_id', p_trip, 'buzz', true, 'text', 'The van has reached your stop.'));
  end loop;
end $$;

-- ---------------------------------------------------------------- finish one student
-- p_state: picked_up | dropped | absent | no_one_at_stop | not_available
create function mark_stop(p_trip_stop uuid, p_state stop_state)
returns void language plpgsql security definer set search_path = public as $$
declare ts trip_stops; t trips; st stops; nxt record; v_remark remark_kind; left_count int;
begin
  select * into ts from trip_stops where id = p_trip_stop;
  if not found then raise exception 'unknown stop'; end if;
  t := assert_my_trip(ts.trip_id);
  if p_state not in ('picked_up', 'dropped', 'absent', 'no_one_at_stop', 'not_available') then raise exception 'bad state'; end if;
  select * into st from stops where id = ts.stop_id;

  if t.mode = 'pickup' and st.scheduled_time is not null then
    if ts.van_arrived_at is not null and (ts.van_arrived_at at time zone 'Asia/Kolkata')::time > st.scheduled_time then
      v_remark := 'van_delayed';
    elsif p_state = 'picked_up' and ist_now_time() > st.scheduled_time + interval '2 minutes' then
      v_remark := 'student_delayed';
    else
      v_remark := 'on_time';
    end if;
  end if;

  update trip_stops set state = p_state, done_at = now(), remark = coalesce(v_remark, trip_stops.remark)
  where id = p_trip_stop;

  -- "get ready": tell the guardians of the student(s) at the next stop
  select s2.id as stop_id into nxt from stops s2
  where s2.route_id = st.route_id and s2.seq > st.seq
    and exists (select 1 from trip_stops x where x.trip_id = t.id and x.stop_id = s2.id and x.state = 'pending')
  order by s2.seq limit 1;
  if found then
    perform notify_guardians(t.school_id, x.student_id, 'stop_before',
      jsonb_build_object('trip_id', t.id, 'text', 'The van is arriving soon. Please be ready.'))
    from trip_stops x where x.trip_id = t.id and x.stop_id = nxt.stop_id and x.state = 'pending';
  end if;

  -- last student on a pickup route: notify school caretakers
  select count(*) into left_count from trip_stops where trip_id = t.id and state = 'pending';
  if left_count = 0 and t.mode = 'pickup' then
    insert into notifications (school_id, recipient_id, kind, payload)
    select t.school_id, p.id, 'last_picked', jsonb_build_object('trip_id', t.id, 'text', 'All students are on board. The van is heading to school.')
    from profiles p where p.school_id = t.school_id and p.role = 'caretaker' and p.active;
  end if;
end $$;

-- ---------------------------------------------------------------- "Student Not Available/Ready" proof
create function mark_not_available(p_trip_stop uuid, p_image_path text, p_lat double precision, p_lng double precision)
returns void language plpgsql security definer set search_path = public as $$
declare ts trip_stops; t trips;
begin
  select * into ts from trip_stops where id = p_trip_stop;
  if not found then raise exception 'unknown stop'; end if;
  t := assert_my_trip(ts.trip_id);
  insert into proof_photos (trip_stop_id, image_url, location)
  values (p_trip_stop, p_image_path, st_setsrid(st_makepoint(p_lng, p_lat), 4326)::geography);
  perform notify_guardians(t.school_id, ts.student_id, 'absent_proof',
    jsonb_build_object('trip_id', t.id, 'image', p_image_path, 'taken_at', now(),
                       'text', 'Your child was not ready at the stop.'));
  perform mark_stop(p_trip_stop, 'not_available');
end $$;

-- ---------------------------------------------------------------- Alert button
-- Pickup: only at or after the stop's scheduled time. Drop: always enabled.
create function driver_alert(p_trip_stop uuid)
returns void language plpgsql security definer set search_path = public as $$
declare ts trip_stops; t trips; st stops;
begin
  select * into ts from trip_stops where id = p_trip_stop;
  if not found then raise exception 'unknown stop'; end if;
  t := assert_my_trip(ts.trip_id);
  select * into st from stops where id = ts.stop_id;
  if t.mode = 'pickup' and st.scheduled_time is not null and ist_now_time() < st.scheduled_time then
    raise exception 'alert is not available before the scheduled pickup time';
  end if;
  perform notify_guardians(t.school_id, ts.student_id, 'alert',
    jsonb_build_object('trip_id', t.id, 'buzz', true, 'buzz_seconds', 60,
      'text', case when t.mode = 'drop' then 'Your child has reached.' else 'The van is waiting at your stop.' end));
end $$;

-- ---------------------------------------------------------------- end of shift
create function finish_trip(p_trip uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform assert_my_trip(p_trip);
  update trips set state = 'completed', ended_at = now() where id = p_trip;
  delete from live_positions where trip_id = p_trip;
end $$;

grant execute on function start_trip(uuid, text, uuid[]), mark_arrived(uuid, uuid), mark_stop(uuid, stop_state),
  mark_not_available(uuid, text, double precision, double precision), driver_alert(uuid), finish_trip(uuid)
  to authenticated;

-- ================= 004_stop_coordinates.sql =================
-- PostgREST returns PostGIS columns as hex text, which the app cannot read.
-- Add plain latitude / longitude columns that always follow `location`.
alter table stops
  add column if not exists lat double precision generated always as (st_y(location::geometry)) stored,
  add column if not exists lng double precision generated always as (st_x(location::geometry)) stored;

-- make PostgREST notice the new columns right away
notify pgrst, 'reload schema';

-- ================= 005_fix_policy_recursion.sql =================
-- Fixes: "infinite recursion detected in policy for relation trip_stops".
-- trips and trip_stops used to check each other. These helper functions read the other table
-- without re-triggering its row-level rules, which breaks the loop. Access rules are unchanged.

create or replace function is_my_trip(tid uuid) returns boolean
language sql stable security definer set search_path = public as
$$ select exists (select 1 from trips where id = tid and driver_id = auth.uid()) $$;

create or replace function trip_school(tid uuid) returns uuid
language sql stable security definer set search_path = public as
$$ select school_id from trips where id = tid $$;

create or replace function is_parent_on_trip(tid uuid) returns boolean
language sql stable security definer set search_path = public as
$$ select exists (
     select 1 from trip_stops ts
     where ts.trip_id = tid
       and exists (select 1 from guardians g where g.student_id = ts.student_id and g.parent_id = auth.uid())
   ) $$;

grant execute on function is_my_trip(uuid), trip_school(uuid), is_parent_on_trip(uuid) to authenticated;

-- trips
drop policy if exists trip_parent on trips;
create policy trip_parent on trips for select using (is_parent_on_trip(id));

-- trip_stops
drop policy if exists tstop_staff  on trip_stops;
drop policy if exists tstop_driver on trip_stops;
create policy tstop_staff  on trip_stops for select
  using (is_staff() and trip_school(trip_id) = auth_school());
create policy tstop_driver on trip_stops for all
  using (is_my_trip(trip_id)) with check (is_my_trip(trip_id));

-- proof photos and live position used the same cross-checks
drop policy if exists proof_driver on proof_photos;
create policy proof_driver on proof_photos for all using (
  exists (select 1 from trip_stops ts where ts.id = trip_stop_id and is_my_trip(ts.trip_id)));

drop policy if exists live_read   on live_positions;
drop policy if exists live_driver on live_positions;
create policy live_read on live_positions for select using (
  trip_school(trip_id) = auth_school() and (is_staff() or is_parent_on_trip(trip_id)));
create policy live_driver on live_positions for all
  using (is_my_trip(trip_id)) with check (is_my_trip(trip_id));

drop policy if exists ping_driver on location_pings;
drop policy if exists ping_admin  on location_pings;
create policy ping_driver on location_pings for insert with check (is_my_trip(trip_id));
create policy ping_admin  on location_pings for select
  using (auth_role() = 'school_admin' and trip_school(trip_id) = auth_school());

notify pgrst, 'reload schema';

-- ================= 006_parent_admin.sql =================
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

-- ================= 008_complete.sql =================
-- EDUBREEDS 008: consent forms, tighter photo access, boarded/dropped alerts, cleanup job.
-- Run once in Supabase -> SQL Editor (after 006).

-- 1. Signed consent forms (photo or scan of the signed form), private bucket
insert into storage.buckets (id, name, public) values ('consents', 'consents', false) on conflict (id) do nothing;

drop policy if exists consents_admin_write on storage.objects;
create policy consents_admin_write on storage.objects for insert to authenticated
  with check (bucket_id = 'consents' and auth_role() = 'school_admin'
              and (storage.foldername(name))[1] = auth_school()::text);

drop policy if exists consents_admin_read on storage.objects;
create policy consents_admin_read on storage.objects for select to authenticated
  using (bucket_id = 'consents' and (is_super() or (auth_role() = 'school_admin'
              and (storage.foldername(name))[1] = auth_school()::text)));

-- 2. Photos: only people of the same school can read them; drivers write only into their own folder
drop policy if exists trip_photos_read on storage.objects;
create policy trip_photos_read on storage.objects for select to authenticated using (
  is_super()
  or (bucket_id = 'student-photos' and (storage.foldername(name))[1] = auth_school()::text)
  or (bucket_id = 'trip-photos' and exists (
        select 1 from profiles p
        where p.id::text = (storage.foldername(name))[2] and p.school_id = auth_school()))
);

drop policy if exists trip_photos_insert on storage.objects;
create policy trip_photos_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'trip-photos' and (storage.foldername(name))[2] = auth.uid()::text);

-- 3. Parents are told when their child boards and when the child is dropped
create or replace function on_trip_stop_done() returns trigger
language plpgsql security definer set search_path = public as $$
declare t trips; nm text;
begin
  if new.state is distinct from old.state and new.state in ('picked_up', 'dropped') then
    select * into t from trips where id = new.trip_id;
    select full_name into nm from students where id = new.student_id;
    perform notify_guardians(t.school_id, new.student_id, new.state::text,
      jsonb_build_object('trip_id', new.trip_id,
        'text', case when new.state = 'picked_up' then nm || ' has boarded the bus.' else nm || ' has been dropped.' end));
  end if;
  return new;
end $$;

drop trigger if exists trg_trip_stop_done on trip_stops;
create trigger trg_trip_stop_done after update on trip_stops for each row execute function on_trip_stop_done();

-- 4. Branding for shared apps: {"name": "My School App", "color": "#1B5E9E"}
--    (edited by the Super Admin in the app; nothing to run)

-- 5. Nightly cleanup (needs the pg_cron extension; skipped quietly if it is not available)
do $$
begin
  create extension if not exists pg_cron;
  perform cron.schedule('edubreeds-cleanup', '30 20 * * *', $c$
    delete from location_pings where recorded_at < now() - interval '30 days';
    delete from notifications  where sent_at   < now() - interval '90 days';
  $c$);
exception when others then
  raise notice 'pg_cron not enabled, cleanup job skipped: %', sqlerrm;
end $$;

-- 6. Phone registration for push alerts (a token moves to whoever signed in last on that phone)
create or replace function register_device(p_token text, p_platform text default 'android') returns void
language sql security definer set search_path = public as $$
  insert into device_tokens (token, user_id, platform, updated_at) values (p_token, auth.uid(), p_platform, now())
  on conflict (token) do update set user_id = auth.uid(), updated_at = now()
$$;
grant execute on function register_device(text, text) to authenticated;

notify pgrst, 'reload schema';

-- ================= 009_grants.sql =================
-- Lets signed-in users use the tables (row-level security still decides WHICH rows).
-- Run after all tables exist.
grant usage on schema public to authenticated;
grant select, insert, update, delete on all tables in schema public to authenticated;
grant usage, select on all sequences in schema public to authenticated;
grant execute on all functions in schema public to authenticated;
alter default privileges in schema public grant select, insert, update, delete on tables to authenticated;
alter default privileges in schema public grant usage, select on sequences to authenticated;
alter default privileges in schema public grant execute on functions to authenticated;
notify pgrst, 'reload schema';

