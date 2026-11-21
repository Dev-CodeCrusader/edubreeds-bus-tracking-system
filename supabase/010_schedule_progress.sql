-- EDUBREEDS 010: daily schedule, school holidays, and trip progress milestones.

-- 1. Schedule: every route has a start time and the weekdays it runs (1 = Monday ... 7 = Sunday).
--    Each day the app shows the day's trips automatically from this; nothing has to be created per day.
alter table routes add column if not exists start_time time;
alter table routes add column if not exists days int[] not null default '{1,2,3,4,5,6}';

-- 2. School holidays (no trips are scheduled on these dates)
create table if not exists holidays (
  id        uuid primary key default gen_random_uuid(),
  school_id uuid not null references schools(id) on delete cascade,
  on_date   date not null,
  reason    text,
  unique (school_id, on_date)
);
alter table holidays enable row level security;
drop policy if exists holiday_read on holidays;
drop policy if exists holiday_admin on holidays;
drop policy if exists holiday_super on holidays;
create policy holiday_read  on holidays for select using (school_id = auth_school());
create policy holiday_admin on holidays for all
  using (school_id = auth_school() and auth_role() = 'school_admin')
  with check (school_id = auth_school() and auth_role() = 'school_admin');
create policy holiday_super on holidays for all using (is_super()) with check (is_super());
grant select, insert, update, delete on holidays to authenticated, service_role;

-- 3. Progress milestones
alter table trips      add column if not exists school_reached_at timestamptz;
alter table trips      add column if not exists left_school_at    timestamptz;
alter table trip_stops add column if not exists arriving_at       timestamptz;

-- The van is close to a stop: parents get "get ready" and the progress bar moves to "arriving".
create or replace function mark_approaching(p_trip uuid, p_stop uuid) returns void
language plpgsql security definer set search_path = public as $$
declare t trips; ts record;
begin
  t := assert_my_trip(p_trip);
  for ts in select * from trip_stops where trip_id = p_trip and stop_id = p_stop and state = 'pending' and arriving_at is null loop
    update trip_stops set arriving_at = now() where id = ts.id;
    perform notify_guardians(t.school_id, ts.student_id, 'arriving',
      jsonb_build_object('trip_id', p_trip, 'text', 'The van is arriving at your stop. Get ready and wait for the van.'));
  end loop;
end $$;

-- DROP: the van has left the school with the students on board.
create or replace function mark_left_school(p_trip uuid) returns void
language plpgsql security definer set search_path = public as $$
declare t trips; ts record;
begin
  t := assert_my_trip(p_trip);
  if t.left_school_at is not null then return; end if;
  update trips set left_school_at = now() where id = p_trip;
  for ts in select * from trip_stops where trip_id = p_trip loop
    perform notify_guardians(t.school_id, ts.student_id, 'left_school',
      jsonb_build_object('trip_id', p_trip, 'text', 'The van has left the school.'));
  end loop;
end $$;

-- PICKUP: the van reached the school. Parents are told and the trip finishes by itself.
create or replace function mark_school_reached(p_trip uuid) returns void
language plpgsql security definer set search_path = public as $$
declare t trips; ts record; nm text;
begin
  t := assert_my_trip(p_trip);
  if t.school_reached_at is not null then return; end if;
  update trips set school_reached_at = now() where id = p_trip;
  for ts in select * from trip_stops where trip_id = p_trip and state = 'picked_up' loop
    select full_name into nm from students where id = ts.student_id;
    perform notify_guardians(t.school_id, ts.student_id, 'school_reached',
      jsonb_build_object('trip_id', p_trip, 'text', 'The van has reached the school. ' || nm || ' is at school.'));
  end loop;
  update trips set state = 'completed', ended_at = now() where id = p_trip;
  delete from live_positions where trip_id = p_trip;
end $$;

-- Only signed-in users call these; nobody else.
revoke execute on function mark_approaching(uuid, uuid), mark_left_school(uuid), mark_school_reached(uuid) from anon, public;
grant  execute on function mark_approaching(uuid, uuid), mark_left_school(uuid), mark_school_reached(uuid) to authenticated, service_role;

notify pgrst, 'reload schema';
