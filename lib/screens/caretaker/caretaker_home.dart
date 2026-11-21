import 'package:flutter/material.dart';

import '../../api.dart';
import '../../util.dart';
import '../admin/live_trips.dart';

/// Caretaker at the school gate: today's trips, which buses are running, who is on board
/// or has been dropped, and a live map of each running bus.
class CaretakerHome extends StatelessWidget {
  final DriverProfile me;
  const CaretakerHome({super.key, required this.me});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('School gate  |  ${me.schoolName}'), actions: [signOutButton()]),
      body: LiveTripsView(me: me),
    );
  }
}
