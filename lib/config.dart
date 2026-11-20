// Fill these from Supabase: Project Settings -> API.
// Use the anon (public) key only. Never put the service_role key in the app.
const supabaseUrl = 'https://YOUR-PROJECT.supabase.co';
const supabaseAnonKey = 'YOUR-ANON-KEY';

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

const countdownSeconds = 120; // wait after the scheduled pickup time before "Not Available/Ready"
const alertBuzzSeconds = 60;
