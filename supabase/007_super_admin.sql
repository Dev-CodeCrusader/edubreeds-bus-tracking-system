-- Makes one account the platform Super Admin.
-- BEFORE RUNNING: Supabase -> Authentication -> Users -> Add user -> Create new user
--   Email:    <mobile>@users.edubreeds.app   (example: 9000000001@users.edubreeds.app)
--   Password: your choice;  tick "Auto Confirm User"
-- Then change the two values below and run.

do $$
declare
  v_phone text := '9000000001';        -- <- the 10-digit number you used in the email
  v_name  text := 'EDUBREEDS Admin';   -- <- your name
  u uuid;
begin
  select id into u from auth.users where email = v_phone || '@users.edubreeds.app';
  if u is null then raise exception 'Create the user in Authentication first (email %@users.edubreeds.app)', v_phone; end if;
  insert into profiles (id, school_id, role, full_name, phone)
  values (u, null, 'super_admin', v_name, v_phone)
  on conflict (id) do update set role = 'super_admin', school_id = null, full_name = excluded.full_name, active = true;
  raise notice 'Done. % can sign in as Super Admin.', v_phone;
end $$;
