import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show FileOptions;

import '../../api.dart';
import '../../util.dart';
import 'people_panel.dart';

/// School admin: list of students; tap one to edit, link parents and set stops.
class StudentsTab extends StatefulWidget {
  final DriverProfile me;
  const StudentsTab({super.key, required this.me});

  @override
  State<StudentsTab> createState() => _StudentsTabState();
}

class _StudentsTabState extends State<StudentsTab> {
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
          .from('students')
          .select('id, full_name, class_name, photo_url, active')
          .eq('school_id', widget.me.schoolId!)
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

  Future<void> _open([Map<String, dynamic>? s]) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => StudentForm(me: widget.me, student: s)));
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final shown = _rows.where((r) {
      if (_search.isEmpty) return true;
      final q = _search.toLowerCase();
      return r['full_name'].toString().toLowerCase().contains(q) || (r['class_name'] ?? '').toString().toLowerCase().contains(q);
    }).toList();
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
        child: Row(children: [
          Expanded(
            child: TextField(
              decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Search name or class', isDense: true),
              onChanged: (v) => setState(() => _search = v.trim()),
            ),
          ),
          const SizedBox(width: 8),
          FilledButton.icon(onPressed: () => _open(), icon: const Icon(Icons.add), label: const Text('Add student')),
        ]),
      ),
      Expanded(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error != null
                ? Center(child: Text('Could not load: $_error'))
                : shown.isEmpty
                    ? const Center(child: Text('No students yet.'))
                    : RefreshIndicator(
                        onRefresh: _load,
                        child: ListView.separated(
                          itemCount: shown.length,
                          separatorBuilder: (_, __) => const Divider(height: 1),
                          itemBuilder: (context, i) {
                            final s = shown[i];
                            return ListTile(
                              leading: StudentAvatar(
                                  name: s['full_name'].toString(),
                                  photoPath: s['photo_url'] as String?,
                                  photosEnabled: widget.me.photosEnabled,
                                  radius: 20),
                              title: Text(s['full_name'].toString(),
                                  style: TextStyle(decoration: s['active'] == true ? null : TextDecoration.lineThrough)),
                              subtitle: Text(s['class_name']?.toString() ?? ''),
                              trailing: const Icon(Icons.chevron_right),
                              onTap: () => _open(s),
                            );
                          },
                        ),
                      ),
      ),
    ]);
  }
}

class StudentForm extends StatefulWidget {
  final DriverProfile me;
  final Map<String, dynamic>? student;
  const StudentForm({super.key, required this.me, this.student});

  @override
  State<StudentForm> createState() => _StudentFormState();
}

class _StudentFormState extends State<StudentForm> {
  String? _id;
  late final TextEditingController _name = TextEditingController(text: widget.student?['full_name']?.toString() ?? '');
  late final TextEditingController _class = TextEditingController(text: widget.student?['class_name']?.toString() ?? '');
  bool _active = true;
  XFile? _photo;
  Uint8List? _photoBytes;
  String? _photoPath;
  bool _saving = false;

  List<Map<String, dynamic>> _guardians = [];
  List<Map<String, dynamic>> _routes = [];
  final Map<String, String?> _stopByRoute = {};

  @override
  void initState() {
    super.initState();
    _id = widget.student?['id']?.toString();
    _active = widget.student?['active'] != false;
    _photoPath = widget.student?['photo_url'] as String?;
    if (_id != null) _loadExtras();
  }

  @override
  void dispose() {
    _name.dispose();
    _class.dispose();
    super.dispose();
  }

  Future<void> _loadExtras() async {
    try {
      final g = await db.from('guardians').select('parent_id, profiles(full_name, phone)').eq('student_id', _id!);
      final r = await db
          .from('routes')
          .select('id, name, mode, stops(id, name, seq)')
          .eq('school_id', widget.me.schoolId!)
          .order('name');
      final a = await db.from('stop_students').select('stop_id').eq('student_id', _id!);
      final mine = a.map((e) => e['stop_id'].toString()).toSet();
      final routes = r.map<Map<String, dynamic>>((e) => Map<String, dynamic>.from(e)).toList();
      final by = <String, String?>{};
      for (final rt in routes) {
        final stops = (rt['stops'] as List).map((s) => Map<String, dynamic>.from(s as Map)).toList();
        by[rt['id'].toString()] = stops.map((s) => s['id'].toString()).firstWhere(mine.contains, orElse: () => '');
        if (by[rt['id'].toString()] == '') by[rt['id'].toString()] = null;
      }
      if (!mounted) return;
      setState(() {
        _guardians = g.map<Map<String, dynamic>>((e) => Map<String, dynamic>.from(e)).toList();
        _routes = routes;
        _stopByRoute
          ..clear()
          ..addAll(by);
      });
    } catch (e) {
      if (mounted) toast(context, 'Could not load details: ${errText(e)}');
    }
  }

  Future<void> _pickPhoto() async {
    final x = await ImagePicker().pickImage(source: ImageSource.gallery, imageQuality: 70, maxWidth: 800);
    if (x == null) return;
    final b = await x.readAsBytes();
    setState(() {
      _photo = x;
      _photoBytes = b;
    });
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    if (name.isEmpty) {
      toast(context, 'Enter the student\'s name');
      return;
    }
    setState(() => _saving = true);
    try {
      final data = {
        'full_name': name,
        'class_name': _class.text.trim().isEmpty ? null : _class.text.trim(),
        'active': _active,
      };
      if (_id == null) {
        final row = await db.from('students').insert({...data, 'school_id': widget.me.schoolId}).select('id').single();
        _id = row['id'].toString();
      } else {
        await db.from('students').update(data).eq('id', _id!);
      }
      if (_photo != null) {
        final bytes = _photoBytes ?? await _photo!.readAsBytes();
        final path = '${widget.me.schoolId}/${_id}_${DateTime.now().millisecondsSinceEpoch}.jpg';
        await db.storage
            .from('student-photos')
            .uploadBinary(path, bytes, fileOptions: const FileOptions(contentType: 'image/jpeg'));
        await db.from('students').update({'photo_url': path}).eq('id', _id!);
        _photoPath = path;
        _photo = null;
      }
      if (!mounted) return;
      toast(context, 'Saved.');
      setState(() => _saving = false);
      _loadExtras();
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      toast(context, errText(e));
    }
  }

  Future<void> _addGuardian() async {
    final c = TextEditingController();
    final phone = await showDialog<String>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('Add a parent / guardian'),
        content: TextField(
            controller: c, decoration: const InputDecoration(labelText: 'Parent mobile number'), keyboardType: TextInputType.phone),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(d, c.text), child: const Text('Next')),
        ],
      ),
    );
    if (phone == null) return;
    final digits = phone.replaceAll(RegExp(r'[^0-9]'), '');
    final p10 = digits.length > 10 ? digits.substring(digits.length - 10) : digits;
    if (p10.length != 10) {
      if (mounted) toast(context, 'Enter a 10-digit mobile number');
      return;
    }
    try {
      final found = await db.from('profiles').select('id, role').eq('school_id', widget.me.schoolId!).eq('phone', p10).maybeSingle();
      String? parentId;
      if (found != null) {
        if (found['role'] != 'parent') {
          if (mounted) toast(context, 'That number belongs to a ${found['role']}, not a parent.');
          return;
        }
        parentId = found['id'].toString();
      } else {
        if (!mounted) return;
        parentId = await createPersonDialog(context, role: 'parent', schoolId: widget.me.schoolId!, phone: p10);
      }
      if (parentId == null) return;
      await db.from('guardians').insert({'student_id': _id, 'parent_id': parentId});
      _loadExtras();
    } catch (e) {
      if (mounted) toast(context, errText(e));
    }
  }

  Future<void> _removeGuardian(String parentId) async {
    try {
      await db.from('guardians').delete().eq('student_id', _id!).eq('parent_id', parentId);
      _loadExtras();
    } catch (e) {
      if (mounted) toast(context, errText(e));
    }
  }

  Future<void> _setStop(Map<String, dynamic> route, String? stopId) async {
    final stopIds = (route['stops'] as List).map((s) => (s as Map)['id'].toString()).toList();
    try {
      if (stopIds.isNotEmpty) {
        await db.from('stop_students').delete().eq('student_id', _id!).inFilter('stop_id', stopIds);
      }
      if (stopId != null) await db.from('stop_students').insert({'stop_id': stopId, 'student_id': _id});
      setState(() => _stopByRoute[route['id'].toString()] = stopId);
    } catch (e) {
      if (mounted) toast(context, errText(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final photoWidget = _photoBytes != null
        ? CircleAvatar(radius: 40, backgroundImage: MemoryImage(_photoBytes!))
        : StudentAvatar(name: _name.text, photoPath: _photoPath, photosEnabled: true, radius: 40);
    return Scaffold(
      appBar: AppBar(title: Text(_id == null ? 'New student' : 'Student')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Row(children: [
          photoWidget,
          const SizedBox(width: 16),
          OutlinedButton.icon(onPressed: _pickPhoto, icon: const Icon(Icons.photo), label: const Text('Choose photo')),
        ]),
        if (!widget.me.photosEnabled)
          const Padding(
            padding: EdgeInsets.only(top: 6),
            child: Text('Pictures are switched off for this school, so they are hidden in the app.',
                style: TextStyle(fontSize: 12, color: Colors.grey)),
          ),
        const SizedBox(height: 12),
        TextField(controller: _name, decoration: const InputDecoration(labelText: 'Full name'), textCapitalization: TextCapitalization.words),
        TextField(controller: _class, decoration: const InputDecoration(labelText: 'Class (e.g. Class 5)')),
        SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('Active (uses the bus)'), value: _active, onChanged: (v) => setState(() => _active = v)),
        FilledButton(onPressed: _saving ? null : _save, child: Text(_saving ? 'Saving...' : (_id == null ? 'Create student' : 'Save changes'))),
        if (_id != null) ...[
          const SizedBox(height: 8),
          Section(
            title: 'Parents / guardians',
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (_guardians.isEmpty) const Text('No parent linked yet.', style: TextStyle(color: Colors.grey)),
              for (final g in _guardians)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.family_restroom),
                  title: Text((g['profiles'] as Map?)?['full_name']?.toString() ?? 'Parent'),
                  subtitle: Text((g['profiles'] as Map?)?['phone']?.toString() ?? ''),
                  trailing: IconButton(icon: const Icon(Icons.link_off), tooltip: 'Remove', onPressed: () => _removeGuardian(g['parent_id'].toString())),
                ),
              OutlinedButton.icon(onPressed: _addGuardian, icon: const Icon(Icons.person_add), label: const Text('Add parent')),
            ]),
          ),
          Section(
            title: 'Bus stops',
            child: _routes.isEmpty
                ? const Text('Create a route with stops first (Fleet tab).', style: TextStyle(color: Colors.grey))
                : Column(children: [
                    for (final r in _routes)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: DropdownButtonFormField<String?>(
                          decoration: InputDecoration(labelText: '${r['name']} (${r['mode']})'),
                          value: _stopByRoute[r['id'].toString()],
                          items: [
                            const DropdownMenuItem<String?>(value: null, child: Text('Not on this route')),
                            for (final s in ((r['stops'] as List).map((e) => Map<String, dynamic>.from(e as Map)).toList()
                              ..sort((a, b) => (a['seq'] as int).compareTo(b['seq'] as int))))
                              DropdownMenuItem<String?>(value: s['id'].toString(), child: Text('${s['seq']}. ${s['name']}')),
                          ],
                          onChanged: (v) => _setStop(r, v),
                        ),
                      ),
                  ]),
          ),
        ],
      ]),
    );
  }
}
