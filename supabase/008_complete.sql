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
