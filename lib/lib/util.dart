import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'api.dart';

/// Today's date in India, as yyyy-MM-dd (does not depend on the phone's time zone).
String istDate([DateTime? now]) {
  final t = (now ?? DateTime.now()).toUtc().add(const Duration(hours: 5, minutes: 30));
  return '${t.year.toString().padLeft(4, '0')}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';
}

String two(int n) => n.toString().padLeft(2, '0');

/// 24-hour clock in the phone's local time, e.g. "07:45".
String clockOf(DateTime d) {
  final l = d.toLocal();
  return '${two(l.hour)}:${two(l.minute)}';
}

const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

/// "21 Nov, 07:45"
String stampOf(DateTime d) {
  final l = d.toLocal();
  return '${l.day} ${_months[l.month - 1]}, ${clockOf(l)}';
}

DateTime? parseTime(dynamic v) => v == null ? null : DateTime.tryParse(v.toString());

/// A readable message for any error coming from Supabase or the network.
String errText(Object e) {
  if (e is PostgrestException) return e.message;
  if (e is AuthException) return e.message;
  if (e is FunctionException) {
    final d = e.details;
    if (d is Map && d['error'] != null) return d['error'].toString();
    return d?.toString() ?? 'Request failed (${e.status})';
  }
  return e.toString().replaceFirst('Exception: ', '');
}

void toast(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
}

Widget signOutButton() => IconButton(
      tooltip: 'Sign out',
      icon: const Icon(Icons.logout),
      onPressed: () => Supabase.instance.client.auth.signOut(),
    );

/// Round student picture; shows initials when pictures are switched off for the school
/// (child-privacy toggle) or when there is no picture.
class StudentAvatar extends StatelessWidget {
  final String name;
  final String? photoPath;
  final bool photosEnabled;
  final double radius;
  const StudentAvatar({super.key, required this.name, this.photoPath, required this.photosEnabled, this.radius = 26});

  static final Map<String, Future<String?>> _cache = {};

  @override
  Widget build(BuildContext context) {
    final initial = name.trim().isEmpty ? '?' : name.trim()[0].toUpperCase();
    final fallback = CircleAvatar(radius: radius, child: Text(initial, style: TextStyle(fontSize: radius * 0.85)));
    final path = photoPath;
    if (!photosEnabled || path == null || path.isEmpty) return fallback;
    return FutureBuilder<String?>(
      future: _cache.putIfAbsent(path, () => Api.signedUrl('student-photos', path)),
      builder: (context, snap) => snap.data == null
          ? fallback
          : CircleAvatar(radius: radius, backgroundImage: NetworkImage(snap.data!)),
    );
  }
}

/// A small titled box used on admin screens.
class Section extends StatelessWidget {
  final String title;
  final Widget child;
  const Section({super.key, required this.title, required this.child});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          child,
        ]),
      );
}

/// Asks a yes / no question.
Future<bool> confirm(BuildContext context, String title, String body, {String yes = 'Yes'}) async {
  final r = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      title: Text(title),
      content: Text(body),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(yes)),
      ],
    ),
  );
  return r == true;
}
