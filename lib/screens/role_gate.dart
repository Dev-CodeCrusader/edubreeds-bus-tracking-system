import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../api.dart';
import 'home_screen.dart';

/// One app for everyone: after sign-in the user's role (from `profiles.role`)
/// decides which screens they see. Only the driver screens exist so far; the other
/// roles get a holding screen until their modules are built.
class RoleGate extends StatelessWidget {
  const RoleGate({super.key});

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<DriverProfile>(
      future: Api.myProfile(),
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
            return _Message(title: 'Parent', body: 'Live tracking and alerts are coming in the next build.');
          case 'caretaker':
            return _Message(title: 'Caretaker', body: 'The school gate screen is coming in the next build.');
          case 'school_admin':
            return _Message(title: 'School Admin', body: 'Admin screens are coming in a later build.');
          case 'super_admin':
            return _Message(title: 'Super Admin', body: 'Platform screens are coming in a later build.');
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
