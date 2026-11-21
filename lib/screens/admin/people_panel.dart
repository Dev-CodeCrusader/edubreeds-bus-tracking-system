import 'package:flutter/material.dart';

import '../../admin_api.dart';
import '../../api.dart';
import '../../util.dart';

const roleLabels = {
  'school_admin': 'School admin',
  'driver': 'Driver',
  'caretaker': 'Caretaker',
  'parent': 'Parent',
};

/// Dialog to create a login (name, mobile number, password). Returns the new user id, or null if cancelled.
Future<String?> createPersonDialog(
  BuildContext context, {
  required String role,
  required String schoolId,
  String? phone,
  String? name,
}) {
  final nameC = TextEditingController(text: name ?? '');
  final phoneC = TextEditingController(text: phone ?? '');
  final passC = TextEditingController();
  bool busy = false;
  String? error;
  return showDialog<String>(
    context: context,
    barrierDismissible: false,
    builder: (c) => StatefulBuilder(
      builder: (c, setS) => AlertDialog(
        title: Text('Add ${roleLabels[role]?.toLowerCase() ?? role}'),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(controller: nameC, decoration: const InputDecoration(labelText: 'Full name'), textCapitalization: TextCapitalization.words),
            TextField(
                controller: phoneC,
                decoration: const InputDecoration(labelText: 'Mobile number (10 digits)'),
                keyboardType: TextInputType.phone),
            TextField(controller: passC, decoration: const InputDecoration(labelText: 'Password (min 6 characters)')),
            if (error != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(error!, style: const TextStyle(color: Colors.red))),
          ]),
        ),
        actions: [
          TextButton(onPressed: busy ? null : () => Navigator.pop(c), child: const Text('Cancel')),
          FilledButton(
            onPressed: busy
                ? null
                : () async {
                    setS(() {
                      busy = true;
                      error = null;
                    });
                    try {
                      final id = await AdminApi.createUser(
                          phone: phoneC.text, password: passC.text, fullName: nameC.text, role: role, schoolId: schoolId);
                      if (c.mounted) Navigator.pop(c, id);
                    } catch (e) {
                      setS(() {
                        busy = false;
                        error = errText(e);
                      });
                    }
                  },
            child: Text(busy ? 'Saving...' : 'Create'),
          ),
        ],
      ),
    ),
  );
}

Future<String?> askPassword(BuildContext context, String who) {
  final c = TextEditingController();
  return showDialog<String>(
    context: context,
    builder: (d) => AlertDialog(
      title: Text('New password for $who'),
      content: TextField(controller: c, decoration: const InputDecoration(labelText: 'New password (min 6 characters)')),
      actions: [
        TextButton(onPressed: () => Navigator.pop(d), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(d, c.text), child: const Text('Save')),
      ],
    ),
  );
}

/// List of people of one school by role, with add / reset password / switch off.
class PeoplePanel extends StatefulWidget {
  final String schoolId;
  final List<String> roles;
  const PeoplePanel({super.key, required this.schoolId, required this.roles});

  @override
  State<PeoplePanel> createState() => _PeoplePanelState();
}

class _PeoplePanelState extends State<PeoplePanel> {
  late String _role = widget.roles.first;
  List<Map<String, dynamic>> _rows = [];
  bool _loading = true;
  String? _error;
  String _search = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final r = await db
          .from('profiles')
          .select('id, full_name, phone, active')
          .eq('school_id', widget.schoolId)
          .eq('role', _role)
          .order('full_name');
      if (!mounted) return;
      setState(() {
        _rows = r.map<Map<String, dynamic>>((e) => Map<String, dynamic>.from(e)).toList();
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

  Future<void> _add() async {
    final id = await createPersonDialog(context, role: _role, schoolId: widget.schoolId);
    if (id != null) {
      if (mounted) toast(context, 'Account created. They can sign in with the mobile number and this password.');
      _load();
    }
  }

  Future<void> _menu(String action, Map<String, dynamic> p) async {
    try {
      if (action == 'password') {
        final pw = await askPassword(context, p['full_name'].toString());
        if (pw == null) return;
        await AdminApi.setPassword(p['id'].toString(), pw);
        if (mounted) toast(context, 'Password changed.');
      } else {
        final makeActive = p['active'] != true;
        if (!makeActive && !await confirm(context, 'Switch off ${p['full_name']}?', 'They will not be able to sign in.', yes: 'Switch off')) return;
        await AdminApi.setActive(p['id'].toString(), makeActive);
        _load();
      }
    } catch (e) {
      if (mounted) toast(context, errText(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final shown = _rows.where((r) {
      if (_search.isEmpty) return true;
      final s = _search.toLowerCase();
      return r['full_name'].toString().toLowerCase().contains(s) || (r['phone'] ?? '').toString().contains(s);
    }).toList();
    return Column(children: [
      if (widget.roles.length > 1)
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
          child: Wrap(spacing: 8, children: [
            for (final r in widget.roles)
              ChoiceChip(
                label: Text('${roleLabels[r] ?? r}s'),
                selected: _role == r,
                onSelected: (_) {
                  setState(() => _role = r);
                  _load();
                },
              ),
          ]),
        ),
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
        child: Row(children: [
          Expanded(
            child: TextField(
              decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Search name or number', isDense: true),
              onChanged: (v) => setState(() => _search = v.trim()),
            ),
          ),
          const SizedBox(width: 8),
          FilledButton.icon(onPressed: _add, icon: const Icon(Icons.person_add), label: const Text('Add')),
        ]),
      ),
      Expanded(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error != null
                ? Center(child: Text('Could not load: $_error'))
                : shown.isEmpty
                    ? const Center(child: Text('Nobody here yet.'))
                    : RefreshIndicator(
                        onRefresh: _load,
                        child: ListView.separated(
                          itemCount: shown.length,
                          separatorBuilder: (_, __) => const Divider(height: 1),
                          itemBuilder: (context, i) {
                            final p = shown[i];
                            final active = p['active'] == true;
                            return ListTile(
                              leading: CircleAvatar(child: Text(p['full_name'].toString().isEmpty ? '?' : p['full_name'].toString()[0].toUpperCase())),
                              title: Text(p['full_name'].toString(),
                                  style: TextStyle(decoration: active ? null : TextDecoration.lineThrough)),
                              subtitle: Text('${p['phone'] ?? ''}${active ? '' : '  (switched off)'}'),
                              trailing: PopupMenuButton<String>(
                                onSelected: (a) => _menu(a, p),
                                itemBuilder: (_) => [
                                  const PopupMenuItem(value: 'password', child: Text('Reset password')),
                                  PopupMenuItem(value: 'active', child: Text(active ? 'Switch off' : 'Switch on')),
                                ],
                              ),
                            );
                          },
                        ),
                      ),
      ),
    ]);
  }
}
