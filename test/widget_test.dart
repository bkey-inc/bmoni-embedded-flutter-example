import 'package:bmoni_embedded_sdk/bmoni_embedded_sdk.dart';
import 'package:bmoni_proxy_api_example/main.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    // The app restores session state from these stores on startup; provide
    // empty mocks so it boots to a clean "create account" screen in tests.
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    BmoniEmbeddedSdk.initialize(pinLength: 6, requirePin: true);
  });

  testWidgets('boots to the configure + create-account screen', (tester) async {
    await tester.pumpWidget(const BmoniProxyApiExampleApp());

    // _restoreSession() is async (reads prefs + secure storage); pump until it
    // resolves and the loading view transitions to the create-account step.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('Create your account'), findsOneWidget);
    expect(find.text('API configuration'), findsOneWidget);
  });
}
