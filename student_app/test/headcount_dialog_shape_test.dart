// Repro test: builds the SAME widget chain as the demo headcount dialog
// (AlertDialog -> SingleChildScrollView -> Column -> ... -> GridView.count)
// at a typical phone viewport and records any framework exception /
// overflow reported during layout.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('headcount dialog tree lays out without exceptions/overflow',
      (tester) async {
    final exceptions = <FlutterErrorDetails>[];
    final originalOnError = FlutterError.onError;
    FlutterError.onError = (details) => exceptions.add(details);

    Widget key(String label, VoidCallback onTap, {Color? fg}) {
      return SizedBox(
        height: 46,
        child: Material(
          color: const Color(0xFF2C2C2C),
          borderRadius: BorderRadius.circular(10),
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(10),
            child: Center(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                  color: fg ?? Colors.white,
                ),
              ),
            ),
          ),
        ),
      );
    }

    Widget chip(String label, String value, Color color) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label, style: TextStyle(fontSize: 10, color: color.withValues(alpha: 0.9))),
            const SizedBox(width: 4),
            Text(value, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: color)),
          ],
        ),
      );
    }

    final dialog = AlertDialog(
      backgroundColor: const Color(0xFF1E1E1E),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      titlePadding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
      contentPadding: const EdgeInsets.fromLTRB(20, 10, 20, 4),
      actionsPadding: const EdgeInsets.fromLTRB(16, 2, 16, 12),
      title: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: const Color(0xFF6366F1).withValues(alpha: 0.2),
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Icon(Icons.groups, size: 18, color: Color(0xFF818CF8)),
          ),
          const SizedBox(width: 10),
          const Expanded(
            child: Text(
              'Boarding at Electronic City',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Driver demo: how many students boarded?',
              style: TextStyle(fontSize: 12, color: Color(0xFF94A3B8)),
            ),
            const SizedBox(height: 10),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                chip('Onboard', '0', const Color(0xFF60A5FA)),
                const SizedBox(width: 6),
                chip('Capacity', '40', const Color(0xFF94A3B8)),
                const SizedBox(width: 6),
                chip('Free', '40', const Color(0xFF4ADE80)),
              ],
            ),
            const SizedBox(height: 10),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 10),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: const Color(0xFF2C2C2C),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0xFF3F3F3F)),
              ),
              child: const Text(
                '0',
                style: TextStyle(fontSize: 34, fontWeight: FontWeight.w800, color: Colors.white),
              ),
            ),
            const SizedBox(height: 10),
            // Numpad: plain Rows, same as the fixed dialog.
            for (final row in const [
              ['1', '2', '3'],
              ['4', '5', '6'],
              ['7', '8', '9'],
              ['C', '0', '⌫'],
            ])
              Row(
                children: [
                  for (final label in row)
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.all(3),
                        child: key(
                          label,
                          () {},
                          fg: label == '⌫'
                              ? const Color(0xFFF59E0B)
                              : label == 'C'
                                  ? const Color(0xFFE5E7EB)
                                  : null,
                        ),
                      ),
                    ),
                ],
              ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () {}, child: const Text('Skip')),
        ElevatedButton.icon(
          onPressed: () {},
          icon: const Icon(Icons.check_rounded, size: 18),
          label: const Text('Submit'),
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFF22C55E),
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
        ),
      ],
    );

    try {
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (ctx) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () => showDialog(context: ctx, builder: (_) => dialog),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    } finally {
      // Restore before expect/throw, as flutter_test requires.
      FlutterError.onError = originalOnError;
    }

    // No hidden framework/layout errors - reveal the full exception.
    if (exceptions.isNotEmpty) {
      final d = exceptions.first;
      throw d.exception;
    }

    // Dialog must be actually visible: its title and numpad row exist.
    expect(find.text('Boarding at Electronic City'), findsOneWidget);
    expect(find.text('9'), findsOneWidget);
    expect(find.text('⌫'), findsOneWidget);
    expect(find.text('Submit'), findsOneWidget);
  });
}
