// Fill these from Supabase: Project Settings -> API.
// Use the anon (public) key only. Never put the service_role key in the app.
const supabaseUrl = 'https://xynozwjrneoxtkrfmjxv.supabase.co';
const supabaseAnonKey = 'sb_publishable_bWH7KziXZipGg6cIF0Mo7A_LVtG9mij';

// Free community map style (OpenFreeMap). Replace with self-hosted tiles before go-live.
const mapStyleUrl = 'https://tiles.openfreemap.org/styles/liberty';

// Every user signs in with a mobile number and password. Supabase needs an email-shaped
// identifier, so the number is mapped to a private address. The admin creates the same
// address when adding the account (see README).
String phoneToLogin(String phone) {
  final digits = phone.replaceAll(RegExp(r'[^0-9]'), '');
  final national = digits.length > 10 ? digits.substring(digits.length - 10) : digits;
  return '$national@users.edubreeds.app';
}

// Road routing server. Start with your own OSRM server once it is running (see routing-server/README.md),
// e.g. 'https://route.edubreeds.org'. The public demo server is the fallback if yours is unreachable.
const routingBaseUrl = 'https://router.project-osrm.org';
const routingFallbackUrl = 'https://router.project-osrm.org';

const approachMeters = 400; // "van is arriving" is sent to parents when the van is this close to their stop
const schoolRadiusM = 150; // the van counts as "at school" inside this distance
const leftSchoolM = 250; // ...and as "left school" beyond this distance (drop trips)
const countdownSeconds = 120; // wait after the scheduled pickup time before "Not Available/Ready"
const alertBuzzSeconds = 60;
