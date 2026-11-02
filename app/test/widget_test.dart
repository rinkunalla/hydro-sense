import 'package:flutter_test/flutter_test.dart';
import 'package:hydro_sense/core/config.dart';
import 'package:hydro_sense/main.dart';

void main() {
  testWidgets('shell renders', (tester) async {
    await tester.pumpWidget(const HydroSenseApp());
    expect(find.text('Hydro Sense'), findsOneWidget);
  });

  test('config patterns match the backend', () {
    expect(AppConfig.deviceIdPattern.hasMatch('A1B2C3D4E5F6'), isTrue);
    expect(AppConfig.deviceIdPattern.hasMatch('a1b2c3d4e5f6'), isFalse);
    expect(AppConfig.phMobilePattern.hasMatch('09171234567'), isTrue);
    expect(AppConfig.phMobilePattern.hasMatch('+639171234567'), isTrue);
    expect(AppConfig.phMobilePattern.hasMatch('0917123456'), isFalse);
  });
}
