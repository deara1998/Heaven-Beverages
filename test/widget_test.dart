import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:heaven_beverages/main.dart';

void main() {
  testWidgets('Login page displays Heaven Beverages branding',
      (WidgetTester tester) async {
    await tester.pumpWidget(const HeavenBeveragesApp());

    expect(find.text('Heaven Beverages'), findsOneWidget);
    expect(find.text('Sign In'), findsOneWidget);
    expect(find.byType(TextFormField), findsNWidgets(2));
  });
}
