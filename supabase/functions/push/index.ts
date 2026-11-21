// Supabase Edge Function: push
// Called by a Database Webhook on every INSERT into `notifications`. Sends the alert to the
// recipient's phone(s) through Firebase Cloud Messaging (HTTP v1).
// Secrets needed (Edge Functions -> Secrets):
//   FIREBASE_SERVICE_ACCOUNT : the whole service-account JSON from Firebase
//   PUSH_SECRET              : any long random text; the webhook sends it in the header x-webhook-secret
import { createClient } from 'npm:@supabase/supabase-js@2';
import { SignJWT, importPKCS8 } from 'npm:jose@5';

let cached: { token: string; exp: number } | null = null;

async function accessToken(sa: { client_email: string; private_key: string }) {
  const now = Math.floor(Date.now() / 1000);
  if (cached && cached.exp > now + 60) return cached.token;
  const key = await importPKCS8(sa.private_key, 'RS256');
  const jwt = await new SignJWT({ scope: 'https://www.googleapis.com/auth/firebase.messaging' })
    .setProtectedHeader({ alg: 'RS256', typ: 'JWT' })
    .setIssuer(sa.client_email).setSubject(sa.client_email)
    .setAudience('https://oauth2.googleapis.com/token')
    .setIssuedAt(now).setExpirationTime(now + 3600).sign(key);
  const r = await fetch('https://oauth2.googleapis.com/token', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({ grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer', assertion: jwt }),
  });
  const j = await r.json();
  if (!j.access_token) throw new Error('Google token error: ' + JSON.stringify(j));
  cached = { token: j.access_token, exp: now + 3500 };
  return cached.token;
}

Deno.serve(async (req) => {
  if (req.headers.get('x-webhook-secret') !== Deno.env.get('PUSH_SECRET')) {
    return new Response('forbidden', { status: 403 });
  }
  try {
    const body = await req.json();
    const rec = body.record;
    if (!rec?.recipient_id) return new Response('no record', { status: 200 });

    const admin = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
    const { data: tokens } = await admin.from('device_tokens').select('token').eq('user_id', rec.recipient_id);
    if (!tokens || tokens.length === 0) return new Response('no devices', { status: 200 });

    const sa = JSON.parse(Deno.env.get('FIREBASE_SERVICE_ACCOUNT')!);
    const access = await accessToken(sa);
    const urgent = rec.kind === 'arrived' || rec.kind === 'alert';
    const text = rec.payload?.text ?? 'New alert from your school bus';

    for (const t of tokens) {
      const r = await fetch(`https://fcm.googleapis.com/v1/projects/${sa.project_id}/messages:send`, {
        method: 'POST',
        headers: { Authorization: `Bearer ${access}`, 'Content-Type': 'application/json' },
        body: JSON.stringify({
          message: {
            token: t.token,
            notification: { title: urgent ? 'EDUBREEDS ALERT' : 'EDUBREEDS', body: text },
            data: { kind: String(rec.kind), trip_id: String(rec.payload?.trip_id ?? '') },
            android: { priority: 'HIGH', notification: { sound: 'default' } },
          },
        }),
      });
      if (r.status === 404 || r.status === 400) {
        const e = await r.json().catch(() => ({}));
        if (JSON.stringify(e).includes('UNREGISTERED') || JSON.stringify(e).includes('INVALID_ARGUMENT')) {
          await admin.from('device_tokens').delete().eq('token', t.token); // phone no longer has the app
        }
      }
    }
    return new Response('ok');
  } catch (e) {
    return new Response(String(e), { status: 500 });
  }
});
