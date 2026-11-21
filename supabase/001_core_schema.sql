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
