import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:gamehub/main.dart';

void main() {
  testWidgets('App starts up and shows a loading indicator', (WidgetTester tester) async {
    await tester.pumpWidget(const GameHubApp());
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });
}
