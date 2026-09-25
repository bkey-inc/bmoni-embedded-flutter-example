import 'dart:convert';

import 'package:bmoni_proxy_api_example/main.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Pins each request to the documented contract (method, path, body) at
/// https://embedded-dev.bmoni.com/docs.
void main() {
  const client = ProxyApiClient(baseUrl: 'https://proxy.test', apiKey: 'k');

  Future<http.Request> capture(Future<Object?> Function() call) async {
    late http.Request seen;
    await http.runWithClient(
      call,
      () => MockClient((request) async {
        seen = request;
        return http.Response('{}', 200);
      }),
    );
    return seen;
  }

  void expectCall(
    http.Request r,
    String method,
    String path, [
    Map<String, dynamic>? body,
  ]) {
    expect(r.method, method);
    expect(r.url.path, path);
    expect(r.headers['x-api-key'], 'k');
    if (body != null) {
      expect(jsonDecode(r.body), body);
    }
  }

  test('workflow status', () async {
    final r = await capture(
      () => client.getWorkflowStatus(userId: 'u', workflowId: 'wf'),
    );
    expectCall(r, 'GET', '/v1/users/u/wallets/workflows/wf');
  });

  test('LATAM foreign bank payout', () async {
    final r = await capture(
      () => client.createLatamForeignPayout(
        userId: 'u',
        smartWalletId: 'w',
        usdcAmount: '25',
        targetCountry: 'MX',
        targetCurrency: 'MXN',
        description: 'rent',
      ),
    );
    expectCall(r, 'POST', '/v1/users/u/latam/cash/payouts/foreign', {
      'smartWalletId': 'w',
      'usdcAmount': '25',
      'targetCountry': 'MX',
      'targetCurrency': 'MXN',
      'description': 'rent',
    });
  });

  test('Mexico: launch, start-mexico, MXNe migration, offramp quote', () async {
    expectCall(
      await capture(() => client.getMxKycLaunch('u')),
      'GET',
      '/v1/users/u/latam/mx/kyc/launch/agreements',
    );
    expectCall(
      await capture(
        () =>
            client.startMexicoOnboarding(userId: 'u', mxnWalletAddress: '0xa'),
      ),
      'POST',
      '/v1/users/u/onboarding/start-mexico',
      {'mxnWalletAddress': '0xa', 'mxnWalletIndex': 0},
    );
    expectCall(
      await capture(() => client.getMxneMigrationStatus('u')),
      'GET',
      '/v1/users/u/latam/mx/mxne-migration/status',
    );
    expectCall(
      await capture(() => client.prepareMxneMigration('u')),
      'POST',
      '/v1/users/u/latam/mx/mxne-migration/prepare',
    );
    expectCall(
      await capture(
        () => client.createMxOfframpQuote(userId: 'u', sourceAmount: '500'),
      ),
      'POST',
      '/v1/users/u/latam/mx/quote',
      {'type': 'offramp', 'sourceAmount': '500'},
    );
  });

  test(
    'bank rails: USD wallet provision, VBA link, deposit accounts',
    () async {
      expectCall(
        await capture(
          () => client.provisionSmartWalletUsdVba(
            userId: 'u',
            smartWalletId: 'w',
          ),
        ),
        'POST',
        '/v1/users/u/smart-wallets/w/onramp/vba/usd/provision',
      );
      expectCall(
        await capture(
          () => client.linkDepositVba(
            userId: 'u',
            smartWalletId: 'w',
            region: 'nigeria',
            bankAccountId: 'b',
          ),
        ),
        'POST',
        '/v1/users/u/smart-wallets/w/onramp/vba/nigeria',
        {'bankAccountId': 'b'},
      );
      expectCall(
        await capture(() => client.getDepositAccounts('u', 'MXN')),
        'GET',
        '/v1/users/u/bank-accounts/deposit-accounts/MXN',
      );
    },
  );

  test('exchange/convert sends a numeric amount', () async {
    final r = await capture(
      () => client.convertCurrency(
        userId: 'u',
        amount: 12.5,
        from: 'USD',
        to: 'NGN',
      ),
    );
    expectCall(r, 'POST', '/v1/users/u/exchange/convert', {
      'amount': 12.5,
      'from': 'USD',
      'to': 'NGN',
    });
  });

  test('biometric upload sends `selfie` + type', () async {
    late http.BaseRequest seen;
    late String body;
    await http.runWithClient(
      () => client.uploadKycBiometric(
        userId: 'u',
        file: http.MultipartFile.fromBytes('selfie', [
          1,
          2,
          3,
        ], filename: 's.jpg'),
      ),
      () => MockClient((request) async {
        seen = request;
        body = request.body;
        return http.Response('{}', 200);
      }),
    );
    expect(seen.url.path, '/v1/users/u/kyc/documents/biometric');
    expect(body, contains('name="selfie"; filename="s.jpg"'));
    expect(body, contains('name="type"\r\n\r\nselfie'));
  });

  test('camera skips the prompt only on the provider site', () {
    expect(isSameSite('app.etherfuse.com', 'devnet.etherfuse.com'), isTrue);
    expect(isSameSite('ETHERFUSE.com', 'etherfuse.com'), isTrue);
    expect(isSameSite('evil.com', 'etherfuse.com'), isFalse);
    expect(isSameSite('etherfuse.com.evil.io', 'etherfuse.com'), isFalse);
    expect(isSameSite('', 'etherfuse.com'), isFalse);
    expect(isSameSite('etherfuse.com', null), isFalse);
  });

  test('MXN wallets use MEXe', () {
    expect(WalletCurrencyOption.mxn.smartWalletCurrency, 'MEXe');
    expect(WalletCurrencyOption.cad.sumsubLevelName, isNull);
    expect(WalletCurrencyOption.ngn.sumsubLevelName, 'id-only');
    expect(WalletCurrencyOption.usd.sumsubLevelName, 'id-and-liveness');
  });
}
