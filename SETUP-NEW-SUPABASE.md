# Setting up the NEW Supabase project (Mumbai)

The app already points to the new project (lib/config.dart). The new project is empty, so it needs
the database, two functions and your first accounts. Follow in order. About 20 minutes.

## 1. Database  (Supabase -> SQL Editor -> New query)
Open `supabase/SETUP_ALL_IN_ONE.sql`, paste ALL of it, press Run. It must finish with "Success".
(It creates every table, rule, function, storage bucket and permission in the right order.)
If it stops with an error, send me the error text and the line it names. Do not run it twice
after a partial failure without telling me, because the first half would already exist.

## 2. Your Super Admin login
- Authentication -> Users -> Add user -> Create new user
  Email: 9000000001@users.edubreeds.app   (use your own 10-digit number before the @)
  Password: your choice.  Tick "Auto Confirm User".
- SQL Editor: open `supabase/007_super_admin.sql`, put the same number and your name at the top, Run.

## 3. The two Edge Functions  (Edge Functions -> Deploy a new function -> Via Editor)
- Name `manage-user`: paste `supabase/functions/manage-user/index.ts`, Deploy.
- Name `push` (only needed for phone alerts): paste `supabase/functions/push/index.ts`, Deploy.
- For each, turn OFF "Verify JWT" if you see that option (the code checks access itself).

## 4. Build and host the app
Upload this whole project to GitHub (it replaces the old files), wait for the build, and host the new
web files. Users must sign in again (the old Supabase accounts do not exist in the new project).

## 5. Create the real data from inside the app (no SQL needed)
Sign in as Super Admin -> Schools -> Add school ("N K Public School, Bhubaneswar") -> open it ->
People -> School admins -> Add. Repeat for Daspalla (or add both schools under one app group:
"New app group", then pick it in each school).
Then sign in as a school admin: Fleet (buses, routes, stops), People (drivers, parents), Students.

## 6. Optional quick test data
`supabase/003_test_data.sql` creates a test driver, route and students for the first school.
It needs the school to exist under the exact name in its first lines and a driver login created
first (instructions at the top of that file). Skip it if you will enter real data.

## 7. Phone alerts later
Follow section C of SETUP-UPDATE-4.md. It needs this new project's Edge Function secrets and webhook,
so do it after steps 1-5 work.

## 8. Move the old project data? 
Only the test data existed, so nothing needs migrating. You can pause the Indonesia project.
