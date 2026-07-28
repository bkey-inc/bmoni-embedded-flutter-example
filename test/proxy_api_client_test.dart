import 'package:bmoni_proxy_api_example/main.dart';
import 'package:flutter_test/flutter_test.dart';

/// The discovery endpoints (`/smart-wallets/supported-currencies`,
/// `/deposit/supported-assets`, `…/bank-accounts/nigerian-banks`) and the
/// proposal sign-payload are provider-shaped: gateways wrap them differently.
/// These cover the shapes the tolerant parsers are built for.
void main() {
  group('parseSupportedCurrencies', () {
    test('reads a plain array', () {
      expect(
        ProxyApiClient.parseSupportedCurrencies(['USDB', 'CNGN', 'MXNe']),
        ['USDB', 'CNGN', 'MXNe'],
      );
    });

    test('reads a data envelope and object rows, de-duplicating', () {
      expect(
        ProxyApiClient.parseSupportedCurrencies({
          'data': [
            {'currency': 'USDB'},
            {'code': 'EURe'},
            {'currency': 'USDB'},
          ],
        }),
        ['USDB', 'EURe'],
      );
    });

    test('returns empty for unusable payloads', () {
      expect(ProxyApiClient.parseSupportedCurrencies(null), isEmpty);
      expect(ProxyApiClient.parseSupportedCurrencies('USDB'), isEmpty);
      expect(ProxyApiClient.parseSupportedCurrencies({'nope': 1}), isEmpty);
    });
  });

  group('flattenDepositAssets', () {
    test('flattens chain groups with a currency list', () {
      expect(
        ProxyApiClient.flattenDepositAssets([
          {
            'chain': 'Base',
            'currencies': ['USDC', 'USDT'],
          },
          {
            'chain': 'Ethereum',
            'currencies': ['DAI'],
          },
        ]),
        [
          (chain: 'Base', currency: 'USDC'),
          (chain: 'Base', currency: 'USDT'),
          (chain: 'Ethereum', currency: 'DAI'),
        ],
      );
    });

    test('flattens flat chain+currency rows under a data envelope', () {
      expect(
        ProxyApiClient.flattenDepositAssets({
          'data': [
            {'chain': 'Base', 'currency': 'USDC'},
            {'network': 'Polygon', 'currency': 'EURC'},
          ],
        }),
        [
          (chain: 'Base', currency: 'USDC'),
          (chain: 'Polygon', currency: 'EURC'),
        ],
      );
    });

    test('flattens a chain-keyed map and de-duplicates', () {
      expect(
        ProxyApiClient.flattenDepositAssets({
          'Base': ['USDC', 'USDC'],
          'Solana': [
            {'symbol': 'USDT'},
          ],
        }),
        [
          (chain: 'Base', currency: 'USDC'),
          (chain: 'Solana', currency: 'USDT'),
        ],
      );
    });

    test('drops rows missing a chain or a token', () {
      expect(
        ProxyApiClient.flattenDepositAssets([
          {'currency': 'USDC'},
          {'chain': 'Base'},
          {'chain': '  ', 'currency': 'USDC'},
        ]),
        isEmpty,
      );
    });
  });

  group('parseNigerianBanks', () {
    test('accepts either field spelling', () {
      expect(
        ProxyApiClient.parseNigerianBanks({
          'banks': [
            {'name': 'Guaranty Trust Bank', 'code': '058'},
            {'bankName': 'Access Bank', 'bankCode': '044'},
          ],
        }),
        [
          (name: 'Guaranty Trust Bank', code: '058'),
          (name: 'Access Bank', code: '044'),
        ],
      );
    });

    test('skips rows without both a name and a code', () {
      expect(
        ProxyApiClient.parseNigerianBanks([
          {'name': 'No code bank'},
          {'code': '058'},
        ]),
        isEmpty,
      );
    });
  });

  test('readProposalId unwraps the data envelope', () {
    expect(
      ProxyApiClient.readProposalId({
        'data': {'proposalId': 'prop-1', 'status': 'PENDING_APPROVALS'},
      }),
      'prop-1',
    );
    expect(ProxyApiClient.readProposalId({'status': 'PENDING'}), isNull);
  });

  group('extractSignableHash', () {
    const hash =
        '0x1c8aff950685c2ed4bc3174f3472287b56d9517b9c948127319a09a7a36deac8';

    test('finds the digest at the top level and when nested', () {
      expect(ProxyApiClient.extractSignableHash({'hashToSign': hash}), hash);
      expect(
        ProxyApiClient.extractSignableHash({
          'data': {
            'signatureRequest': {'hashToSign': hash},
          },
        }),
        hash,
      );
      expect(
        ProxyApiClient.extractSignableHash({'signingPayloadHash': hash}),
        hash,
      );
    });

    test('rejects anything that is not a 32-byte hex digest', () {
      expect(
        ProxyApiClient.extractSignableHash({'hashToSign': '0x1234'}),
        isNull,
      );
      expect(
        ProxyApiClient.extractSignableHash({'hashToSign': hash.substring(2)}),
        isNull,
      );
      expect(ProxyApiClient.extractSignableHash({'other': hash}), isNull);
      expect(ProxyApiClient.extractSignableHash(null), isNull);
    });
  });

  test('Global-KYC currencies are USD, EUR and MXN only', () {
    expect(WalletCurrencyOption.values.where((c) => c.usesGlobalKyc).toList(), [
      WalletCurrencyOption.usd,
      WalletCurrencyOption.eur,
      WalletCurrencyOption.mxn,
    ]);
  });
}
