// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:flutter_test/flutter_test.dart';

import 'package:track_start_call/main.dart';

void main() {
  testWidgets('Start call home renders', (WidgetTester tester) async {
    await tester.pumpWidget(const StartCallApp());

    expect(find.text('スタート'), findsOneWidget);
    expect(find.text('停止'), findsOneWidget);
    expect(find.text('Ready'), findsNothing);
    expect(find.text('Track Start Call'), findsOneWidget);
  });
}
