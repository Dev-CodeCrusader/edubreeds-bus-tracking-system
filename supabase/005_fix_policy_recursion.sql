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
