// Supabase Edge Function: manage-user
// Lets admins create logins (mobile number + password), reset passwords and switch accounts on/off.
// The service-role key stays here on the server; the app never sees it.
//   - super_admin: may create any role, in any school
//   - school_admin: may create driver / parent / caretaker in their own school only
import { createClient } from 'npm:@supabase/supabase-js@2';

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } });

const ROLES = ['super_admin', 'school_admin', 'driver', 'parent', 'caretaker'];

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  try {
    const url = Deno.env.get('SUPABASE_URL')!;
    const service = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
    const admin = createClient(url, service);

    // who is calling?
    const jwt = (req.headers.get('Authorization') ?? '').replace('Bearer ', '');
    const { data: u } = await admin.auth.getUser(jwt);
    if (!u?.user) return json({ error: 'Not signed in' }, 401);
    const { data: me } = await admin.from('profiles').select('role, school_id, active').eq('id', u.user.id).single();
    if (!me || !me.active || !['super_admin', 'school_admin'].includes(me.role)) {
      return json({ error: 'Not allowed' }, 403);
    }
    const isSuper = me.role === 'super_admin';

    const b = await req.json();
    const action = b.action as string;

    if (action === 'create') {
      const digits = String(b.phone ?? '').replace(/[^0-9]/g, '');
      const phone = digits.slice(-10);
      if (phone.length !== 10) return json({ error: 'Enter a 10-digit mobile number' }, 400);
      const password = String(b.password ?? '');
      if (password.length < 6) return json({ error: 'Password must be at least 6 characters' }, 400);
      const fullName = String(b.full_name ?? '').trim();
      if (!fullName) return json({ error: 'Name is required' }, 400);
      const role = String(b.role ?? '');
      if (!ROLES.includes(role)) return json({ error: 'Unknown role' }, 400);

      let schoolId: string | null = null;
      if (isSuper) {
        if (role !== 'super_admin') {
          schoolId = b.school_id ?? null;
          if (!schoolId) return json({ error: 'Choose a school' }, 400);
        }
      } else {
        if (!['driver', 'parent', 'caretaker'].includes(role)) return json({ error: 'Not allowed for this role' }, 403);
        schoolId = me.school_id;
      }

      const email = `${phone}@users.edubreeds.app`;
      const { data: created, error: cErr } = await admin.auth.admin.createUser({
        email, password, email_confirm: true,
      });
      if (cErr || !created?.user) {
        const msg = cErr?.message ?? 'Could not create the login';
        return json({ error: /already|registered|exists/i.test(msg) ? 'This mobile number already has an account' : msg }, 400);
      }
      const { error: pErr } = await admin.from('profiles').insert({
        id: created.user.id, school_id: schoolId, role, full_name: fullName, phone,
      });
      if (pErr) {
        await admin.auth.admin.deleteUser(created.user.id);
        return json({ error: pErr.message }, 400);
      }
      return json({ user_id: created.user.id });
    }

    // the remaining actions act on an existing user
    const { data: target } = await admin.from('profiles').select('id, role, school_id').eq('id', b.user_id).single();
    if (!target) return json({ error: 'User not found' }, 404);
    if (!isSuper && (target.school_id !== me.school_id || ['super_admin', 'school_admin'].includes(target.role))) {
      return json({ error: 'Not allowed' }, 403);
    }

    if (action === 'set_password') {
      const password = String(b.password ?? '');
      if (password.length < 6) return json({ error: 'Password must be at least 6 characters' }, 400);
      const { error } = await admin.auth.admin.updateUserById(target.id, { password });
      if (error) return json({ error: error.message }, 400);
      return json({ ok: true });
    }

    if (action === 'set_active') {
      const active = !!b.active;
      await admin.from('profiles').update({ active }).eq('id', target.id);
      await admin.auth.admin.updateUserById(target.id, { ban_duration: active ? 'none' : '876000h' });
      return json({ ok: true });
    }

    return json({ error: 'Unknown action' }, 400);
  } catch (e) {
    return json({ error: String(e) }, 500);
  }
});
