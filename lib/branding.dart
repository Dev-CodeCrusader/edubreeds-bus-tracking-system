import 'package:flutter/material.dart';

/// White-label theming: the colour of the school group's app, applied app-wide after sign-in.
const defaultBrandColor = Color(0xFF1B5E9E);
final ValueNotifier<Color> brandColor = ValueNotifier<Color>(defaultBrandColor);

Color? parseHexColor(String? hex) {
  if (hex == null) return null;
  final h = hex.replaceAll('#', '').trim();
  if (h.length != 6) return null;
  final v = int.tryParse(h, radix: 16);
  return v == null ? null : Color(0xFF000000 | v);
}
