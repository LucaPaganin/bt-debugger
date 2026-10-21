import 'package:bt_debugger/main.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('la home mostra le quattro schede', (tester) async {
    await tester.pumpWidget(const BtDebuggerApp(startNative: false));
    await tester.pump();
    expect(find.text('Monitor'), findsWidgets);
    expect(find.text('Diagnosi'), findsWidgets);
    expect(find.text('Scansione'), findsWidgets);
  });
}
