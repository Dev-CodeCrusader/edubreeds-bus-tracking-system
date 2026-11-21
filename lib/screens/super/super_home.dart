import 'package:flutter/material.dart';

import '../../api.dart';
import '../../util.dart';
import '../admin/admin_home.dart' show changeMyPassword;
import '../admin/people_panel.dart';

/// Platform owner: create schools (grouped into shared apps), and create their admins.
class SuperHome extends StatefulWidget {
  final DriverProfile me;
  const SuperHome({super.key, required this.me});

  @override
  State<SuperHome> createState() => _SuperHomeState();
}

class _SuperHomeState extends State<SuperHome> {
  int _tab = 0;
  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _schools = [];
  List<Map<String, dynamic>> _groups = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final s = await db.from('schools').select('id, name, city, group_id, photos_enabled, plan, app_groups(name)').order('name');
      final g = await db.from('app_groups').select('id, name').order('name');
      if (!mounted) return;
      setState(() {
        _schools = s.map<Map<String, dynamic>>((e) => Map<String, dynamic>.from(e)).toList();
        _groups = g.map<Map<String, dynamic>>((e) => Map<String, dynamic>.from(e)).toList();
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = errText(e);
      });
    }
  }

  Future<void> _addGroup() async {
    final c = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('New shared app (group of schools)'),
        content: TextField(controller: c, decoration: const InputDecoration(labelText: 'Group name')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(d, c.text.trim()), child: const Text('Create')),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    try {
      await db.from('app_groups').insert({'name': name});
      _load();
    } catch (e) {
      if (mounted) toast(context, errText(e));
    }
  }

  Future<void> _openSchool([Map<String, dynamic>? s]) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => SchoolScreen(school: s, groups: _groups)));
    _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(_tab == 0 ? 'Schools' : 'Settings'), actions: [signOutButton()]),
      body: _tab == 0 ? _schoolsTab() : _settingsTab(),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.apartment), label: 'Schools'),
          NavigationDestination(icon: Icon(Icons.settings), label: 'Settings'),
        ],
      ),
    );
  }

  Widget _schoolsTab() {
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
        child: Row(children: [
          OutlinedButton.icon(onPressed: _addGroup, icon: const Icon(Icons.apps), label: const Text('New app group')),
          const Spacer(),
          FilledButton.icon(onPressed: () => _openSchool(), icon: const Icon(Icons.add), label: const Text('Add school')),
        ]),
      ),
      Expanded(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error != null
                ? Center(child: Text('Could not load: $_error'))
                : RefreshIndicator(
                    onRefresh: _load,
                    child: ListView.separated(
                      itemCount: _schools.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (context, i) {
                        final s = _schools[i];
                        final g = (s['app_groups'] as Map?)?['name'];
                        return ListTile(
                          leading: const Icon(Icons.apartment),
                          title: Text(s['name'].toString()),
                          subtitle: Text([if (s['city'] != null) s['city'], if (g != null) 'App: $g'].join('  |  ')),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () => _openSchool(s),
                        );
                      },
                    ),
                  ),
      ),
    ]);
  }

  Widget _settingsTab() {
    return ListView(children: [
      Section(
        title: 'My account',
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('${widget.me.fullName}  |  Super admin'),
          const SizedBox(height: 8),
          OutlinedButton.icon(
              icon: const Icon(Icons.key), label: const Text('Change my password'), onPressed: () => changeMyPassword(context)),
        ]),
      ),
    ]);
  }
}

class SchoolScreen extends StatefulWidget {
  final Map<String, dynamic>? school;
  final List<Map<String, dynamic>> groups;
  const SchoolScreen({super.key, this.school, required this.groups});

  @override
  State<SchoolScreen> createState() => _SchoolScreenState();
}

class _SchoolScreenState extends State<SchoolScreen> {
  String? _id;
  late final TextEditingController _name = TextEditingController(text: widget.school?['name']?.toString() ?? '');
  late final TextEditingController _city = TextEditingController(text: widget.school?['city']?.toString() ?? '');
  String? _group;
  bool _photos = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final s = widget.school;
    if (s != null) {
      _id = s['id'].toString();
      _group = s['group_id']?.toString();
      _photos = s['photos_enabled'] != false;
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _city.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_name.text.trim().isEmpty) {
      toast(context, 'Enter the school name');
      return;
    }
    setState(() => _saving = true);
    try {
      final data = {
        'name': _name.text.trim(),
        'city': _city.text.trim().isEmpty ? null : _city.text.trim(),
        'group_id': _group,
        'photos_enabled': _photos,
      };
      if (_id == null) {
        final row = await db.from('schools').insert(data).select('id').single();
        _id = row['id'].toString();
      } else {
        await db.from('schools').update(data).eq('id', _id!);
      }
      if (!mounted) return;
      setState(() => _saving = false);
      toast(context, 'Saved. Now create the school admin below.');
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      toast(context, errText(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(_id == null ? 'New school' : (widget.school?['name']?.toString() ?? 'School'))),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        TextField(controller: _name, decoration: const InputDecoration(labelText: 'School name'), textCapitalization: TextCapitalization.words),
        TextField(controller: _city, decoration: const InputDecoration(labelText: 'City'), textCapitalization: TextCapitalization.words),
        const SizedBox(height: 8),
        DropdownButtonFormField<String?>(
          decoration: const InputDecoration(labelText: 'Shared app group'),
          value: _group,
          items: [
            const DropdownMenuItem<String?>(value: null, child: Text('None (own app / default)')),
            for (final g in widget.groups) DropdownMenuItem<String?>(value: g['id'].toString(), child: Text(g['name'].toString())),
          ],
          onChanged: (v) => setState(() => _group = v),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Show student pictures'),
          subtitle: const Text('Child-privacy switch. Off hides all student and stop pictures.'),
          value: _photos,
          onChanged: (v) => setState(() => _photos = v),
        ),
        FilledButton(onPressed: _saving ? null : _save, child: Text(_saving ? 'Saving...' : (_id == null ? 'Create school' : 'Save school'))),
        if (_id != null) ...[
          const SizedBox(height: 12),
          Section(
            title: 'People of this school',
            child: SizedBox(
              height: 520,
              child: PeoplePanel(schoolId: _id!, roles: const ['school_admin', 'driver', 'caretaker', 'parent']),
            ),
          ),
        ],
      ]),
    );
  }
}
