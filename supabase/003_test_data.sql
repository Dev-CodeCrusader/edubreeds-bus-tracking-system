-- EDUBREEDS test data: one driver, one bus, a pickup route and a drop route (3 stops each), 3 students.
-- Nothing to replace except the settings in the first block. Safe to run again (it rebuilds the test data).
--
-- BEFORE RUNNING: in Supabase -> Authentication -> Users -> Add user -> Create new user:
--   Email:    8260211553@users.edubreeds.app
--   Password: choose one (this is the driver's app password)
--   Tick "Auto Confirm User"

do $$
declare
  -- ------------------------------------------------ settings (edit these)
  v_phone   text   := '8260211553';
  v_school  text   := 'N K Public School, Bhubaneswar';
  v_name    text   := 'Test Driver';
  -- Put your real position here so the arrival check can trigger when you walk or drive to stop 1.
  -- (Google Maps: long-press a spot, copy the two numbers.) Stops 2 and 3 are placed a short way from it.
  v_lat     double precision := 20.2961;
  v_lng     double precision := 85.8245;
  -- ------------------------------------------------
  u uuid; s uuid; b uuid; r uuid; stp uuid; stu uuid;
  m text; i int; now_t time := date_trunc('minute', now() at time zone 'Asia/Kolkata')::time; -- whole minutes only
begin
  select id into u from auth.users where email = v_phone || '@users.edubreeds.app';
  if u is null then
    raise exception 'First create the user in Authentication -> Users with email %@users.edubreeds.app', v_phone;
  end if;
  select id into s from schools where name = v_school;
  if s is null then raise exception 'School "%" not found in the schools table', v_school; end if;

  insert into profiles (id, school_id, role, full_name, phone)
  values (u, s, 'driver', v_name, v_phone)
  on conflict (id) do update set school_id = excluded.school_id, role = 'driver', full_name = excluded.full_name;

  -- clear earlier test data
  delete from trips  where school_id = s and route_id in (select id from routes where school_id = s and name like 'TEST %');
  delete from routes where school_id = s and name like 'TEST %';
  delete from students where school_id = s and full_name like 'Test Student%';

  insert into buses (school_id, reg_no, capacity, driver_id)
  values (s, 'OD-02-TEST-0001', 30, u)
  on conflict (school_id, reg_no) do update set driver_id = u
  returning id into b;

  insert into students (school_id, full_name, class_name) values
    (s, 'Test Student One',   'Class 3'),
    (s, 'Test Student Two',   'Class 5'),
    (s, 'Test Student Three', 'Class 7');

  foreach m in array array['pickup', 'drop'] loop
    insert into routes (school_id, bus_id, name, mode, school_location, school_arrival)
    values (s, b, 'TEST ' || initcap(m) || ' route', m::trip_mode,
            st_setsrid(st_makepoint(v_lng + 0.02, v_lat + 0.02), 4326)::geography, '08:30')
    returning id into r;

    for i in 1..3 loop
      insert into stops (route_id, seq, name, location, radius_m, scheduled_time)
      values (r, i, 'Test stop ' || i,
              st_setsrid(st_makepoint(v_lng + (i - 1) * 0.004, v_lat + (i - 1) * 0.004), 4326)::geography,
              60,
              -- scheduled 5, 10 and 15 minutes from now, so the Alert button and countdown can be tested today
              now_t + (i * 5) * interval '1 minute')
      returning id into stp;

      select id into stu from students
      where school_id = s and full_name = case i when 1 then 'Test Student One' when 2 then 'Test Student Two' else 'Test Student Three' end;
      insert into stop_students (stop_id, student_id) values (stp, stu);
    end loop;
  end loop;

  raise notice 'Done. Driver % can now sign in with %.', v_name, v_phone;
end $$;
