// Basic smoke test for Aisthetron.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aisthetron/main.dart';

void main() {
  testWidgets('AisthetronApp builds without throwing', (WidgetTester tester) async {
    await tester.pumpWidget(const AisthetronApp());
    expect(find.byType(MaterialApp), findsOneWidget);
  });
}
