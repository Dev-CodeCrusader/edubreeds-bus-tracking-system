import 'package:flutter/material.dart';

import '../../api.dart';
import '../../util.dart';

/// School holidays: no trips are scheduled on these dates; parents and drivers see "holiday".
class HolidaysPanel extends StatefulWidget {
  final String schoolId;
  const HolidaysPanel({super.key, required this.schoolId});

  @override
  State<HolidaysPanel> createState() => _HolidaysPanelState();
}

class _HolidaysPanelState extends State<HolidaysPanel> {
  List<Map<String, dynamic>> _rows = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await db
          .from('holidays')
          .select('id, on_date, reason')
          .eq('school_id', widget.schoolId)
          .gte('on_date', istDate())
          .order('on_date');
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

  String _dateLabel(String iso) {
    final d = DateTime.parse(iso);
    const m = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    const w = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    return '${w[d.weekday - 1]}, ${d.day} ${m[d.month - 1]} ${d.year}';
  }

  Future<void> _add() async {
    final now = DateTime.now();
    final range = await showDateRangePicker(
      context: context,
      firstDate: DateTime(now.year, now.month, now.day),
      lastDate: DateTime(now.year + 2),
      helpText: 'Choose the holiday (one day, or first and last day)',
    );
    if (range == null || !mounted) return;
    final reason = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('Reason'),
        content: TextField(controller: reason, decoration: const InputDecoration(labelText: 'e.g. Diwali, Summer vacation')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('Save')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      final rows = <Map<String, dynamic>>[];
      for (var d = range.start; !d.isAfter(range.end); d = d.add(const Duration(days: 1))) {
        rows.add({
          'school_id': widget.schoolId,
          'on_date': '${d.year}-${two(d.month)}-${two(d.day)}',
          'reason': reason.text.trim().isEmpty ? null : reason.text.trim(),
        });
      }
      await db.from('holidays').upsert(rows, onConflict: 'school_id,on_date');
      _load();
    } catch (e) {
      if (mounted) toast(context, errText(e));
    }
  }

  Future<void> _remove(Map<String, dynamic> h) async {
    try {
      await db.from('holidays').delete().eq('id', h['id']);
      _load();
    } catch (e) {
      if (mounted) toast(context, errText(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (_loading) const LinearProgressIndicator(),
      if (_error != null) Text('Could not load: $_error'),
      if (!_loading && _rows.isEmpty) const Text('No upcoming holidays.', style: TextStyle(color: Colors.grey)),
      for (final h in _rows)
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.beach_access),
          title: Text(_dateLabel(h['on_date'].toString())),
          subtitle: h['reason'] == null ? null : Text(h['reason'].toString()),
          trailing: IconButton(icon: const Icon(Icons.delete_outline), onPressed: () => _remove(h)),
        ),
      OutlinedButton.icon(onPressed: _add, icon: const Icon(Icons.add), label: const Text('Add holiday')),
    ]);
  }
}
