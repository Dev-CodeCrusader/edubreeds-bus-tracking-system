# EDUBREEDS App (Flutter): one codebase for Android and web, every role

One app serves every role. After sign-in, `profiles.role` decides the screens
(`lib/screens/role_gate.dart`). Only the **driver** screens are built so far; parent, caretaker,
school admin and super admin show a holding screen.

First build of the driver screens: login, shift start (Pickup / Drop, live selfie, student selection for Drop),
and the 50/50 ride screen (map on top, control deck below).

> **Not compiled or run yet.** The Flutter SDK could not be installed in the build environment,
> so this code has not been through `flutter analyze` or a device test. Expect a few small
> fixes on the first build (package versions, API differences). Send me the error output and I will fix it.

## What works in this version

- Mobile number + password login (WhatsApp OTP is added later, when the messaging API is ready).
- Pickup or Drop shift start, live selfie, parents notified ("School transportation has started").
- Drop: driver ticks the students who are in the van.
- Ride screen: MapLibre map (OpenFreeMap) with the stops, the bus position, and the next student card.
- Pickup buttons: **Picked Up**, **Absent** (with confirm), **Alert** (greyed out before the stop's scheduled time).
- 2-minute countdown after the scheduled time; early arrival does not start it. At zero:
  "Student Not Available/Ready" -> proof photo with GPS -> parent notified -> next student.
- Drop buttons: **Dropped**, **Nobody at stop** (logged), **Alert** (always on).
- Photo privacy toggle: when the school has photos off, the app shows initials instead of the student picture.
- Live position sent to Supabase every few seconds while the trip runs (foreground service keeps it alive).
- All rules (alert time gate, notifications, remarks, ownership) are enforced on the server in `supabase/002_driver_functions.sql`.

## Not built yet

- Turn-by-turn voice navigation (the route is drawn as straight lines between stops for now).
- Live ETAs.
- Actually delivering notifications to phones. The server writes rows to the `notifications` table;
  a Supabase Database Webhook + Edge Function that sends them through Firebase (FCM) is the next step,
  together with the parent and caretaker apps that receive and buzz.
- WhatsApp OTP login and WhatsApp alerts.

## Setup

1. **Database.** In the Supabase SQL Editor run `001_core_schema.sql` (already done), then
   `supabase/002_driver_functions.sql`.
2. **Create the Flutter project shell** (needs Flutter installed), then copy these files in:
   ```
   flutter create --org app.edubreeds --project-name edubreeds_app .
   ```
   Keep the `lib/` folder and `pubspec.yaml` from this package, then `flutter pub get`.
3. **Keys.** Edit `lib/config.dart`: the Supabase URL and the **anon** key (Project Settings -> API).
4. **Android permissions.** In `android/app/src/main/AndroidManifest.xml`, inside `<manifest>`:
   ```xml
   <uses-permission android:name="android.permission.INTERNET"/>
   <uses-permission android:name="android.permission.ACCESS_FINE_LOCATION"/>
   <uses-permission android:name="android.permission.ACCESS_COARSE_LOCATION"/>
   <uses-permission android:name="android.permission.FOREGROUND_SERVICE"/>
   <uses-permission android:name="android.permission.FOREGROUND_SERVICE_LOCATION"/>
   <uses-permission android:name="android.permission.CAMERA"/>
   <uses-permission android:name="android.permission.WAKE_LOCK"/>
   <uses-permission android:name="android.permission.POST_NOTIFICATIONS"/>
   ```
   Set `minSdkVersion` to 21 or higher in `android/app/build.gradle`.
5. **Run on Android:** `flutter run` on a real phone (location and camera need a real device).
6. **Run / build the web app (same code, same look):**
   ```
   flutter run -d chrome
   flutter build web --release
   ```
   Upload everything inside `build/web/` to a folder on your Hostinger hosting (for example
   `public_html/app/`; if it is not the site root, build with `--base-href /app/`). The site must use
   HTTPS, because browsers only allow camera and location on secure pages. Add the `.htaccess` below so
   refreshing a page does not give a 404:
   ```
   RewriteEngine On
   RewriteCond %{REQUEST_FILENAME} !-f
   RewriteCond %{REQUEST_FILENAME} !-d
   RewriteRule . index.html [L]
   ```
   Add your web address to Supabase -> Authentication -> URL Configuration -> Site URL.

## Web vs Android: what differs

- Browsers cannot track location with the screen off, so **drivers should run trips in the Android app**.
  The web app works for a driver only as a fallback, with the tab open and the screen on.
- Browsers cannot reliably buzz through silent mode. Parents and caretakers need the Android app for buzz alerts;
  the web app is fine for the live map and history.
- Everything else (screens, rules, data) is identical, because it is the same code.

## Creating a driver to test with

Everyone logs in with their mobile number, which the app maps to `<10-digit-number>@users.edubreeds.app`.

1. Supabase -> Authentication -> Users -> Add user: email `9XXXXXXXXX@users.edubreeds.app`,
   a password, and tick "Auto Confirm User".
2. In the SQL Editor, add the profile (use the new user's id and your school's id from the `schools` table):
   ```sql
   insert into profiles (id, school_id, role, full_name, phone)
   values ('<user-id>', '<school-id>', 'driver', 'Test Driver', '9XXXXXXXXX');
   ```
3. Add test data: a bus with `driver_id` = the user id, a route (`mode` pickup or drop, `bus_id` set),
   2 to 3 stops with a `location` (e.g. `'SRID=4326;POINT(85.8245 20.2961)'`), a `scheduled_time`,
   a few students, their parent profiles in `guardians`, and `stop_students` rows linking students to stops.

## Pilot-level shortcuts to tighten before go-live

- Storage policies let any signed-in user read and upload to the photo buckets.
- Phone-to-email login mapping is a stopgap until WhatsApp OTP exists.
- The phone's clock is used for the scheduled-time checks in the app (the server uses India time for the Alert gate).
