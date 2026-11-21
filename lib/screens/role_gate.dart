import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../api.dart';
import '../branding.dart';
import '../push_service.dart';
import 'admin/admin_home.dart';
import 'caretaker/caretaker_home.dart';
import 'home_screen.dart';
import 'parent/parent_home.dart';
import 'super/super_home.dart';

/// One app for everyone: after sign-in the user's role (from `profiles.role`)
/// decides which screens they see. Only the driver screens exist so far; the other
/// roles are handled by their own home screens.
class RoleGate extends StatefulWidget {
  const RoleGate({super.key});

  @override
  State<RoleGate> createState() => _RoleGateState();
}

class _RoleGateState extends State<RoleGate> {
  // Loaded once. (A sign-in token refresh rebuilds this widget; it must not reload the profile
  // and throw the user back to the start of their screen.)
  late final Future<DriverProfile> _profile = Api.myProfile().then((p) {
    brandColor.value = parseHexColor(p.brandHex) ?? defaultBrandColor; // white-label colour
    Push.register(); // phone alerts (Android); safe no-op elsewhere
    return p;
  });

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<DriverProfile>(
      future: _profile,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Scaffold(body: Center(child: CircularProgressIndicator()));
        }
        if (snap.hasError || !snap.hasData) {
          // Show the real reason so a setup problem can be found quickly.
          return _Message(
            title: 'Could not load your account',
            body: 'Your login works, but your profile could not be read.\n\n'
                'Details: ${snap.error ?? 'no data'}\n\n'
                'Signed in as: ${Supabase.instance.client.auth.currentUser?.email}',
          );
        }
        switch (snap.data!.role) {
          case 'driver':
            return const HomeScreen();
          case 'parent':
            return ParentHome(me: snap.data!);
          case 'caretaker':
            return CaretakerHome(me: snap.data!);
          case 'school_admin':
            return AdminHome(me: snap.data!);
          case 'super_admin':
            return SuperHome(me: snap.data!);
          default:
            return _Message(title: 'Unknown role', body: 'Please contact support.');
        }
      },
    );
  }
}

class _Message extends StatelessWidget {
  final String title;
  final String body;
  const _Message({required this.title, required this.body});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(title), actions: [
        IconButton(
          tooltip: 'Sign out',
          icon: const Icon(Icons.logout),
          onPressed: () => Supabase.instance.client.auth.signOut(),
        ),
      ]),
      body: Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(body, textAlign: TextAlign.center))),
    );
  }
}
