# Update 4: everything in one package (full project)

This zip is the WHOLE project. Upload it to GitHub (replace everything: lib/, pubspec.yaml, supabase/, .github/).

## A. Database (Supabase -> SQL Editor), run these if not run yet, in this order
006_parent_admin.sql, 007_super_admin.sql (edit the phone/name first), 008_complete.sql

## B. Edge Functions (Supabase -> Edge Functions -> Deploy a new function -> Via Editor)
1. `manage-user`  (paste supabase/functions/manage-user/index.ts)  - creates logins from the app
2. `push`         (paste supabase/functions/push/index.ts)         - sends phone alerts
   For both, switch OFF "Verify JWT" if the option is shown (they check access themselves).

## C. Phone alerts (push) - 6 steps, all free
1. Firebase console -> Project settings -> Your apps -> Add app -> Android.
   Package name: app.edubreeds.edubreeds_app   -> download `google-services.json`.
2. GitHub repo -> Settings -> Secrets and variables -> Actions -> New repository secret
   Name: GOOGLE_SERVICES_JSON   Value: paste the whole content of google-services.json.
3. Firebase -> Project settings -> Service accounts -> Generate new private key (downloads a JSON file).
4. Supabase -> Edge Functions -> Secrets, add:
   FIREBASE_SERVICE_ACCOUNT = the whole content of the private-key JSON
   PUSH_SECRET              = any long random text (remember it)
5. Supabase -> Database -> Webhooks -> Create a new hook:
   Table: notifications, Event: Insert, Type: Supabase Edge Functions -> `push`,
   HTTP header: x-webhook-secret = the same PUSH_SECRET.
6. Run the GitHub build again, install the new APK, sign in as a parent and allow notifications.
Without steps 1-6 the app still works; alerts then show only while the app is open.

## D. Then
Sign in as Super Admin -> Schools -> create school -> add the school admin. The school admin adds
students (with signed consent form before any picture), parents, drivers, buses, routes and stops.
