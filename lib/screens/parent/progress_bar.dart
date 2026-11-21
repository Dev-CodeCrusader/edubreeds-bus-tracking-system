import 'package:flutter/material.dart';

/// Vertical progress tracker for one child's pickup or drop.
/// [step] is the index of the current step; steps before it are done.
class TripProgress extends StatelessWidget {
  final List<String> labels;
  final List<String?> details; // optional small text under each label
  final int step;
  final bool holiday;
  const TripProgress({super.key, required this.labels, required this.step, this.details = const [], this.holiday = false});

  @override
  Widget build(BuildContext context) {
    final primary = holiday ? Colors.red.shade400 : Theme.of(context).colorScheme.primary;
    final done = Colors.green.shade700;
    return Column(children: [
      for (var i = 0; i < labels.length; i++)
        IntrinsicHeight(
          child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            SizedBox(
              width: 28,
              child: Column(children: [
                Container(
                  width: 22,
                  height: 22,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: i < step ? done : (i == step ? primary : Colors.transparent),
                    border: Border.all(color: i <= step ? (i < step ? done : primary) : Colors.grey.shade400, width: 2),
                  ),
                  child: i < step
                      ? const Icon(Icons.check, size: 14, color: Colors.white)
                      : (i == step ? const Icon(Icons.circle, size: 8, color: Colors.white) : null),
                ),
                if (i < labels.length - 1)
                  Expanded(child: Container(width: 2, color: i < step ? done : Colors.grey.shade300)),
              ]),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(labels[i],
                      style: TextStyle(
                        fontWeight: i == step ? FontWeight.w700 : FontWeight.normal,
                        color: i > step ? Colors.grey : null,
                      )),
                  if (i < details.length && details[i] != null)
                    Text(details[i]!, style: TextStyle(fontSize: 12, color: Colors.grey.shade700)),
                ]),
              ),
            ),
          ]),
        ),
    ]);
  }
}
