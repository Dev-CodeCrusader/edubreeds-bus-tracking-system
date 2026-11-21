import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show UserAttributes;

import '../../api.dart';
import '../../util.dart';
import 'fleet_tab.dart';
import 'holidays_panel.dart';
import 'live_trips.dart';
import 'people_panel.dart';
import 'students_tab.dart';

/// School admin app: live trips, students, staff and parents, buses/routes, and school settings.
class AdminHome extends StatefulWidget {
  final DriverProfile me;
  const AdminHome({super.key, required this.me});

  @override
  State<AdminHome> createState() => _AdminHomeState();
}

class _AdminHomeState extends State<AdminHome> {
  int _tab = 0;
  late bool _photos = widget.me.photosEnabled;

  static const _titles = ['Today', 'Students', 'People', 'Fleet', 'Settings'];

  @override
  Widget build(BuildContext context) {
    final me = widget.me;
    final pages = <Widget>[
      LiveTripsView(me: me),
      StudentsTab(me: me),
      PeoplePanel(schoolId: me.schoolId!, roles: const ['driver', 'caretaker', 'parent']),
      FleetTab(me: me),
      _settings(),
    ];
    return Scaffold(
      appBar: AppBar(title: Text('${_titles[_tab]}  |  ${me.schoolName}'), actions: [signOutButton()]),
      body: IndexedStack(index: _tab, children: pages),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.today), label: 'Today'),
          NavigationDestination(icon: Icon(Icons.school), label: 'Students'),
          NavigationDestination(icon: Icon(Icons.groups), label: 'People'),
          NavigationDestination(icon: Icon(Icons.directions_bus), label: 'Fleet'),
          NavigationDestination(icon: Icon(Icons.settings), label: 'Settings'),
        ],
      ),
    );
  }

  Widget _settings() {
    return ListView(children: [
      Section(
        title: 'Child privacy',
        child: Card(
          child: SwitchListTile(
            title: const Text('Show student and stop pictures'),
            subtitle: const Text('Turn off to hide all student profile pictures in the app. '
                'Only turn on if signed parental consent is on file.'),
            value: _photos,
            onChanged: (v) async {
              try {
                await db.from('schools').update({'photos_enabled': v}).eq('id', widget.me.schoolId!);
                setState(() => _photos = v);
                if (mounted) toast(context, 'Saved. Everyone sees the change after they reopen the app.');
              } catch (e) {
                if (mounted) toast(context, errText(e));
              }
            },
          ),
        ),
      ),
      Section(title: 'School holidays', child: HolidaysPanel(schoolId: widget.me.schoolId!)),
      Section(
        title: 'My account',
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('${widget.me.fullName}  |  School admin'),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            icon: const Icon(Icons.key),
            label: const Text('Change my password'),
            onPressed: () => changeMyPassword(context),
          ),
        ]),
      ),
    ]);
  }
}

/// Lets any signed-in user change their own password.
Future<void> changeMyPassword(BuildContext context) async {
  final pw = await askPassword(context, 'yourself');
  if (pw == null) return;
  if (pw.length < 6) {
    if (context.mounted) toast(context, 'Password must be at least 6 characters');
    return;
  }
  try {
    await db.auth.updateUser(UserAttributes(password: pw));
    if (context.mounted) toast(context, 'Password changed.');
  } catch (e) {
    if (context.mounted) toast(context, errText(e));
  }
}
