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
