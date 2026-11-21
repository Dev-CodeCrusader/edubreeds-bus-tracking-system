# Update 2: Parent, School Admin, Super Admin, Caretaker

Do these in order.

1. Supabase -> SQL Editor: run `supabase/006_parent_admin.sql` (once).
2. Deploy the login-creation function (needed to add drivers, parents, admins from the app):
   - Supabase -> Edge Functions -> Deploy a new function -> "Via Editor"
   - Name: `manage-user`
   - Paste the whole of `supabase/functions/manage-user/index.ts`, then Deploy.
   - Open the function's Settings and switch OFF "Verify JWT with legacy secret" if that option is shown
     (the function checks the signed-in user itself).
3. Create your Super Admin: follow the steps at the top of `supabase/007_super_admin.sql`, then run it.
4. Upload `lib/` to GitHub (replace/add the files), let the build finish, host the new web build.
5. Sign in as Super Admin -> Schools -> open the school -> People -> School admins -> Add.
   Then sign in as that school admin and add students, buses, routes, stops, drivers, parents.
