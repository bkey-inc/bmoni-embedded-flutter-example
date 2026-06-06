import 'dart:convert';
import 'dart:io';

import 'package:bkey_uikit/bkey_uikit.dart';
import 'package:bmoni_embedded_sdk/bmoni_embedded_sdk.dart';
import 'package:bmoni_embedded_wallets_cards/bmoni_embedded_wallets_cards.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  BmoniEmbeddedSdk.initialize(pinLength: 6, requirePin: true);
  runApp(const BmoniProxyApiExampleApp());
}

/// Optional defaults for local runs; prefer entering URL + key in the app UI.
String apiBaseUrl = '';
String apiKey = '';

/// Swagger **Bank Accounts** tag — swap host for your deployed proxy or ngrok URL.
const String kEmbeddedBankAccountsDocsUrl =
    'https://bd68-197-251-135-217.ngrok-free.app/docs#tag/bank-accounts';

/// Prisma `IdentificationDocumentType` — must match upload DTO (`POST …/identification-documents`).
const List<String> kycIdentificationUploadTypes = [
  'passport',
  'drivers_license',
  'national_id',
  'government_id',
  'other',
];

/// Prisma `ProofOfAddressDocumentType`.
const List<String> kycProofOfAddressUploadTypes = [
  'utility_bill',
  'bank_statement',
  'rental_agreement',
  'tax_document',
  'other',
];

MediaType multipartMediaTypeForFilename(String? filename) {
  final name = (filename ?? '').toLowerCase();
  if (name.endsWith('.png')) {
    return MediaType('image', 'png');
  }
  if (name.endsWith('.pdf')) {
    return MediaType('application', 'pdf');
  }
  return MediaType('image', 'jpeg');
}

class BmoniProxyApiExampleApp extends StatelessWidget {
  const BmoniProxyApiExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'BMoni Embedded API Example',
      debugShowCheckedModeBanner: false,
      theme: BMoniTheme.darkTheme(),
      home: const ExampleHomePage(),
    );
  }
}

enum ExampleStep {
  loading,
  createAccount,
  unlock,
  selectCurrency,
  walletHome,
  kycWizard,
}

enum WalletCurrencyOption {
  usd('US Dollar', 'USD', 'USDB', 'Bridge KYC'),
  cad('Canadian Dollar', 'CAD', 'CADC', 'PayTrie KYC'),
  eur('Euro', 'EUR', 'EURe', 'Monerium KYC'),
  ngn('Naira', 'NGN', 'CNGN', 'Anchor KYC');

  const WalletCurrencyOption(
    this.label,
    this.fiatCode,
    this.smartWalletCurrency,
    this.kycProviderLabel,
  );

  final String label;
  final String fiatCode;
  final String smartWalletCurrency;
  final String kycProviderLabel;

  static WalletCurrencyOption fromSmartWalletCurrency(String value) {
    return WalletCurrencyOption.values.firstWhere(
      (option) =>
          option.smartWalletCurrency.toUpperCase() == value.toUpperCase(),
      orElse: () => WalletCurrencyOption.usd,
    );
  }
}

class _ExampleSessionKeys {
  static const baseUrl = 'example.baseUrl';
  static const apiKey = 'example.apiKey';
  static const user = 'example.user';
  static const smartWallet = 'example.smartWallet';
  static const currency = 'example.currency';
  static const ownerAddress = 'example.ownerAddress';
  static const isLoggedIn = 'example.isLoggedIn';
}

class ExampleHomePage extends StatefulWidget {
  const ExampleHomePage({super.key});

  @override
  State<ExampleHomePage> createState() => _ExampleHomePageState();
}

class _ExampleHomePageState extends State<ExampleHomePage> {
  late final TextEditingController _baseUrlController;
  late final TextEditingController _apiKeyController;
  late final TextEditingController _pinController;
  late final TextEditingController _firstNameController;
  late final TextEditingController _lastNameController;
  late final TextEditingController _emailController;
  late final TextEditingController _phoneController;
  late final TextEditingController _amountController;
  late final TextEditingController _destinationAddressController;
  late final TextEditingController _toCurrencyController;

  late final TextEditingController _kycMiddleNameController;
  late final TextEditingController _kycDobController;
  late final TextEditingController _kycStreet1Controller;
  late final TextEditingController _kycStreet2Controller;
  late final TextEditingController _kycCityController;
  late final TextEditingController _kycStateController;
  late final TextEditingController _kycPostalController;
  late final TextEditingController _kycCountryCodeController;
  late final TextEditingController _kycEmployerController;
  late final TextEditingController _kycOccupationSearchController;
  late final TextEditingController _kycBvnController;

  final PageController _kycPageController = PageController();

  ExampleStep _step = ExampleStep.loading;
  ProxyUser? _profile;
  SmartWallet? _smartWallet;
  List<SmartWallet> _accountWallets = [];
  Map<String, dynamic> _accountBalancesData = const {};
  bool _addingAnotherWallet = false;
  WalletCurrencyOption _selectedCurrency = WalletCurrencyOption.usd;
  String? _ownerAddress;
  String? _message;
  String? _error;
  String? _lastResponse;
  bool _isBusy = false;
  bool _isBalanceHidden = false;

  int _kycPageIndex = 0;
  String? _kycGender;
  String? _kycEmploymentStatus;
  String? _kycSourceOfFunds;
  String? _kycAccountPurpose;
  int? _kycEstimatedMonthlyVolume;
  bool _kycActingAsIntermediary = false;
  String? _kycOccupationCode;
  String? _kycOccupationLabel;
  List<Map<String, dynamic>> _kycOccupationHits = [];
  Map<String, dynamic>? _kycOptionsJson;

  /// USD (Bridge) requires TOS signing + storing `signedAgreementId`.
  bool get _needsBridgeAgreement =>
      _selectedCurrency == WalletCurrencyOption.usd;

  static const int _kycPageCount = 7;

  final ImagePicker _imagePicker = ImagePicker();

  Uint8List? _kycIdFrontBytes;
  Uint8List? _kycIdBackBytes;
  String? _kycIdFrontFilename;
  String? _kycIdBackFilename;
  Uint8List? _kycPoaBytes;
  Uint8List? _kycPoaBackBytes;
  String? _kycPoaFilename;
  String? _kycPoaBackFilename;

  String? _kycIdDocType;
  late final TextEditingController _kycIdDocumentNumberController;
  late final TextEditingController _kycIdIssuingCountryController;
  late final TextEditingController _kycIdExpirationController;
  late final TextEditingController _kycIdIssueController;
  String _kycPoaDocType = 'utility_bill';

  String? _bridgeSigningUrl;
  late final TextEditingController _bridgeSignedAgreementIdController;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now().millisecondsSinceEpoch;
    _baseUrlController = TextEditingController(text: _defaultBaseUrl());
    _apiKeyController = TextEditingController();
    _pinController = TextEditingController();
    _firstNameController = TextEditingController(text: 'Chiamaka');
    _lastNameController = TextEditingController(text: 'Okafor');
    _emailController = TextEditingController(
      text: 'embedded.demo+$now@example.com',
    );
    _phoneController = TextEditingController(text: '+2348012345678');
    _amountController = TextEditingController(text: '10.00');
    _destinationAddressController = TextEditingController(
      text: '0x0000000000000000000000000000000000000001',
    );
    _toCurrencyController = TextEditingController(text: 'NGN');
    _kycMiddleNameController = TextEditingController();
    _kycDobController = TextEditingController(text: '1990-01-01');
    _kycStreet1Controller = TextEditingController(text: '15 Admiralty Way');
    _kycStreet2Controller = TextEditingController();
    _kycCityController = TextEditingController(text: 'Lagos');
    _kycStateController = TextEditingController(text: 'Lagos');
    _kycPostalController = TextEditingController(text: '101241');
    _kycCountryCodeController = TextEditingController(text: 'NGA');
    _kycEmployerController = TextEditingController(text: 'ACME Corp');
    _kycOccupationSearchController = TextEditingController(text: 'engineer');
    _kycBvnController = TextEditingController();
    _kycIdDocumentNumberController = TextEditingController(text: 'A12345678');
    _kycIdIssuingCountryController = TextEditingController(text: 'NGA');
    _kycIdExpirationController = TextEditingController(text: '2030-01-01');
    _kycIdIssueController = TextEditingController(text: '2020-01-01');
    _bridgeSignedAgreementIdController = TextEditingController();
    _restoreSession();
  }

  @override
  void dispose() {
    _kycPageController.dispose();
    _baseUrlController.dispose();
    _apiKeyController.dispose();
    _pinController.dispose();
    _firstNameController.dispose();
    _lastNameController.dispose();
    _emailController.dispose();
    _phoneController.dispose();
    _amountController.dispose();
    _destinationAddressController.dispose();
    _toCurrencyController.dispose();
    _kycMiddleNameController.dispose();
    _kycDobController.dispose();
    _kycStreet1Controller.dispose();
    _kycStreet2Controller.dispose();
    _kycCityController.dispose();
    _kycStateController.dispose();
    _kycPostalController.dispose();
    _kycCountryCodeController.dispose();
    _kycEmployerController.dispose();
    _kycOccupationSearchController.dispose();
    _kycBvnController.dispose();
    _kycIdDocumentNumberController.dispose();
    _kycIdIssuingCountryController.dispose();
    _kycIdExpirationController.dispose();
    _kycIdIssueController.dispose();
    _bridgeSignedAgreementIdController.dispose();
    super.dispose();
  }

  String _defaultBaseUrl() {
    if (apiBaseUrl.isNotEmpty) {
      return apiBaseUrl;
    }
    if (Platform.isAndroid) {
      return 'http://10.0.2.2:4001';
    }
    return 'http://localhost:4001';
  }

  ProxyApiClient get _client => ProxyApiClient(
    baseUrl: _baseUrlController.text.trim(),
    apiKey: _apiKeyController.text.trim(),
  );

  /// The wallet card uses [WalletCurrencyOption] + zeros when only this object
  /// exists with empty [SmartWallet.id] — actions still require a real API id.
  static bool _walletReady(SmartWallet? wallet) =>
      wallet != null && wallet.id.trim().isNotEmpty;

  Set<String> get _ownedStablecoinCodes => _accountWallets
      .map((w) => w.currency.trim().toUpperCase())
      .where((c) => c.isNotEmpty)
      .toSet();

  Future<void> _refreshAccountWalletData() async {
    final userId = _profile?.bmoniUserId;
    if (userId == null || userId.isEmpty) {
      return;
    }
    final wallets = await _client.listAccountSmartWallets(userId);
    final balances = await _client.listAccountBalances(userId);
    if (!mounted) {
      return;
    }
    setState(() {
      _accountWallets = wallets;
      _accountBalancesData = balances;
      final active = _smartWallet;
      if (active != null && active.id.trim().isNotEmpty) {
        _selectedCurrency = WalletCurrencyOption.fromSmartWalletCurrency(
          active.currency,
        );
      }
    });
  }

  Future<void> _refreshWalletsAndBalancesUi() => _runTask(() async {
    await _refreshAccountWalletData();
    if (!mounted) {
      return;
    }
    setState(() {
      _message = 'Wallets and balances refreshed from the API.';
    });
  });

  Future<void> _startAddWalletFlow() => _runTask(() async {
    await _refreshAccountWalletData();
    if (!mounted) {
      return;
    }
    final available = WalletCurrencyOption.values
        .where(
          (o) => !_ownedStablecoinCodes.contains(
            o.smartWalletCurrency.toUpperCase(),
          ),
        )
        .toList();
    if (available.isEmpty) {
      setState(() {
        _message =
            'You already have wallets for every supported currency on this account.';
      });
      return;
    }
    setState(() {
      _addingAnotherWallet = true;
      _step = ExampleStep.selectCurrency;
      if (!available.contains(_selectedCurrency)) {
        _selectedCurrency = available.first;
      }
      _message =
          'Choose a currency you do not already have. Existing wallets are disabled.';
    });
  });

  void _cancelAddWalletFlow() {
    setState(() {
      _addingAnotherWallet = false;
      _step = ExampleStep.walletHome;
      _message = null;
    });
  }

  void _selectActiveWallet(SmartWallet wallet) {
    if (!_walletReady(wallet)) {
      return;
    }
    setState(() {
      _smartWallet = wallet;
      _selectedCurrency = WalletCurrencyOption.fromSmartWalletCurrency(
        wallet.currency,
      );
      _message =
          'Active wallet: ${wallet.currency} · ${wallet.id.length > 10 ? '${wallet.id.substring(0, 8)}…' : wallet.id}';
    });
    _saveSession(isLoggedIn: true);
  }

  Future<void> _reloadActiveSmartWalletFromApi() => _runTask(() async {
    final userId = _requiredUserId;
    final id = _requiredSmartWallet.id;
    final wallet = await _client.getSmartWallet(
      userId: userId,
      smartWalletId: id,
    );
    if (!mounted) {
      return;
    }
    setState(() {
      _smartWallet = wallet;
      _message = 'Current wallet reloaded from GET …/smart-wallets/{id}.';
    });
    await _saveSession(isLoggedIn: true);
    await _refreshAccountWalletData();
  });

  Future<void> _restoreSession() async {
    final prefs = await SharedPreferences.getInstance();
    final baseUrl = prefs.getString(_ExampleSessionKeys.baseUrl);
    final apiKey = prefs.getString(_ExampleSessionKeys.apiKey);
    final userJson = prefs.getString(_ExampleSessionKeys.user);
    final walletJson = prefs.getString(_ExampleSessionKeys.smartWallet);
    final currency = prefs.getString(_ExampleSessionKeys.currency);
    final ownerAddress =
        prefs.getString(_ExampleSessionKeys.ownerAddress) ??
        await BmoniEmbeddedSdk.walletAddress();
    final isLoggedIn = prefs.getBool(_ExampleSessionKeys.isLoggedIn) ?? false;

    if (!mounted) {
      return;
    }

    setState(() {
      if (baseUrl != null && baseUrl.isNotEmpty) {
        _baseUrlController.text = baseUrl;
      }
      if (apiKey != null && apiKey.isNotEmpty) {
        _apiKeyController.text = apiKey;
      }
      if (userJson != null) {
        _profile = ProxyUser.fromJson(jsonDecode(userJson));
      }
      if (walletJson != null) {
        final parsed = SmartWallet.fromJson(
          jsonDecode(walletJson) as Map<String, dynamic>,
        );
        _smartWallet = _walletReady(parsed) ? parsed : null;
      }
      if (currency != null) {
        _selectedCurrency = WalletCurrencyOption.fromSmartWalletCurrency(
          currency,
        );
      }
      _ownerAddress = ownerAddress;
      _step = _profile == null
          ? ExampleStep.createAccount
          : isLoggedIn
          ? (_walletReady(_smartWallet)
                ? ExampleStep.walletHome
                : ExampleStep.selectCurrency)
          : ExampleStep.unlock;
    });
    final syncListAfterRestore =
        mounted &&
        _profile != null &&
        _walletReady(_smartWallet) &&
        _step == ExampleStep.walletHome;
    if (syncListAfterRestore) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) {
          return;
        }
        _refreshAccountWalletData().catchError((Object e) {
          if (!mounted) {
            return;
          }
          setState(() {
            _message =
                'Could not sync wallets from the API ($e). Tap Refresh wallets & balances.';
          });
        });
      });
    }
    if (walletJson != null &&
        _smartWallet == null &&
        _profile != null &&
        mounted) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_ExampleSessionKeys.smartWallet);
    }
  }

  Future<void> _saveSession({bool? isLoggedIn}) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_ExampleSessionKeys.baseUrl, _baseUrlController.text);
    await prefs.setString(_ExampleSessionKeys.apiKey, _apiKeyController.text);
    await prefs.setString(
      _ExampleSessionKeys.currency,
      _selectedCurrency.smartWalletCurrency,
    );
    if (_profile != null) {
      await prefs.setString(
        _ExampleSessionKeys.user,
        jsonEncode(_profile!.toJson()),
      );
    }
    if (_smartWallet != null) {
      await prefs.setString(
        _ExampleSessionKeys.smartWallet,
        jsonEncode(_smartWallet!.toJson()),
      );
    } else {
      await prefs.remove(_ExampleSessionKeys.smartWallet);
    }
    if (_ownerAddress != null) {
      await prefs.setString(_ExampleSessionKeys.ownerAddress, _ownerAddress!);
    }
    if (isLoggedIn != null) {
      await prefs.setBool(_ExampleSessionKeys.isLoggedIn, isLoggedIn);
    }
  }

  Future<void> _runTask(Future<void> Function() action) async {
    if (_isBusy) {
      return;
    }
    setState(() {
      _isBusy = true;
      _error = null;
      _message = null;
    });
    try {
      await action();
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() => _error = error.toString());
    } finally {
      if (mounted) {
        setState(() => _isBusy = false);
      }
    }
  }

  Future<void> _createAccount() => _runTask(() async {
    final user = await _client.createUser(
      CreateUserRequest(
        firstName: _firstNameController.text.trim(),
        lastName: _lastNameController.text.trim(),
        email: _emailController.text.trim(),
        phoneNumber: _phoneController.text.trim(),
      ),
    );
    setState(() {
      _profile = user;
      _smartWallet = null;
      _ownerAddress = null;
      _accountWallets = [];
      _accountBalancesData = const {};
      _addingAnotherWallet = false;
      _step = ExampleStep.selectCurrency;
      _message = 'Account created. Choose a wallet currency next.';
      _lastResponse = _prettyJson(user.toJson());
    });
    await _saveSession(isLoggedIn: true);
  });

  Future<void> _unlockWithPin() => _runTask(() async {
    final pin = _pinController.text.trim();
    if (pin.length != BmoniEmbeddedSdk.pinLength) {
      throw ExampleException(
        'Enter a ${BmoniEmbeddedSdk.pinLength}-digit PIN.',
      );
    }
    final hasPin = await BmoniEmbeddedSdk.hasPin();
    if (!hasPin) {
      throw const ExampleException(
        'No PIN is configured on this device. Create a new account first.',
      );
    }
    final matches = await BmoniEmbeddedSdk.matchPin(pin);
    if (!matches) {
      throw const ExampleException('The PIN did not match this device wallet.');
    }
    setState(() {
      _step = _walletReady(_smartWallet)
          ? ExampleStep.walletHome
          : ExampleStep.selectCurrency;
      _message = 'Welcome back.';
    });
    await _saveSession(isLoggedIn: true);
    _refreshAccountWalletData().catchError((Object e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _message =
            'Could not sync wallets from the API ($e). Tap Refresh wallets & balances.';
      });
    });
  });

  Future<void> _logout() => _runTask(() async {
    _pinController.clear();
    setState(() {
      _step = ExampleStep.unlock;
      _smartWallet = null;
      _ownerAddress = null;
      _accountWallets = [];
      _accountBalancesData = const {};
      _addingAnotherWallet = false;
      _message = 'Logged out. Unlock with the device PIN to continue.';
    });
    await _saveSession(isLoggedIn: false);
  });

  Future<void> _provisionSmartWallet() => _runTask(() async {
    final userId = _profile?.bmoniUserId;
    if (userId == null || userId.isEmpty) {
      throw const ExampleException('Create an account first.');
    }
    final pin = _pinController.text.trim();
    if (pin.length != BmoniEmbeddedSdk.pinLength) {
      throw ExampleException(
        'Enter a ${BmoniEmbeddedSdk.pinLength}-digit PIN.',
      );
    }

    // Best-effort pre-flight to populate the duplicate-currency guard below.
    // A first-time user has no smart-wallet group yet, so listing wallets /
    // balances returns 400 "No embedded smart wallet group found … Call POST
    // …/owner-proof-challenges first." — which is expected right before we
    // create the first wallet. Don't let it abort provisioning; any genuine
    // error (auth, network) resurfaces on the owner-proof call immediately
    // below.
    try {
      await _refreshAccountWalletData();
    } on ExampleException {
      // No group / no wallets yet — proceed to create the first wallet.
    }
    final requested = _selectedCurrency.smartWalletCurrency.toUpperCase();
    if (_ownedStablecoinCodes.contains(requested)) {
      throw ExampleException(
        'You already have a ${_selectedCurrency.smartWalletCurrency} wallet. '
        'Choose another currency.',
      );
    }

    final ownerAddress = await _provisionOwnerAddress(pin);
    final challenge = await _client.createOwnerProofChallenge(
      userId: userId,
      currency: _selectedCurrency.smartWalletCurrency,
      userOwnerAddress: ownerAddress,
    );
    final signature = await BmoniEmbeddedSdk.signMessage(
      challenge.message,
      pin: pin,
    );
    final smartWallet = await _client.createManagedSmartWallet(
      userId: userId,
      currency: _selectedCurrency.smartWalletCurrency,
      userOwnerAddress: ownerAddress,
      ownerProofChallengeId: challenge.challengeId,
      ownerProofSignature: signature,
    );

    setState(() {
      _ownerAddress = ownerAddress;
      _smartWallet = smartWallet;
      _addingAnotherWallet = false;
      _step = ExampleStep.walletHome;
      _message = '${_selectedCurrency.label} smart wallet is ready.';
      _lastResponse = _prettyJson({
        'ownerProofChallenge': challenge.toJson(),
        'smartWallet': smartWallet.toJson(),
      });
    });
    await _saveSession(isLoggedIn: true);
    await _refreshAccountWalletData();
  });

  Future<String> _provisionOwnerAddress(String pin) async {
    final hasWallet = await BmoniEmbeddedSdk.hasWallet();
    final address = hasWallet
        ? await BmoniEmbeddedSdk.walletAddress()
        : await BmoniEmbeddedSdk.initWallet();
    if (address == null || address.isEmpty) {
      throw const ExampleException('The embedded SDK returned no address.');
    }

    final hasPin = await BmoniEmbeddedSdk.hasPin();
    if (!hasPin) {
      await BmoniEmbeddedSdk.setPin(pin);
    } else if (!await BmoniEmbeddedSdk.matchPin(pin)) {
      throw const ExampleException('The PIN did not match this device wallet.');
    }
    return address;
  }

  Future<void> _handleTopUp() async {
    if (_isBusy) {
      return;
    }
    final active = await _ensureKycReady();
    if (!active || !mounted) {
      return;
    }
    final method = await _showTopUpMethodSheet();
    if (method == null || !mounted) {
      return;
    }
    await _runTask(() async {
      if (method == 'crypto') {
        await _executeTopUpCrypto();
      } else {
        await _executeTopUpBank();
      }
    });
  }

  Future<String?> _showTopUpMethodSheet() {
    return showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Top up',
                style: Theme.of(ctx).textTheme.titleLarge,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              ListTile(
                leading: const Icon(Icons.currency_bitcoin),
                title: const Text('Crypto deposit'),
                subtitle: const Text('Bridge deposit address (on-chain)'),
                onTap: () => Navigator.pop(ctx, 'crypto'),
              ),
              ListTile(
                leading: const Icon(Icons.account_balance),
                title: const Text('Bank transfer (VBA)'),
                subtitle: Text(switch (_selectedCurrency) {
                  WalletCurrencyOption.usd =>
                    'Provision a US VBA (Graph Finance) for this wallet',
                  WalletCurrencyOption.ngn =>
                    'Create a Nigerian deposit account for this wallet',
                  WalletCurrencyOption.eur =>
                    'Create an EU IBAN deposit account for this wallet',
                  WalletCurrencyOption.cad =>
                    'Not demonstrated for CAD — use crypto',
                }),
                onTap: () => Navigator.pop(ctx, 'bank'),
              ),
              TextButton.icon(
                onPressed: () async {
                  final uri = Uri.parse(kEmbeddedBankAccountsDocsUrl);
                  if (await canLaunchUrl(uri)) {
                    await launchUrl(uri, mode: LaunchMode.externalApplication);
                  }
                },
                icon: const Icon(Icons.open_in_new, size: 18),
                label: const Text('Bank Accounts API docs'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _executeTopUpCrypto() async {
    final userId = _requiredUserId;
    final smartWalletId = _requiredSmartWallet.id;
    final response = await _client.depositToWallet(
      userId: userId,
      smartWalletId: smartWalletId,
      chain: 'Base',
      currency: 'USDC',
    );
    setState(() {
      final address = response['address'];
      _message = address is String && address.isNotEmpty
          ? 'Top up: send USDC on Base to $address — it is converted and credited automatically.'
          : 'Top up: deposit address generated. Send USDC on Base to the returned address.';
      _lastResponse = _prettyJson(response);
    });
  }

  Future<void> _executeTopUpBank() async {
    final userId = _requiredUserId;
    final smartWalletId = _requiredSmartWallet.id;
    switch (_selectedCurrency) {
      case WalletCurrencyOption.usd:
        await _topUpBankUsd(userId, smartWalletId);
      case WalletCurrencyOption.ngn:
        await _topUpBankNgn(userId, smartWalletId);
      case WalletCurrencyOption.eur:
        await _topUpBankEur(userId, smartWalletId);
      case WalletCurrencyOption.cad:
        throw const ExampleException(
          'Bank transfer top-up for CAD is not wired in this example. '
          'Use crypto top-up.',
        );
    }
  }

  /// USD bank top-up now uses the dedicated `/us/vba/*` module (Graph Finance):
  /// readiness gate → provision → fetch the issued account details. There is no
  /// per-wallet "link" step in the new model — provisioning binds the VBA.
  Future<void> _topUpBankUsd(String userId, String smartWalletId) async {
    final readiness = await _client.getUsVbaReadiness(userId);
    if (readiness['ready'] != true) {
      final missing = (readiness['missing'] as List?)?.join(', ') ?? 'unknown';
      setState(() {
        _message = 'US VBA not ready. Outstanding requirements: $missing.';
        _lastResponse = _prettyJson(readiness);
      });
      return;
    }
    final provision = await _client.provisionUsVba(
      userId: userId,
      smartWalletId: smartWalletId,
    );
    final vba = await _client.getUsVba(userId);
    if (!mounted) {
      return;
    }
    setState(() {
      _message =
          'US VBA provisioning ${provision['workflowId'] != null ? "started" : "requested"} '
          '(status: ${vba['status'] ?? 'unknown'}). Poll GET /us/vba for account '
          'details once active.';
      _lastResponse = _prettyJson({'provision': provision, 'vba': vba});
    });
  }

  /// Nigerian bank top-up: the Blockradar deposit account itself is the funding
  /// rail — incoming NGN to it is swept to this wallet. The old separate
  /// `onramp/vba/nigeria` link step was removed.
  Future<void> _topUpBankNgn(String userId, String smartWalletId) async {
    final raw = await _client.getBankAccounts(userId);
    final ng = ProxyApiClient.extractNigerianDeposits(raw);
    if (!mounted) {
      return;
    }
    final existingId = await _pickDepositBankAccountId(
      context: context,
      accounts: ng,
      title: 'Nigerian deposit VBA',
      createNewLabel: 'Create Blockradar NGN deposit account',
    );
    if (!mounted || existingId == null) {
      return;
    }
    final account = existingId.isEmpty
        ? await _client.createBlockradarDepositAccount(
            userId: userId,
            smartWalletId: smartWalletId,
          )
        : ng.firstWhere(
            (a) => ProxyApiClient.readBankAccountId(a) == existingId,
            orElse: () => {'id': existingId},
          );
    if (!mounted) {
      return;
    }
    setState(() {
      _message =
          'Nigerian deposit account ready. Incoming NGN to it is swept to this '
          'wallet per Anchor / Blockradar rules.';
      _lastResponse = _prettyJson(account);
    });
  }

  /// EUR bank top-up: create/show the EUR deposit account. (Outbound EUR SEPA
  /// payouts are the separate `/eu/*` module — see the Integrations screen.)
  Future<void> _topUpBankEur(String userId, String smartWalletId) async {
    final raw = await _client.getBankAccounts(userId);
    final eu = ProxyApiClient.extractEuropeanDeposits(raw);
    if (!mounted) {
      return;
    }
    final existingId = await _pickDepositBankAccountId(
      context: context,
      accounts: eu,
      title: 'European deposit IBAN',
      createNewLabel: 'Create new EUR deposit account',
    );
    if (!mounted || existingId == null) {
      return;
    }
    final account = existingId.isEmpty
        ? await _client.createDepositAccount(
            userId: userId,
            region: 'EUR',
            smartWalletId: smartWalletId,
          )
        : eu.firstWhere(
            (a) => ProxyApiClient.readBankAccountId(a) == existingId,
            orElse: () => {'id': existingId},
          );
    if (!mounted) {
      return;
    }
    setState(() {
      _message =
          'EU deposit account ready. Use GET /bank-accounts for IBAN routing. '
          'Outbound SEPA payouts use the EU module on the Integrations screen.';
      _lastResponse = _prettyJson(account);
    });
  }

  /// Returns empty string to mean “create new”; null if cancelled.
  Future<String?> _pickDepositBankAccountId({
    required BuildContext context,
    required List<Map<String, dynamic>> accounts,
    required String title,
    required String createNewLabel,
  }) {
    return showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(title),
        children: [
          for (final a in accounts)
            SimpleDialogOption(
              onPressed: () {
                final id = ProxyApiClient.readBankAccountId(a);
                if (id != null) {
                  Navigator.pop(ctx, id);
                }
              },
              child: Text(
                '${a['bankName'] ?? 'Bank'} · '
                '${ProxyApiClient.readBankAccountId(a) ?? '?'}',
              ),
            ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, ''),
            child: Text(createNewLabel),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
  }

  Future<void> _handleWithdraw() async {
    if (_isBusy) {
      return;
    }
    final active = await _ensureKycReady();
    if (!active || !mounted) {
      return;
    }
    final method = await _showWithdrawMethodSheet();
    if (method == null || !mounted) {
      return;
    }
    if (method == 'bank' &&
        _selectedCurrency != WalletCurrencyOption.ngn &&
        _selectedCurrency != WalletCurrencyOption.usd) {
      if (!mounted) {
        return;
      }
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Bank withdrawal'),
          content: Text(
            'This proxy exposes bank offramp for Nigeria and US only. '
            'For ${_selectedCurrency.label}, use crypto withdrawal or extend '
            'the client when an endpoint exists.\n\n'
            'See Bank Accounts in Swagger.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('OK'),
            ),
          ],
        ),
      );
      return;
    }
    await _runTask(() async {
      if (method == 'crypto') {
        await _executeWithdrawCrypto();
      } else {
        await _executeWithdrawBank();
      }
    });
  }

  Future<String?> _showWithdrawMethodSheet() {
    return showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Withdraw',
                style: Theme.of(ctx).textTheme.titleLarge,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              ListTile(
                leading: const Icon(Icons.currency_bitcoin),
                title: const Text('Crypto'),
                subtitle: const Text('Bridge crypto offramp proposal'),
                onTap: () => Navigator.pop(ctx, 'crypto'),
              ),
              ListTile(
                leading: const Icon(Icons.account_balance),
                title: const Text('Bank transfer'),
                subtitle: Text(switch (_selectedCurrency) {
                  WalletCurrencyOption.ngn =>
                    'Save Nigerian payout account, then offramp',
                  WalletCurrencyOption.usd =>
                    'ACH to a saved US payout account',
                  WalletCurrencyOption.eur =>
                    'Not available for this currency here',
                  WalletCurrencyOption.cad =>
                    'Not available for this currency here',
                }),
                onTap: () => Navigator.pop(ctx, 'bank'),
              ),
              TextButton.icon(
                onPressed: () async {
                  final uri = Uri.parse(kEmbeddedBankAccountsDocsUrl);
                  if (await canLaunchUrl(uri)) {
                    await launchUrl(uri, mode: LaunchMode.externalApplication);
                  }
                },
                icon: const Icon(Icons.open_in_new, size: 18),
                label: const Text('Bank Accounts API docs'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _executeWithdrawCrypto() async {
    final confirmed = await _showActionInputSheet(
      title: 'Withdraw to crypto address',
      primaryLabel: 'Create proposal',
      body: Column(
        children: [
          _TextInput(
            controller: _amountController,
            label: 'Amount',
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
          ),
          const SizedBox(height: 12),
          _TextInput(
            controller: _destinationAddressController,
            label: 'Destination address',
            keyboardType: TextInputType.text,
          ),
        ],
      ),
    );
    if (confirmed != true) {
      return;
    }
    final response = await _client.createCryptoOfframp(
      userId: _requiredUserId,
      smartWalletId: _requiredSmartWallet.id,
      amount: _amountController.text.trim(),
      destinationAddress: _destinationAddressController.text.trim(),
      destinationChain: 'Base',
      destinationCurrency: 'USDC',
    );
    setState(() {
      _message =
          'Crypto withdrawal proposal created. Admins approve and sign it.';
      _lastResponse = _prettyJson(response);
    });
  }

  Future<void> _executeWithdrawBank() async {
    switch (_selectedCurrency) {
      case WalletCurrencyOption.usd:
        await _withdrawBankUsd();
      case WalletCurrencyOption.ngn:
        await _withdrawBankNgn();
      case WalletCurrencyOption.eur:
      case WalletCurrencyOption.cad:
        throw const ExampleException('Unsupported bank withdrawal currency.');
    }
  }

  Future<void> _withdrawBankUsd() async {
    final userId = _requiredUserId;
    final smartWalletId = _requiredSmartWallet.id;
    final raw = await _client.getBankAccounts(userId);
    final usa = ProxyApiClient.extractUsaWithdrawals(raw);
    if (!mounted) {
      return;
    }
    if (usa.isEmpty) {
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('No US payout account'),
          content: const Text(
            'You need a saved US withdrawal bank account before ACH offramp. '
            'Provision one through your partner / Bridge flow, then '
            'GET …/bank-accounts → withdrawalAccounts → usaAccounts.\n\n'
            'Deposit VBAs (ACH in) are separate from payout accounts.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('OK'),
            ),
          ],
        ),
      );
      return;
    }
    final bankAccountId = await _pickWithdrawalBankAccountId(
      context: context,
      accounts: usa,
      title: 'US payout account',
    );
    if (bankAccountId == null || !mounted) {
      return;
    }
    final confirmed = await _showActionInputSheet(
      title: 'ACH withdrawal',
      primaryLabel: 'Create proposal',
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Bank account id: $bankAccountId',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          _TextInput(
            controller: _amountController,
            label: 'Amount (USDB)',
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
          ),
        ],
      ),
    );
    if (confirmed != true) {
      return;
    }
    final response = await _client.offrampUsBankAccount(
      userId: userId,
      smartWalletId: smartWalletId,
      bankAccountId: bankAccountId,
      amount: _amountController.text.trim(),
    );
    setState(() {
      _message = 'US ACH offramp proposal created.';
      _lastResponse = _prettyJson(response);
    });
  }

  Future<void> _withdrawBankNgn() async {
    final proposal = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (ctx) => _NigeriaBankWithdrawalDialog(
        client: _client,
        userId: _requiredUserId,
        smartWalletId: _requiredSmartWallet.id,
      ),
    );
    if (proposal == null || !mounted) {
      return;
    }
    setState(() {
      _message =
          'Nigerian bank offramp proposal created. Admins approve and sign it.';
      _lastResponse = _prettyJson(proposal);
    });
  }

  Future<String?> _pickWithdrawalBankAccountId({
    required BuildContext context,
    required List<Map<String, dynamic>> accounts,
    required String title,
  }) {
    return showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(title),
        children: [
          for (final a in accounts)
            SimpleDialogOption(
              onPressed: () {
                final id = ProxyApiClient.readBankAccountId(a);
                if (id != null) {
                  Navigator.pop(ctx, id);
                }
              },
              child: Text(
                '${a['bankName'] ?? 'Bank'} · '
                '${ProxyApiClient.readBankAccountId(a) ?? '?'}',
              ),
            ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
  }

  Future<void> _handleSwap() => _runTask(() async {
    final active = await _ensureKycReady();
    if (!active) {
      return;
    }
    final confirmed = await _showActionInputSheet(
      title: 'Preview swap',
      primaryLabel: 'Preview',
      body: Column(
        children: [
          _TextInput(
            controller: _amountController,
            label: 'Amount',
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
          ),
          const SizedBox(height: 12),
          _TextInput(
            controller: _toCurrencyController,
            label: 'To currency',
            textCapitalization: TextCapitalization.characters,
          ),
        ],
      ),
    );
    if (confirmed != true) {
      return;
    }
    final response = await _client.convertCurrency(
      userId: _requiredUserId,
      amount: _amountController.text.trim(),
      from: _selectedCurrency.fiatCode,
      to: _toCurrencyController.text.trim().toUpperCase(),
    );
    setState(() {
      _message = 'Swap preview returned by the exchange endpoint.';
      _lastResponse = _prettyJson(response);
    });
  });

  Future<bool> _ensureKycReady() async {
    final status = await _client.getOnboardingStatus(_requiredUserId);
    if (_isKycActiveForSelectedCurrency(status)) {
      return true;
    }
    if (_isKycPendingForSelectedCurrency(status)) {
      await _showPendingVerificationDialog();
      return false;
    }
    await _openKycWizard(status);
    return false;
  }

  Future<void> _showPendingVerificationDialog() async {
    if (!mounted) {
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Verification in progress'),
        content: const Text(
          'Your information has already been submitted and is being reviewed. '
          'You do not need to complete KYC again. Top up, withdraw, and swap '
          'will be available once onboarding is marked active.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  Future<void> _openKycWizard(Map<String, dynamic> status) async {
    try {
      final options = await _client.getKycOptions(_requiredUserId);
      if (!mounted) {
        return;
      }
      setState(() {
        _kycOptionsJson = options;
        _kycOccupationCode = null;
        _kycOccupationLabel = null;
        _kycOccupationHits = [];
        _kycGender = null;
        _kycEmploymentStatus = null;
        _kycSourceOfFunds = null;
        _kycAccountPurpose = null;
        _kycEstimatedMonthlyVolume = null;
        _kycIdFrontBytes = null;
        _kycIdBackBytes = null;
        _kycIdFrontFilename = null;
        _kycIdBackFilename = null;
        _kycPoaBytes = null;
        _kycPoaBackBytes = null;
        _kycPoaFilename = null;
        _kycPoaBackFilename = null;
        _bridgeSigningUrl = null;
        _bridgeSignedAgreementIdController.clear();
        _kycIdDocType = null;
        _kycPoaDocType = 'utility_bill';
        _applyKycOptionDefaults();
        _kycPageIndex = 0;
        _message =
            'Complete KYC (${_selectedCurrency.label}). Submit saves your '
            'profile, activates verification, then starts '
            '${_selectedCurrency.kycProviderLabel}.';
        _lastResponse = _prettyJson(status);
        _step = ExampleStep.kycWizard;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _step != ExampleStep.kycWizard) {
          return;
        }
        if (_kycPageController.hasClients) {
          _kycPageController.jumpToPage(0);
        }
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _error = error.toString();
        _message = 'Could not load KYC options. Fix the error and retry.';
        _lastResponse = _prettyJson(status);
      });
    }
  }

  void _applyKycOptionDefaults() {
    final json = _kycOptionsJson;
    if (json == null) {
      return;
    }
    _kycGender ??= _firstString(json['genders']) ?? 'female';
    _kycEmploymentStatus ??=
        _firstString(json['employmentStatuses']) ?? 'employed';
    _kycSourceOfFunds ??= _firstString(json['fundsSources']) ?? 'salary';
    _kycAccountPurpose ??= _firstString(json['accountPurposes']) ?? 'personal';
    _kycEstimatedMonthlyVolume ??=
        _firstMonthlyVolumeValue(json['estimatedMonthlyVolumeRanges']) ?? 5000;
    _kycIdDocType ??= 'passport';
  }

  String? _firstString(Object? raw) {
    if (raw is List && raw.isNotEmpty && raw.first is String) {
      return raw.first as String;
    }
    return null;
  }

  int? _firstMonthlyVolumeValue(Object? raw) {
    if (raw is List && raw.isNotEmpty) {
      final first = raw.first;
      if (first is Map<String, dynamic>) {
        final v = first['value'];
        if (v is int) {
          return v;
        }
        if (v is num) {
          return v.round();
        }
      }
    }
    return null;
  }

  void _exitKycWizard() {
    setState(() {
      _step = ExampleStep.walletHome;
      _message = 'KYC wizard closed. Retry the action when you are ready.';
    });
  }

  Future<void> _searchKycOccupations() => _runTask(() async {
    final hits = await _client.getKycOccupations(
      userId: _requiredUserId,
      search: _kycOccupationSearchController.text.trim(),
    );
    setState(() => _kycOccupationHits = hits);
  });

  Future<void> _pickKycIdFront() => _pickKycImage(
    onBytes: (b, name) => setState(() {
      _kycIdFrontBytes = b;
      _kycIdFrontFilename = name;
    }),
  );

  Future<void> _pickKycIdBack() => _pickKycImage(
    onBytes: (b, name) => setState(() {
      _kycIdBackBytes = b;
      _kycIdBackFilename = name;
    }),
  );

  Future<void> _pickKycPoaFront() => _pickKycImage(
    onBytes: (b, name) => setState(() {
      _kycPoaBytes = b;
      _kycPoaFilename = name;
    }),
  );

  Future<void> _pickKycPoaBack() => _pickKycImage(
    onBytes: (b, name) => setState(() {
      _kycPoaBackBytes = b;
      _kycPoaBackFilename = name;
    }),
  );

  Future<void> _pickKycImage({
    required void Function(Uint8List bytes, String filename) onBytes,
  }) async {
    try {
      final file = await _imagePicker.pickImage(source: ImageSource.gallery);
      if (file == null) {
        return;
      }
      final bytes = await file.readAsBytes();
      final name = file.name.trim().isNotEmpty ? file.name : 'upload.jpg';
      onBytes(bytes, name);
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() => _error = error.toString());
    }
  }

  Future<void> _fetchBridgeSigningUrl() => _runTask(() async {
    final json = await _client.getBridgeAgreementUrl(_requiredUserId);
    final url = ProxyApiClient.readBridgeSigningUrl(json);
    if (url == null || url.isEmpty) {
      throw const ExampleException(
        'Bridge signing URL missing from API response.',
      );
    }
    setState(() {
      _bridgeSigningUrl = url;
      _message =
          'Open the Bridge link, accept Terms, then paste the signed '
          'agreement UUID (or full redirect URL) below.';
    });
  });

  Future<void> _openBridgeSigningUrlInBrowser() async {
    final url = _bridgeSigningUrl;
    if (url == null || url.isEmpty) {
      setState(() => _error = 'Tap “Generate Bridge link” first.');
      return;
    }
    final uri = Uri.tryParse(url);
    if (uri == null) {
      setState(() => _error = 'Bridge URL could not be parsed.');
      return;
    }
    final launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!launched && mounted) {
      setState(() => _error = 'Could not open the Bridge URL on this device.');
    }
  }

  bool _isUuid(String value) {
    final s = value.trim();
    return RegExp(
      r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-'
      r'[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$',
    ).hasMatch(s);
  }

  /// Accepts a raw UUID or a redirect URL whose query contains the agreement id.
  String? _parseBridgeAgreementId(String raw) {
    final t = raw.trim();
    if (t.isEmpty) {
      return null;
    }
    if (_isUuid(t)) {
      return t;
    }
    final uri = Uri.tryParse(t);
    if (uri != null) {
      const keys = [
        'signedAgreementId',
        'signed_agreement_id',
        'developer_id',
        'developerId',
        'agreementId',
        'agreement_id',
      ];
      for (final k in keys) {
        final v = uri.queryParameters[k];
        if (v != null && _isUuid(v)) {
          return v.trim();
        }
      }
    }
    final embedded = RegExp(
      r'[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-'
      r'[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}',
    ).firstMatch(t);
    return embedded?.group(0);
  }

  Future<void> _submitKycWizard() => _runTask(() async {
    final userId = _requiredUserId;
    final bvn = _kycBvnController.text.trim();
    if (_selectedCurrency == WalletCurrencyOption.ngn) {
      if (bvn.length != 11 || int.tryParse(bvn) == null) {
        throw const ExampleException(
          'Enter a valid 11-digit BVN for Nigeria onboarding.',
        );
      }
    }

    final patchBody = <String, dynamic>{
      // Matches upstream partial KYC personal info (see bmoni-api
      // `PartialPersonalInfoSchema`).
      'personalInfo': {
        'firstName': _firstNameController.text.trim(),
        'lastName': _lastNameController.text.trim(),
        if (_kycMiddleNameController.text.trim().isNotEmpty)
          'middleName': _kycMiddleNameController.text.trim(),
        'phoneNumber': _phoneController.text.trim(),
        'dateOfBirth': _kycDobController.text.trim(),
        'gender': _kycGender,
      },
      'address': {
        'streetLine1': _kycStreet1Controller.text.trim(),
        if (_kycStreet2Controller.text.trim().isNotEmpty)
          'streetLine2': _kycStreet2Controller.text.trim(),
        'city': _kycCityController.text.trim(),
        'state': _kycStateController.text.trim(),
        'postalCode': _kycPostalController.text.trim(),
        'countryCode': _kycCountryCodeController.text.trim().toUpperCase(),
      },
      'employment': {
        'occupationCode': _kycOccupationCode,
        'employerName': _kycEmployerController.text.trim(),
        'employmentStatus': _kycEmploymentStatus,
      },
      'sourceOfFunds': _kycSourceOfFunds,
      'estimatedMonthlyVolume': _kycEstimatedMonthlyVolume,
      'accountPurpose': _kycAccountPurpose,
      'actingAsIntermediary': _kycActingAsIntermediary,
      if (_selectedCurrency == WalletCurrencyOption.ngn)
        'identificationNumbers': [
          {'type': 'bvn', 'number': bvn, 'issuingCountryCode': 'NGA'},
        ],
    };

    final patchResult = await _client.patchKyc(userId: userId, body: patchBody);

    final idFront = _kycIdFrontBytes;
    final poa = _kycPoaBytes;
    if (idFront == null || poa == null) {
      throw const ExampleException(
        'ID front image and proof-of-address image are required before submit.',
      );
    }

    final idUpload = await _client.uploadKycIdentificationDocument(
      userId: userId,
      files: [
        http.MultipartFile.fromBytes(
          'files',
          idFront,
          filename: _kycIdFrontFilename ?? 'identification_front.jpg',
          contentType: multipartMediaTypeForFilename(_kycIdFrontFilename),
        ),
        if (_kycIdBackBytes != null)
          http.MultipartFile.fromBytes(
            'files',
            _kycIdBackBytes!,
            filename: _kycIdBackFilename ?? 'identification_back.jpg',
            contentType: multipartMediaTypeForFilename(_kycIdBackFilename),
          ),
      ],
      type: _kycIdDocType ?? 'passport',
      documentNumber: _kycIdDocumentNumberController.text.trim(),
      issuingCountry: _kycIdIssuingCountryController.text.trim().toUpperCase(),
      expirationDate: _kycIdExpirationController.text.trim(),
      issueDate: _kycIdIssueController.text.trim(),
    );

    final poaFiles = <http.MultipartFile>[
      http.MultipartFile.fromBytes(
        'files',
        poa,
        filename: _kycPoaFilename ?? 'proof_of_address.jpg',
        contentType: multipartMediaTypeForFilename(_kycPoaFilename),
      ),
      if (_kycPoaBackBytes != null)
        http.MultipartFile.fromBytes(
          'files',
          _kycPoaBackBytes!,
          filename: _kycPoaBackFilename ?? 'proof_of_address_back.jpg',
          contentType: multipartMediaTypeForFilename(_kycPoaBackFilename),
        ),
    ];
    final poaUpload = await _client.uploadKycProofOfAddress(
      userId: userId,
      files: poaFiles,
      type: _kycPoaDocType,
    );

    Map<String, dynamic>? bridgeStoreResult;
    if (_needsBridgeAgreement) {
      final agreementId = _parseBridgeAgreementId(
        _bridgeSignedAgreementIdController.text,
      );
      if (agreementId == null) {
        throw const ExampleException(
          'Paste the Bridge signed agreement UUID (or full redirect URL) '
          'before submitting.',
        );
      }
      bridgeStoreResult = await _client.storeBridgeAgreement(
        userId: userId,
        signedAgreementId: agreementId,
      );
    }

    final readinessResult = await _client.getKycReadiness(userId);

    final sumsubLevel = switch (_selectedCurrency) {
      WalletCurrencyOption.ngn => null,
      WalletCurrencyOption.cad => null,
      _ => 'id-and-liveness',
    };
    final activateResult = await _client.activateKyc(
      userId: userId,
      sumsubLevelName: sumsubLevel,
    );

    final startBody = await _client.startKyc(
      userId: userId,
      currency: _selectedCurrency,
      smartWallet: _requiredSmartWallet,
      nigeriaBvn: _selectedCurrency == WalletCurrencyOption.ngn ? bvn : null,
    );

    setState(() {
      _step = ExampleStep.walletHome;
      _message =
          'KYC profile saved, documents uploaded, Bridge step completed where '
          'needed, verification activated, and '
          '${_selectedCurrency.kycProviderLabel} started. Retry your action.';
      _lastResponse = _prettyJson({
        'patchKyc': patchResult,
        'uploadIdentification': idUpload,
        'uploadProofOfAddress': poaUpload,
        'storeBridgeAgreement': bridgeStoreResult,
        'readiness': readinessResult,
        'activateKyc': activateResult,
        'startOnboarding': startBody,
      });
    });
  });

  bool _validateKycPage(int index) {
    switch (index) {
      case 0:
        if (_firstNameController.text.trim().isEmpty ||
            _lastNameController.text.trim().isEmpty ||
            _phoneController.text.trim().isEmpty ||
            _kycDobController.text.trim().isEmpty ||
            _kycGender == null ||
            _kycGender!.isEmpty) {
          setState(() {
            _error =
                'Personal: fill first and last name, phone, DOB (YYYY-MM-DD), '
                'and gender.';
          });
          return false;
        }
      case 1:
        if (_kycStreet1Controller.text.trim().isEmpty ||
            _kycCityController.text.trim().isEmpty ||
            _kycStateController.text.trim().isEmpty ||
            _kycPostalController.text.trim().isEmpty ||
            _kycCountryCodeController.text.trim().length != 3) {
          setState(() {
            _error =
                'Address: street, city, state, postal code, and ISO alpha-3 '
                'country (e.g. NGA).';
          });
          return false;
        }
      case 2:
        if (_kycOccupationCode == null ||
            _kycOccupationCode!.isEmpty ||
            _kycEmployerController.text.trim().isEmpty ||
            _kycEmploymentStatus == null ||
            _kycEmploymentStatus!.isEmpty) {
          setState(() {
            _error =
                'Employment: search and select an occupation, employer, and '
                'status.';
          });
          return false;
        }
      case 3:
        if (_kycSourceOfFunds == null ||
            _kycAccountPurpose == null ||
            _kycEstimatedMonthlyVolume == null) {
          setState(() {
            _error =
                'Compliance: pick source of funds, account purpose, and '
                'expected monthly volume.';
          });
          return false;
        }
        if (_selectedCurrency == WalletCurrencyOption.ngn) {
          final bvn = _kycBvnController.text.trim();
          if (bvn.length != 11 || int.tryParse(bvn) == null) {
            setState(() => _error = 'Enter an 11-digit BVN.');
            return false;
          }
        }
      case 4:
        if (_kycIdFrontBytes == null || _kycPoaBytes == null) {
          setState(() {
            _error =
                'Documents: pick ID front and proof-of-address images '
                '(gallery). ID back is optional.';
          });
          return false;
        }
        if (_kycIdDocType == null ||
            _kycIdDocType!.isEmpty ||
            _kycIdDocumentNumberController.text.trim().isEmpty ||
            _kycIdIssuingCountryController.text.trim().length != 3 ||
            _kycIdExpirationController.text.trim().isEmpty) {
          setState(() {
            _error =
                'Documents: choose ID type, document number, ISO alpha-3 '
                'issuing country, and expiration date.';
          });
          return false;
        }
      case 5:
        if (_needsBridgeAgreement) {
          final id = _parseBridgeAgreementId(
            _bridgeSignedAgreementIdController.text,
          );
          if (id == null) {
            setState(() {
              _error =
                  'Bridge: generate the signing URL, complete TOS in the '
                  'browser, then paste the signed agreement UUID or full '
                  'redirect URL.';
            });
            return false;
          }
        }
      default:
        break;
    }
    setState(() => _error = null);
    return true;
  }

  void _kycGoNext() {
    if (!_validateKycPage(_kycPageIndex)) {
      return;
    }
    if (_kycPageIndex >= _kycPageCount - 1) {
      return;
    }
    final next = _kycPageIndex + 1;
    setState(() => _kycPageIndex = next);
    if (_kycPageController.hasClients) {
      _kycPageController.animateToPage(
        next,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
    }
  }

  void _kycGoBack() {
    if (_kycPageIndex <= 0) {
      _exitKycWizard();
      return;
    }
    final prev = _kycPageIndex - 1;
    setState(() => _kycPageIndex = prev);
    if (_kycPageController.hasClients) {
      _kycPageController.animateToPage(
        prev,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
    }
  }

  String? _onboardingRailStatusForSelectedCurrency(
    Map<String, dynamic> status,
  ) {
    String? valueFor(List<String> keys) {
      for (final key in keys) {
        final value = status[key];
        if (value is String) {
          return value;
        }
      }
      return null;
    }

    return switch (_selectedCurrency) {
      WalletCurrencyOption.usd => valueFor(['bridgeStatus']),
      WalletCurrencyOption.cad => valueFor(['paytrieStatus']),
      WalletCurrencyOption.eur => valueFor([
        'moneriumStatus',
        'moneriumStatusOrNotStarted',
      ]),
      WalletCurrencyOption.ngn => valueFor(['anchorStatus']),
    };
  }

  bool _isKycActiveForSelectedCurrency(Map<String, dynamic> status) {
    final normalized = _onboardingRailStatusForSelectedCurrency(
      status,
    )?.toLowerCase();
    return normalized == 'active' ||
        normalized == 'approved' ||
        normalized == 'completed';
  }

  bool _isKycPendingForSelectedCurrency(Map<String, dynamic> status) {
    return _onboardingRailStatusForSelectedCurrency(status)?.toLowerCase() ==
        'pending';
  }

  Future<bool?> _showActionInputSheet({
    required String title,
    required String primaryLabel,
    required Widget body,
  }) {
    return showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) {
        return Padding(
          padding: EdgeInsets.fromLTRB(
            20,
            8,
            20,
            MediaQuery.of(context).viewInsets.bottom + 24,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(title, style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 16),
              body,
              const SizedBox(height: 20),
              BMoniButton.primary(
                onPressed: () => Navigator.pop(context, true),
                text: primaryLabel,
              ),
            ],
          ),
        );
      },
    );
  }

  String get _requiredUserId {
    final userId = _profile?.bmoniUserId;
    if (userId == null || userId.isEmpty) {
      throw const ExampleException('Create an account first.');
    }
    return userId;
  }

  SmartWallet get _requiredSmartWallet {
    final wallet = _smartWallet;
    if (!_walletReady(wallet)) {
      throw const ExampleException(
        'No deployed smart wallet id on this session. Use “Create smart wallet” '
        'on the currency screen so the API returns a wallet id.',
      );
    }
    return wallet!;
  }

  EmbeddedWallet? get _walletCardModel {
    final smartWallet = _smartWallet;
    if (!_walletReady(smartWallet)) {
      return null;
    }
    final w = smartWallet!;
    final cardCurrency = WalletCurrencyOption.fromSmartWalletCurrency(
      w.currency,
    );
    return EmbeddedWallet(
      walletId: w.id,
      walletIndex: 0,
      name: '${cardCurrency.label} wallet',
      currency: cardCurrency.fiatCode,
      balance: 0,
      isDefault: true,
      isActive: w.status.toUpperCase() == 'ACTIVE' || w.status.isEmpty,
      description: w.smartAccountAddress ?? w.walletAddress,
      createdAt: w.createdAt ?? '',
    );
  }

  String _prettyJson(Object value) {
    return const JsonEncoder.withIndent('  ').convert(value);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('BMoni Embedded API Example'),
        leading: _step == ExampleStep.kycWizard
            ? IconButton(
                tooltip: 'Close KYC',
                onPressed: _isBusy ? null : _exitKycWizard,
                icon: const Icon(Icons.close),
              )
            : null,
        actions: [
          if (_step == ExampleStep.walletHome ||
              _step == ExampleStep.unlock ||
              _step == ExampleStep.kycWizard)
            IconButton(
              tooltip: 'Log out',
              onPressed: _isBusy ? null : _logout,
              icon: const Icon(Icons.logout),
            ),
        ],
      ),
      body: SafeArea(
        child: Stack(
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                  child: _StatusPanel(message: _message, error: _error),
                ),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                    child: switch (_step) {
                      ExampleStep.loading => const Center(
                        child: _LoadingView(),
                      ),
                      ExampleStep.kycWizard => _buildKycWizardView(),
                      _ => ListView(
                        padding: const EdgeInsets.only(bottom: 32),
                        children: [
                          switch (_step) {
                            ExampleStep.createAccount =>
                              _buildCreateAccountView(),
                            ExampleStep.unlock => _buildUnlockView(),
                            ExampleStep.selectCurrency => _buildCurrencyView(),
                            ExampleStep.walletHome => _buildWalletHomeView(),
                            ExampleStep.loading ||
                            ExampleStep.kycWizard => const SizedBox.shrink(),
                          },
                          if (_lastResponse != null) ...[
                            const SizedBox(height: 16),
                            _LastResponsePanel(value: _lastResponse!),
                          ],
                          const SizedBox(height: 32),
                        ],
                      ),
                    },
                  ),
                ),
              ],
            ),
            if (_isBusy)
              const Positioned.fill(
                child: ColoredBox(
                  color: Color(0x66000000),
                  child: Center(child: CircularProgressIndicator.adaptive()),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildKycWizardView() {
    final options = _kycOptionsJson;
    final genders =
        (options?['genders'] as List?)?.whereType<String>().toList() ??
        const ['male', 'female', 'other'];
    final employmentStatuses =
        (options?['employmentStatuses'] as List?)
            ?.whereType<String>()
            .toList() ??
        const [
          'employed',
          'self_employed',
          'unemployed',
          'retired',
          'student',
          'homemaker',
        ];
    final fundsSources =
        (options?['fundsSources'] as List?)?.whereType<String>().toList() ??
        const [
          'salary',
          'business',
          'investments',
          'pension',
          'government',
          'inheritance',
          'savings',
        ];
    final accountPurposes =
        (options?['accountPurposes'] as List?)?.whereType<String>().toList() ??
        const ['personal', 'business', 'investment'];
    final volumeRanges = _parseVolumeRanges(
      options?['estimatedMonthlyVolumeRanges'],
    );
    final idTypes = () {
      final fromApi =
          (options?['identificationTypes'] as List?)?.whereType<String>() ??
          const <String>[];
      final allowed = fromApi
          .where(kycIdentificationUploadTypes.contains)
          .toList();
      return allowed.isNotEmpty ? allowed : kycIdentificationUploadTypes;
    }();
    final poaTypes = kycProofOfAddressUploadTypes;

    String stepTitle(int i) => switch (i) {
      0 => 'Personal',
      1 => 'Address',
      2 => 'Employment',
      3 => 'Compliance',
      4 => 'Documents',
      5 => 'Bridge TOS',
      _ => 'Review',
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LinearProgressIndicator(value: (_kycPageIndex + 1) / _kycPageCount),
        const SizedBox(height: 8),
        Text(
          'Step ${_kycPageIndex + 1} of $_kycPageCount · '
          '${stepTitle(_kycPageIndex)}',
          style: Theme.of(context).textTheme.titleSmall,
        ),
        const SizedBox(height: 12),
        Expanded(
          child: PageView(
            controller: _kycPageController,
            physics: const NeverScrollableScrollPhysics(),
            children: [
              ListView(
                children: [
                  _TwoColumnFields(
                    first: _TextInput(
                      controller: _firstNameController,
                      label: 'First name',
                    ),
                    second: _TextInput(
                      controller: _lastNameController,
                      label: 'Last name',
                    ),
                  ),
                  const SizedBox(height: 12),
                  _TextInput(
                    controller: _kycMiddleNameController,
                    label: 'Middle name (optional)',
                  ),
                  const SizedBox(height: 12),
                  _TwoColumnFields(
                    first: _TextInput(
                      controller: _emailController,
                      label: 'Email (account)',
                      keyboardType: TextInputType.emailAddress,
                    ),
                    second: _TextInput(
                      controller: _phoneController,
                      label: 'Phone (KYC)',
                      keyboardType: TextInputType.phone,
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(top: 8, bottom: 4),
                    child: Text(
                      'Email is stored on your user record from sign-up; '
                      'phone and name here are sent with PATCH /kyc.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                  const SizedBox(height: 12),
                  _TextInput(
                    controller: _kycDobController,
                    label: 'Date of birth (YYYY-MM-DD)',
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    initialValue: _kycGender,
                    decoration: const InputDecoration(
                      labelText: 'Gender',
                      border: OutlineInputBorder(),
                    ),
                    items: genders
                        .map((g) => DropdownMenuItem(value: g, child: Text(g)))
                        .toList(),
                    onChanged: _isBusy
                        ? null
                        : (v) => setState(() => _kycGender = v),
                  ),
                ],
              ),
              ListView(
                children: [
                  _TextInput(
                    controller: _kycStreet1Controller,
                    label: 'Street line 1',
                  ),
                  const SizedBox(height: 12),
                  _TextInput(
                    controller: _kycStreet2Controller,
                    label: 'Street line 2 (optional)',
                  ),
                  const SizedBox(height: 12),
                  _TwoColumnFields(
                    first: _TextInput(
                      controller: _kycCityController,
                      label: 'City',
                    ),
                    second: _TextInput(
                      controller: _kycStateController,
                      label: 'State / province',
                    ),
                  ),
                  const SizedBox(height: 12),
                  _TwoColumnFields(
                    first: _TextInput(
                      controller: _kycPostalController,
                      label: 'Postal code',
                    ),
                    second: _TextInput(
                      controller: _kycCountryCodeController,
                      label: 'Country (ISO alpha-3)',
                      textCapitalization: TextCapitalization.characters,
                    ),
                  ),
                ],
              ),
              ListView(
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: _TextInput(
                          controller: _kycOccupationSearchController,
                          label: 'Search occupation',
                        ),
                      ),
                      const SizedBox(width: 8),
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: IconButton.filled(
                          onPressed: _isBusy ? null : _searchKycOccupations,
                          icon: const Icon(Icons.search),
                        ),
                      ),
                    ],
                  ),
                  if (_kycOccupationLabel != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text(
                        'Selected: $_kycOccupationLabel '
                        '(${_kycOccupationCode ?? ''})',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  ..._kycOccupationHits.map((hit) {
                    final name =
                        hit['displayName'] as String? ??
                        hit['socCode'] as String? ??
                        'Occupation';
                    final id = hit['id'] as String?;
                    final soc = hit['socCode'] as String?;
                    final code = (id != null && id.isNotEmpty)
                        ? id
                        : (soc ?? '');
                    return ListTile(
                      dense: true,
                      title: Text(name),
                      subtitle: Text(
                        id != null
                            ? 'Id: $id · SOC: ${soc ?? '—'}'
                            : 'SOC: $code',
                      ),
                      onTap: _isBusy
                          ? null
                          : () {
                              setState(() {
                                _kycOccupationCode = code.isNotEmpty
                                    ? code
                                    : null;
                                _kycOccupationLabel = name;
                              });
                            },
                    );
                  }),
                  const SizedBox(height: 12),
                  _TextInput(
                    controller: _kycEmployerController,
                    label: 'Employer name',
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    initialValue: _kycEmploymentStatus,
                    decoration: const InputDecoration(
                      labelText: 'Employment status',
                      border: OutlineInputBorder(),
                    ),
                    items: employmentStatuses
                        .map((g) => DropdownMenuItem(value: g, child: Text(g)))
                        .toList(),
                    onChanged: _isBusy
                        ? null
                        : (v) => setState(() => _kycEmploymentStatus = v),
                  ),
                ],
              ),
              ListView(
                children: [
                  DropdownButtonFormField<String>(
                    initialValue: _kycSourceOfFunds,
                    decoration: const InputDecoration(
                      labelText: 'Source of funds',
                      border: OutlineInputBorder(),
                    ),
                    items: fundsSources
                        .map((g) => DropdownMenuItem(value: g, child: Text(g)))
                        .toList(),
                    onChanged: _isBusy
                        ? null
                        : (v) => setState(() => _kycSourceOfFunds = v),
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    initialValue: _kycAccountPurpose,
                    decoration: const InputDecoration(
                      labelText: 'Account purpose',
                      border: OutlineInputBorder(),
                    ),
                    items: accountPurposes
                        .map((g) => DropdownMenuItem(value: g, child: Text(g)))
                        .toList(),
                    onChanged: _isBusy
                        ? null
                        : (v) => setState(() => _kycAccountPurpose = v),
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<int>(
                    initialValue: _kycEstimatedMonthlyVolume,
                    decoration: const InputDecoration(
                      labelText: 'Est. monthly volume (USD)',
                      border: OutlineInputBorder(),
                    ),
                    items: volumeRanges
                        .map(
                          (r) => DropdownMenuItem(
                            value: r.value,
                            child: Text(r.label),
                          ),
                        )
                        .toList(),
                    onChanged: _isBusy
                        ? null
                        : (v) => setState(() => _kycEstimatedMonthlyVolume = v),
                  ),
                  const SizedBox(height: 12),
                  SwitchListTile(
                    title: const Text('Acting as intermediary'),
                    value: _kycActingAsIntermediary,
                    onChanged: _isBusy
                        ? null
                        : (v) => setState(() => _kycActingAsIntermediary = v),
                  ),
                  if (_selectedCurrency == WalletCurrencyOption.ngn) ...[
                    const SizedBox(height: 8),
                    _TextInput(
                      controller: _kycBvnController,
                      label: 'BVN (11 digits)',
                      keyboardType: TextInputType.number,
                      inputFormatters: [
                        FilteringTextInputFormatter.digitsOnly,
                        LengthLimitingTextInputFormatter(11),
                      ],
                    ),
                  ],
                ],
              ),
              ListView(
                children: [
                  Text(
                    'Upload ID & proof of address',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Uses POST …/kyc/documents/identification and '
                    '…/documents/proof-of-address (multipart).',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      BMoniButton.secondary(
                        onPressed: _isBusy ? null : _pickKycIdFront,
                        text: _kycIdFrontBytes == null
                            ? 'ID front'
                            : 'ID front ✓',
                      ),
                      BMoniButton.secondary(
                        onPressed: _isBusy ? null : _pickKycIdBack,
                        text: _kycIdBackBytes == null
                            ? 'ID back (opt.)'
                            : 'ID back ✓',
                      ),
                      BMoniButton.secondary(
                        onPressed: _isBusy ? null : _pickKycPoaFront,
                        text: _kycPoaBytes == null ? 'PoA front' : 'PoA ✓',
                      ),
                      BMoniButton.secondary(
                        onPressed: _isBusy ? null : _pickKycPoaBack,
                        text: _kycPoaBackBytes == null
                            ? 'PoA back (opt.)'
                            : 'PoA back ✓',
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  DropdownButtonFormField<String>(
                    initialValue: _kycIdDocType,
                    decoration: const InputDecoration(
                      labelText: 'ID document type',
                      border: OutlineInputBorder(),
                    ),
                    items: idTypes
                        .map((t) => DropdownMenuItem(value: t, child: Text(t)))
                        .toList(),
                    onChanged: _isBusy
                        ? null
                        : (v) => setState(() => _kycIdDocType = v),
                  ),
                  const SizedBox(height: 12),
                  _TextInput(
                    controller: _kycIdDocumentNumberController,
                    label: 'Document number',
                  ),
                  const SizedBox(height: 12),
                  _TextInput(
                    controller: _kycIdIssuingCountryController,
                    label: 'Issuing country (ISO alpha-3)',
                    textCapitalization: TextCapitalization.characters,
                  ),
                  const SizedBox(height: 12),
                  _TwoColumnFields(
                    first: _TextInput(
                      controller: _kycIdExpirationController,
                      label: 'Expiration (YYYY-MM-DD)',
                    ),
                    second: _TextInput(
                      controller: _kycIdIssueController,
                      label: 'Issue date (YYYY-MM-DD)',
                    ),
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    initialValue: _kycPoaDocType,
                    decoration: const InputDecoration(
                      labelText: 'Proof-of-address type',
                      border: OutlineInputBorder(),
                    ),
                    items: poaTypes
                        .map((t) => DropdownMenuItem(value: t, child: Text(t)))
                        .toList(),
                    onChanged: _isBusy
                        ? null
                        : (v) => setState(
                            () => _kycPoaDocType = v ?? 'utility_bill',
                          ),
                  ),
                ],
              ),
              ListView(
                children: [
                  if (_needsBridgeAgreement) ...[
                    Text(
                      'Bridge Terms of Service',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Generate the signing URL (GET …/kyc/agreement-url), '
                      'open it, complete TOS, then paste the signed agreement UUID '
                      'from the redirect query (e.g. developer_id) or paste the '
                      'full URL.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const SizedBox(height: 12),
                    BMoniButton.secondary(
                      onPressed: _isBusy ? null : _fetchBridgeSigningUrl,
                      text: 'Generate Bridge link',
                    ),
                    const SizedBox(height: 8),
                    if (_bridgeSigningUrl != null)
                      SelectableText(
                        _bridgeSigningUrl!,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    const SizedBox(height: 8),
                    BMoniButton.secondary(
                      onPressed: _isBusy
                          ? null
                          : _openBridgeSigningUrlInBrowser,
                      text: 'Open in browser',
                    ),
                    const SizedBox(height: 16),
                    _TextInput(
                      controller: _bridgeSignedAgreementIdController,
                      label: 'Signed agreement UUID or redirect URL',
                      keyboardType: TextInputType.url,
                    ),
                  ] else
                    Text(
                      'Bridge TOS is only required for USD (Bridge) wallets. '
                      'Tap Next to review.',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                ],
              ),
              ListView(
                padding: const EdgeInsets.only(bottom: 24),
                children: [
                  Text(
                    'Review',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '${_firstNameController.text.trim()} '
                    '${_lastNameController.text.trim()} · '
                    '${_emailController.text.trim()}',
                  ),
                  Text(
                    'Address: ${_kycStreet1Controller.text.trim()}, '
                    '${_kycCityController.text.trim()}, '
                    '${_kycCountryCodeController.text.trim()}',
                  ),
                  Text(
                    'Employment: ${_kycOccupationLabel ?? '—'} '
                    '(${_kycOccupationCode ?? '—'}) · '
                    '${_kycEmployerController.text.trim()}',
                  ),
                  Text(
                    'Funds: ${_kycSourceOfFunds ?? '—'} · '
                    'Purpose: ${_kycAccountPurpose ?? '—'} · '
                    'Volume: ${_kycEstimatedMonthlyVolume ?? '—'}',
                  ),
                  if (_selectedCurrency == WalletCurrencyOption.ngn)
                    Text('BVN: ${_kycBvnController.text.trim()}'),
                  Text(
                    'Documents: ID ${_kycIdDocType ?? '—'} · '
                    'PoA $_kycPoaDocType · '
                    '${_kycIdFrontBytes != null ? "ID file ready" : "no ID file"} · '
                    '${_kycPoaBytes != null ? "PoA ready" : "no PoA"}',
                  ),
                  if (_needsBridgeAgreement)
                    Text(
                      'Bridge agreement: '
                      '${_parseBridgeAgreementId(_bridgeSignedAgreementIdController.text) ?? "—"}',
                    ),
                  const SizedBox(height: 16),
                  Text(
                    'Submit runs: PATCH /kyc → upload ID & PoA → '
                    '${_needsBridgeAgreement ? "POST /kyc/agreement → " : ""}'
                    'GET /kyc/readiness → POST /kyc/activate → '
                    '${_selectedCurrency.kycProviderLabel} start-* onboarding.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  if (_lastResponse != null) ...[
                    const SizedBox(height: 16),
                    _LastResponsePanel(value: _lastResponse!),
                  ],
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: BMoniButton.ghost(
                onPressed: _isBusy ? null : _kycGoBack,
                text: _kycPageIndex == 0 ? 'Cancel' : 'Back',
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: BMoniButton.primary(
                onPressed: _isBusy
                    ? null
                    : (_kycPageIndex >= _kycPageCount - 1
                          ? _submitKycWizard
                          : _kycGoNext),
                text: _kycPageIndex >= _kycPageCount - 1
                    ? 'Submit & start onboarding'
                    : 'Next',
                isLoading: _isBusy,
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
      ],
    );
  }

  List<({String label, int value})> _parseVolumeRanges(Object? raw) {
    if (raw is! List || raw.isEmpty) {
      return const [
        (label: '\$0–\$4,999', value: 4999),
        (label: '\$5,000–\$9,999', value: 9999),
        (label: '\$10,000+', value: 15000),
      ];
    }
    final out = <({String label, int value})>[];
    for (final item in raw) {
      if (item is Map<String, dynamic>) {
        final label = item['label'] as String? ?? '';
        final v = item['value'];
        final iv = v is int ? v : (v is num ? v.round() : null);
        if (iv != null) {
          out.add((label: label.isEmpty ? '$iv' : label, value: iv));
        }
      }
    }
    return out.isEmpty ? const [(label: '5000', value: 5000)] : out;
  }

  Widget _buildCreateAccountView() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _HeaderBlock(
          title: 'Create your account',
          description:
              'Configure the partner API, create a BMoni user, then choose the wallet currency to provision.',
        ),
        _SectionCard(
          title: 'API configuration',
          child: Column(
            children: [
              _TextInput(
                controller: _baseUrlController,
                label: 'Proxy API base URL',
                hintText: 'http://localhost:4001',
                keyboardType: TextInputType.url,
              ),
              const SizedBox(height: 12),
              _TextInput(
                controller: _apiKeyController,
                label: 'Partner API key',
                hintText: 'x-api-key value',
                obscureText: true,
              ),
            ],
          ),
        ),
        _SectionCard(
          title: 'User details',
          child: Column(
            children: [
              _TwoColumnFields(
                first: _TextInput(
                  controller: _firstNameController,
                  label: 'First name',
                  textCapitalization: TextCapitalization.words,
                ),
                second: _TextInput(
                  controller: _lastNameController,
                  label: 'Last name',
                  textCapitalization: TextCapitalization.words,
                ),
              ),
              const SizedBox(height: 12),
              _TextInput(
                controller: _emailController,
                label: 'Email',
                keyboardType: TextInputType.emailAddress,
              ),
              const SizedBox(height: 12),
              _TextInput(
                controller: _phoneController,
                label: 'Phone number',
                keyboardType: TextInputType.phone,
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: BMoniButton.primary(
                  onPressed: _createAccount,
                  text: 'Create account',
                  isLoading: _isBusy,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildUnlockView() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _HeaderBlock(
          title: 'Welcome back',
          description:
              'Enter the 6-digit PIN configured for this device wallet to return to the home page.',
        ),
        _SectionCard(
          title: 'PIN unlock',
          child: Column(
            children: [
              _TextInput(
                controller: _pinController,
                label: '6-digit PIN',
                obscureText: true,
                keyboardType: TextInputType.number,
                inputFormatters: [
                  FilteringTextInputFormatter.digitsOnly,
                  LengthLimitingTextInputFormatter(BmoniEmbeddedSdk.pinLength),
                ],
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: BMoniButton.primary(
                  onPressed: _unlockWithPin,
                  text: 'Unlock',
                  isLoading: _isBusy,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildCurrencyView() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _HeaderBlock(
          title: _addingAnotherWallet
              ? 'Add another wallet'
              : 'Choose wallet currency',
          description: _addingAnotherWallet
              ? 'Only currencies you do not already hold are selectable. '
                    'The API will reject a duplicate stablecoin wallet.'
              : 'The example provisions a local EVM owner key, signs an '
                    'owner-proof challenge, then creates a managed smart wallet.',
        ),
        if (_addingAnotherWallet && _walletReady(_smartWallet)) ...[
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: _cancelAddWalletFlow,
              icon: const Icon(Icons.arrow_back),
              label: const Text('Back to wallet home'),
            ),
          ),
          const SizedBox(height: 8),
        ],
        _SectionCard(
          title: 'Currency',
          child: Column(
            children: [
              for (final option in WalletCurrencyOption.values)
                _CurrencyOptionTile(
                  option: option,
                  isSelected: option == _selectedCurrency,
                  disabled: _ownedStablecoinCodes.contains(
                    option.smartWalletCurrency.toUpperCase(),
                  ),
                  footnote:
                      _ownedStablecoinCodes.contains(
                        option.smartWalletCurrency.toUpperCase(),
                      )
                      ? 'Already created for this account'
                      : null,
                  onTap: () => setState(() => _selectedCurrency = option),
                ),
            ],
          ),
        ),
        _SectionCard(
          title: 'Device PIN',
          child: Column(
            children: [
              _TextInput(
                controller: _pinController,
                label: 'Set or verify 6-digit PIN',
                obscureText: true,
                keyboardType: TextInputType.number,
                inputFormatters: [
                  FilteringTextInputFormatter.digitsOnly,
                  LengthLimitingTextInputFormatter(BmoniEmbeddedSdk.pinLength),
                ],
              ),
              const SizedBox(height: 12),
              if (_ownerAddress != null)
                _KeyValueRow(label: 'Owner address', value: _ownerAddress!),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: BMoniButton.primary(
                  onPressed:
                      _ownedStablecoinCodes.contains(
                        _selectedCurrency.smartWalletCurrency.toUpperCase(),
                      )
                      ? null
                      : _provisionSmartWallet,
                  text: 'Create smart wallet',
                  icon: Icons.account_balance_wallet_outlined,
                  isLoading: _isBusy,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _openIntegrations() async {
    final String userId;
    final String smartWalletId;
    try {
      userId = _requiredUserId;
      smartWalletId = _requiredSmartWallet.id;
    } on ExampleException catch (e) {
      setState(() => _error = e.message);
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => _IntegrationsPage(
          client: _client,
          userId: userId,
          smartWalletId: smartWalletId,
        ),
      ),
    );
  }

  Widget _buildWalletHomeView() {
    final walletCard = _walletCardModel;
    final smartWallet = _smartWallet;
    if (walletCard == null || !_walletReady(smartWallet)) {
      return _buildCurrencyView();
    }
    final w = smartWallet!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _HeaderBlock(
          title: 'Wallet home',
          description:
              'Top up: crypto (Bridge deposit) or bank (US VBA / regional '
              'deposit account). Withdraw: crypto or bank. More provider ramps '
              '(swap quote, EU SEPA, LATAM, payouts, payment) live under '
              'Explore integrations. Onboarding is checked first.',
        ),
        EmbeddedWalletCard(
          wallet: walletCard,
          colorSuffix: '04',
          isBalanceHidden: _isBalanceHidden,
          onToggleHideBalance: () {
            setState(() => _isBalanceHidden = !_isBalanceHidden);
          },
          onInfoTap: () {
            setState(() {
              _message =
                  'Smart account: ${w.smartAccountAddress ?? w.walletAddress ?? 'n/a'}';
            });
          },
        ),
        const SizedBox(height: 16),
        _WalletActionRow(
          onTopUp: _handleTopUp,
          onWithdraw: _handleWithdraw,
          onSwap: _handleSwap,
        ),
        const SizedBox(height: 16),
        _SectionCard(
          title: 'Explore integrations',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Swap quote, EU SEPA payout, LATAM cash, LATAM Mexico, US VBA, '
                'bank payouts and payment wallet-selection — each calls the '
                'proxy directly and dumps the raw response.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: _isBusy ? null : _openIntegrations,
                icon: const Icon(Icons.dashboard_customize_outlined),
                label: const Text('Open integrations'),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        _SectionCard(
          title: 'All wallets on this account',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'GET …/smart-wallets/account/wallets',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              Text(
                '${_accountWallets.length} wallet(s) from API '
                '(inactive / preparing wallets are omitted upstream).',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 12),
              if (_accountWallets.isEmpty)
                Text(
                  'List not loaded yet. Tap refresh (or unlock again) to sync.',
                  style: Theme.of(context).textTheme.bodyMedium,
                )
              else
                ..._accountWallets.map((wallet) {
                  final active = _smartWallet?.id == wallet.id;
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Material(
                      color: Theme.of(context).colorScheme.surface,
                      elevation: 0,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                        side: BorderSide(
                          color: active
                              ? Theme.of(context).colorScheme.primary
                              : Theme.of(context).colorScheme.outlineVariant,
                        ),
                      ),
                      child: ListTile(
                        title: Text(wallet.currency),
                        subtitle: Text(
                          '${wallet.id}'
                          '${wallet.status.isNotEmpty ? ' · ${wallet.status}' : ''}',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: active
                            ? Icon(
                                Icons.check_circle,
                                color: Theme.of(context).colorScheme.primary,
                              )
                            : TextButton(
                                onPressed: () => _selectActiveWallet(wallet),
                                child: const Text('Use'),
                              ),
                      ),
                    ),
                  );
                }),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: _isBusy ? null : _refreshWalletsAndBalancesUi,
                icon: const Icon(Icons.refresh),
                label: const Text('Refresh wallets & balances'),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: _isBusy ? null : _startAddWalletFlow,
                icon: const Icon(Icons.add),
                label: const Text('Add another wallet'),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: _isBusy ? null : _reloadActiveSmartWalletFromApi,
                icon: const Icon(Icons.cloud_download_outlined),
                label: const Text('Reload active wallet (GET by id)'),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        _SectionCard(
          title: 'Account balances',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'GET …/smart-wallets/account/balances',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              if (_accountBalancesData['smartAccountAddress'] != null) ...[
                const SizedBox(height: 8),
                _KeyValueRow(
                  label: 'Smart account',
                  value: '${_accountBalancesData['smartAccountAddress']}',
                ),
              ],
              const SizedBox(height: 12),
              Builder(
                builder: (context) {
                  final raw = _accountBalancesData['balances'];
                  if (raw is! List || raw.isEmpty) {
                    return Text(
                      'No balance rows yet. Tap refresh.',
                      style: Theme.of(context).textTheme.bodyMedium,
                    );
                  }
                  return Column(
                    children: raw.map((dynamic e) {
                      if (e is! Map) {
                        return const SizedBox.shrink();
                      }
                      final m = Map<String, dynamic>.from(e);
                      final cur = '${m['currency'] ?? ''}';
                      final bal = m['balance'];
                      final err = m['error'];
                      return ListTile(
                        dense: true,
                        title: Text(cur.isEmpty ? '—' : cur),
                        subtitle: Text(
                          err != null && '$err'.trim().isNotEmpty
                              ? '$err'
                              : '${bal ?? '—'}',
                        ),
                      );
                    }).toList(),
                  );
                },
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        _SectionCard(
          title: 'Wallet details',
          child: _SmartWalletSummary(wallet: w),
        ),
      ],
    );
  }
}

class ProxyApiClient {
  const ProxyApiClient({required this.baseUrl, required this.apiKey});

  final String baseUrl;
  final String apiKey;

  static Map<String, dynamic> bankAccountsRoot(Map<String, dynamic> json) {
    final d = json['data'];
    if (d is Map<String, dynamic> &&
        (d.containsKey('depositAccounts') ||
            d.containsKey('withdrawalAccounts'))) {
      return d;
    }
    return json;
  }

  static String? readBankAccountId(Map<String, dynamic> m) {
    final id = m['id'];
    if (id is String && id.isNotEmpty) {
      return id;
    }
    return null;
  }

  static String? readCreatedDepositAccountId(Map<String, dynamic> json) {
    final account = json['account'];
    if (account is Map) {
      final id = account['id'];
      if (id is String && id.isNotEmpty) {
        return id;
      }
    }
    return readBankAccountId(json);
  }

  static List<Map<String, dynamic>> extractUsaDeposits(
    Map<String, dynamic> root,
  ) {
    final r = bankAccountsRoot(root);
    final dep = r['depositAccounts'];
    if (dep is! Map<String, dynamic>) {
      return const [];
    }
    final list = dep['usaAccounts'];
    if (list is! List) {
      return const [];
    }
    return list
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
  }

  static List<Map<String, dynamic>> extractEuropeanDeposits(
    Map<String, dynamic> root,
  ) {
    final r = bankAccountsRoot(root);
    final dep = r['depositAccounts'];
    if (dep is! Map<String, dynamic>) {
      return const [];
    }
    final list = dep['europeanAccounts'];
    if (list is! List) {
      return const [];
    }
    return list
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
  }

  static List<Map<String, dynamic>> extractNigerianDeposits(
    Map<String, dynamic> root,
  ) {
    final r = bankAccountsRoot(root);
    final dep = r['depositAccounts'];
    if (dep is! Map<String, dynamic>) {
      return const [];
    }
    final out = <Map<String, dynamic>>[];
    void addList(Object? raw) {
      if (raw is! List) {
        return;
      }
      for (final e in raw) {
        if (e is Map) {
          out.add(Map<String, dynamic>.from(e));
        }
      }
    }

    addList(dep['nigerianAccounts']);
    addList(dep['activationAccounts']);
    return out;
  }

  static List<Map<String, dynamic>> extractUsaWithdrawals(
    Map<String, dynamic> root,
  ) {
    final r = bankAccountsRoot(root);
    final w = r['withdrawalAccounts'];
    if (w is! Map<String, dynamic>) {
      return const [];
    }
    final list = w['usaAccounts'];
    if (list is! List) {
      return const [];
    }
    return list
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
  }

  Future<ProxyUser> createUser(CreateUserRequest input) async {
    final json = await _request(
      method: 'POST',
      path: '/v1/users',
      body: input.toJson(),
    );
    return ProxyUser.fromJson(_readObject(json, 'user'));
  }

  Future<OwnerProofChallenge> createOwnerProofChallenge({
    required String userId,
    required String currency,
    required String userOwnerAddress,
  }) async {
    final json = await _request(
      method: 'POST',
      path: '/v1/users/$userId/smart-wallets/owner-proof-challenges',
      body: {'currency': currency, 'userOwnerAddress': userOwnerAddress},
    );
    return OwnerProofChallenge.fromJson(_unwrapData(json));
  }

  Future<SmartWallet> createManagedSmartWallet({
    required String userId,
    required String currency,
    required String userOwnerAddress,
    required String ownerProofChallengeId,
    required String ownerProofSignature,
  }) async {
    final json = await _request(
      method: 'POST',
      path: '/v1/users/$userId/smart-wallets/create-managed',
      body: {
        'currency': currency,
        'userOwnerAddress': userOwnerAddress,
        'ownerProofChallengeId': ownerProofChallengeId,
        'ownerProofSignature': ownerProofSignature,
      },
    );
    final data = _unwrapData(json);
    final Map<String, dynamic> walletMap = switch (data) {
      final m when m['smartWallet'] is Map<String, dynamic> =>
        Map<String, dynamic>.from(m['smartWallet']! as Map),
      final m when m['groupWallet'] is Map<String, dynamic> =>
        Map<String, dynamic>.from(m['groupWallet']! as Map),
      _ => data,
    };
    return SmartWallet.fromJson(walletMap);
  }

  /// Accepts either a flat [SmartWallet] JSON object or `{ "smartWallet": { … } }`.
  static SmartWallet smartWalletFromPayload(Map<String, dynamic> raw) {
    final nested = raw['smartWallet'];
    if (nested is Map<String, dynamic>) {
      return SmartWallet.fromJson(nested);
    }
    if (nested is Map) {
      return SmartWallet.fromJson(Map<String, dynamic>.from(nested));
    }
    return SmartWallet.fromJson(raw);
  }

  Future<List<SmartWallet>> listAccountSmartWallets(String userId) async {
    final json = await _request(
      method: 'GET',
      path: '/v1/users/$userId/smart-wallets/account/wallets',
    );
    final data = _unwrapData(json);
    // Upstream group-wallet uses `wallets`; proxy OpenAPI uses `smartWallets`.
    // Some gateways nest the dashboard under `value`.
    Map<String, dynamic> layer = data;
    var rawList = layer['smartWallets'] ?? layer['wallets'];
    if (rawList is! List) {
      final inner = layer['value'];
      if (inner is Map<String, dynamic>) {
        layer = inner;
        rawList = layer['smartWallets'] ?? layer['wallets'];
      }
    }
    if (rawList is! List) {
      return const [];
    }
    final out = <SmartWallet>[];
    for (final item in rawList) {
      if (item is Map<String, dynamic>) {
        final w = ProxyApiClient.smartWalletFromPayload(item);
        if (w.id.trim().isNotEmpty) {
          out.add(w);
        }
      } else if (item is Map) {
        final w = ProxyApiClient.smartWalletFromPayload(
          Map<String, dynamic>.from(item),
        );
        if (w.id.trim().isNotEmpty) {
          out.add(w);
        }
      }
    }
    return out;
  }

  Future<Map<String, dynamic>> listAccountBalances(String userId) async {
    final json = await _request(
      method: 'GET',
      path: '/v1/users/$userId/smart-wallets/account/balances',
    );
    return _unwrapData(json);
  }

  Future<SmartWallet> getSmartWallet({
    required String userId,
    required String smartWalletId,
  }) async {
    final json = await _request(
      method: 'GET',
      path: '/v1/users/$userId/smart-wallets/$smartWalletId',
    );
    final data = _unwrapData(json);
    final Map<String, dynamic> walletMap = switch (data) {
      final m when m['smartWallet'] is Map<String, dynamic> =>
        Map<String, dynamic>.from(m['smartWallet']! as Map),
      final m when m['groupWallet'] is Map<String, dynamic> =>
        Map<String, dynamic>.from(m['groupWallet']! as Map),
      _ => data,
    };
    return SmartWallet.fromJson(walletMap);
  }

  Future<Map<String, dynamic>> getOnboardingStatus(String userId) async {
    final json = await _request(
      method: 'GET',
      path: '/v1/users/$userId/onboarding/status',
    );
    return _unwrapData(json);
  }

  Future<Map<String, dynamic>> getKycOptions(String userId) async {
    final json = await _request(
      method: 'GET',
      path: '/v1/users/$userId/kyc/options',
    );
    return _unwrapData(json);
  }

  Future<Map<String, dynamic>> patchKyc({
    required String userId,
    required Map<String, dynamic> body,
  }) {
    return _request(method: 'PATCH', path: '/v1/users/$userId/kyc', body: body);
  }

  Future<Map<String, dynamic>> activateKyc({
    required String userId,
    String? sumsubLevelName,
  }) {
    final body = <String, dynamic>{};
    if (sumsubLevelName != null && sumsubLevelName.trim().isNotEmpty) {
      body['sumsubLevelName'] = sumsubLevelName.trim();
    }
    return _request(
      method: 'POST',
      path: '/v1/users/$userId/kyc/activate',
      body: body,
    );
  }

  Future<Map<String, dynamic>> getKycReadiness(String userId) {
    return _request(method: 'GET', path: '/v1/users/$userId/kyc/readiness');
  }

  Future<Map<String, dynamic>> getBridgeAgreementUrl(String userId) {
    return _request(
      method: 'GET',
      path: '/v1/users/$userId/kyc/agreement-url',
    );
  }

  Future<Map<String, dynamic>> storeBridgeAgreement({
    required String userId,
    required String signedAgreementId,
  }) {
    return _request(
      method: 'POST',
      path: '/v1/users/$userId/kyc/agreement',
      body: {'signedAgreementId': signedAgreementId.trim()},
    );
  }

  /// `GET /kyc/agreement-url` returns the flat `{ url }` shape.
  static String? readBridgeSigningUrl(Map<String, dynamic> json) {
    final url = json['url'];
    return (url is String && url.isNotEmpty) ? url : null;
  }

  Future<Map<String, dynamic>> uploadKycIdentificationDocument({
    required String userId,
    required List<http.MultipartFile> files,
    required String type,
    required String documentNumber,
    required String issuingCountry,
    String? expirationDate,
    String? issueDate,
  }) {
    return _sendMultipartJson(
      path: '/v1/users/$userId/kyc/documents/identification',
      files: files,
      fields: {
        'type': type,
        'documentNumber': documentNumber,
        'issuingCountry': issuingCountry,
        if (expirationDate != null && expirationDate.isNotEmpty)
          'expirationDate': expirationDate,
        if (issueDate != null && issueDate.isNotEmpty) 'issueDate': issueDate,
      },
    );
  }

  Future<Map<String, dynamic>> uploadKycProofOfAddress({
    required String userId,
    required List<http.MultipartFile> files,
    required String type,
  }) {
    return _sendMultipartJson(
      path: '/v1/users/$userId/kyc/documents/proof-of-address',
      files: files,
      fields: {'type': type},
    );
  }

  Future<Map<String, dynamic>> _sendMultipartJson({
    required String path,
    required List<http.MultipartFile> files,
    required Map<String, String> fields,
  }) async {
    if (baseUrl.isEmpty) {
      throw const ExampleException('Enter the proxy API base URL.');
    }
    if (apiKey.isEmpty) {
      throw const ExampleException('Enter a partner API key.');
    }
    final uri = Uri.parse('${_normalizedBaseUrl(baseUrl, path)}$path');
    final request = http.MultipartRequest('POST', uri);
    request.headers['x-api-key'] = apiKey;
    request.headers[HttpHeaders.acceptHeader] = 'application/json';
    for (final e in fields.entries) {
      request.fields[e.key] = e.value;
    }
    request.files.addAll(files);
    final streamed = await request.send();
    final response = await http.Response.fromStream(streamed);
    final decoded = _decodeResponse(response.body);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw ExampleException(_errorMessage(decoded, response.statusCode));
    }
    return decoded;
  }

  Future<List<Map<String, dynamic>>> getKycOccupations({
    required String userId,
    String? search,
  }) async {
    if (baseUrl.isEmpty) {
      throw const ExampleException('Enter the proxy API base URL.');
    }
    if (apiKey.isEmpty) {
      throw const ExampleException('Enter a partner API key.');
    }
    final qs = search != null && search.trim().isNotEmpty
        ? '?search=${Uri.encodeQueryComponent(search.trim())}'
        : '';
    final path = '/v1/users/$userId/kyc/occupations$qs';
    final uri = Uri.parse('${_normalizedBaseUrl(baseUrl, path)}$path');
    final headers = {
      HttpHeaders.acceptHeader: 'application/json',
      'x-api-key': apiKey,
    };
    final response = await http.get(uri, headers: headers);
    final decoded = response.body.isEmpty
        ? null
        : jsonDecode(response.body) as Object?;
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final message = decoded is Map<String, dynamic>
          ? _errorMessage(decoded, response.statusCode)
          : 'HTTP ${response.statusCode}';
      throw ExampleException(message);
    }
    if (decoded is List) {
      return decoded
          .map((e) => Map<String, dynamic>.from(e as Map<dynamic, dynamic>))
          .toList();
    }
    if (decoded is Map<String, dynamic>) {
      final data = decoded['data'];
      if (data is List) {
        return data
            .map((e) => Map<String, dynamic>.from(e as Map<dynamic, dynamic>))
            .toList();
      }
    }
    return const [];
  }

  Future<Map<String, dynamic>> startKyc({
    required String userId,
    required WalletCurrencyOption currency,
    required SmartWallet smartWallet,
    String? nigeriaBvn,
  }) {
    return _request(
      method: 'POST',
      path: switch (currency) {
        WalletCurrencyOption.usd => '/v1/users/$userId/onboarding/start-usa',
        WalletCurrencyOption.cad => '/v1/users/$userId/onboarding/start-canada',
        WalletCurrencyOption.eur =>
          '/v1/users/$userId/onboarding/start-monerium',
        WalletCurrencyOption.ngn =>
          '/v1/users/$userId/onboarding/start-nigeria',
      },
      body: _kycStartBody(currency, smartWallet, nigeriaBvn: nigeriaBvn),
    );
  }

  /// Crypto top-up. `POST /deposit/wallet` returns a one-time Bridge deposit
  /// address; any supported crypto sent to it is converted and credited to the
  /// smart wallet. Replaces the removed `smart-wallets/:id/onramp/crypto` route.
  Future<Map<String, dynamic>> depositToWallet({
    required String userId,
    required String smartWalletId,
    required String chain,
    required String currency,
  }) async {
    final json = await _request(
      method: 'POST',
      path: '/v1/users/$userId/deposit/wallet',
      body: {
        'smartWalletId': smartWalletId,
        'chain': chain,
        'currency': currency,
      },
    );
    return _unwrapData(json);
  }

  Future<Map<String, dynamic>> createCryptoOfframp({
    required String userId,
    required String smartWalletId,
    required String amount,
    required String destinationAddress,
    required String destinationChain,
    required String destinationCurrency,
  }) {
    return _request(
      method: 'POST',
      path: '/v1/users/$userId/smart-wallets/$smartWalletId/offramp/crypto',
      body: {
        'amount': amount,
        'destinationAddress': destinationAddress,
        'destinationChain': destinationChain,
        'destinationCurrency': destinationCurrency,
      },
    );
  }

  Future<Map<String, dynamic>> getBankAccounts(String userId) async {
    final json = await _request(
      method: 'GET',
      path: '/v1/users/$userId/bank-accounts',
    );
    return bankAccountsRoot(_unwrapData(json));
  }

  Future<Map<String, dynamic>> createDepositAccount({
    required String userId,
    required String region,
    required String smartWalletId,
    String ownershipModel = 'shared',
  }) async {
    final json = await _request(
      method: 'POST',
      path: '/v1/users/$userId/bank-accounts/deposit-accounts',
      body: {
        'region': region,
        'smartWalletId': smartWalletId,
        'ownershipModel': ownershipModel,
      },
    );
    return _unwrapData(json);
  }

  Future<Map<String, dynamic>> createBlockradarDepositAccount({
    required String userId,
    required String smartWalletId,
  }) async {
    final json = await _request(
      method: 'POST',
      path: '/v1/users/$userId/bank-accounts/deposit-accounts/blockradar',
      body: {'smartWalletId': smartWalletId},
    );
    return _unwrapData(json);
  }

  /// US virtual bank account (Graph Finance). Replaces the removed
  /// `smart-wallets/:id/onramp/vba/us` route with the dedicated `/us/vba/*`
  /// module: check readiness → provision → poll for account details.
  Future<Map<String, dynamic>> getUsVbaReadiness(String userId) async {
    final json = await _request(
      method: 'GET',
      path: '/v1/users/$userId/us/vba/readiness',
    );
    return _unwrapData(json);
  }

  Future<Map<String, dynamic>> provisionUsVba({
    required String userId,
    required String smartWalletId,
  }) async {
    final json = await _request(
      method: 'POST',
      path: '/v1/users/$userId/us/vba/provision',
      body: {'smartWalletId': smartWalletId},
    );
    return _unwrapData(json);
  }

  Future<Map<String, dynamic>> getUsVba(String userId) async {
    final json = await _request(
      method: 'GET',
      path: '/v1/users/$userId/us/vba',
    );
    return _unwrapData(json);
  }

  Future<Map<String, dynamic>> verifyNigerianAccount({
    required String userId,
    required String bankCode,
    required String accountNumber,
  }) async {
    final json = await _request(
      method: 'POST',
      path: '/v1/users/$userId/bank-accounts/verify-nigerian-account',
      body: {'bankCode': bankCode, 'accountNumber': accountNumber},
    );
    return _unwrapData(json);
  }

  Future<Map<String, dynamic>> getOrCreateNigerianWithdrawalAccount({
    required String userId,
    required Map<String, dynamic> body,
  }) async {
    final json = await _request(
      method: 'POST',
      path: '/v1/users/$userId/bank-accounts/withdrawal-accounts/nigeria',
      body: body,
    );
    return _unwrapData(json);
  }

  Future<Map<String, dynamic>> offrampNigeriaBank({
    required String userId,
    required String smartWalletId,
    required String bankAccountId,
    required String fromAmount,
  }) {
    return _request(
      method: 'POST',
      path: '/v1/users/$userId/smart-wallets/$smartWalletId/offramp/nigeria',
      body: {'bankAccountId': bankAccountId, 'fromAmount': fromAmount},
    );
  }

  Future<Map<String, dynamic>> offrampUsBankAccount({
    required String userId,
    required String smartWalletId,
    required String bankAccountId,
    required String amount,
  }) {
    return _request(
      method: 'POST',
      path:
          '/v1/users/$userId/smart-wallets/$smartWalletId/offramp/us-bank-account',
      body: {'bankAccountId': bankAccountId, 'amount': amount},
    );
  }

  Future<Map<String, dynamic>> convertCurrency({
    required String userId,
    required String amount,
    required String from,
    required String to,
  }) {
    return _request(
      method: 'POST',
      path: '/v1/users/$userId/exchange/convert',
      body: {'amount': amount, 'from': from, 'to': to},
    );
  }

  // ---------------------------------------------------------------------------
  // Exchange — swap quote (#63)
  // ---------------------------------------------------------------------------

  Future<Map<String, dynamic>> getExchangeRate({
    required String userId,
    required String from,
    required String to,
  }) {
    return _request(
      method: 'GET',
      path: '/v1/users/$userId/exchange/rate/$from/$to',
    );
  }

  /// Firm swap quote. [amountType] is `exactIn` or `exactOut`; the matching
  /// `amountIn`/`amountOut` numeric string is sent per the discriminated input.
  Future<Map<String, dynamic>> getSwapQuote({
    required String userId,
    required String fromCurrency,
    required String toCurrency,
    required String amountType,
    required String amount,
  }) {
    return _request(
      method: 'POST',
      path: '/v1/users/$userId/exchange/quote',
      body: {
        'swapAmount': {
          'type': amountType,
          if (amountType == 'exactIn') 'amountIn': amount,
          if (amountType == 'exactOut') 'amountOut': amount,
        },
        'fromCurrency': fromCurrency,
        'toCurrency': toCurrency,
      },
    );
  }

  // ---------------------------------------------------------------------------
  // EU — SEPA / Monerium ramp (#64)
  // ---------------------------------------------------------------------------

  Future<Map<String, dynamic>> completeEuKyc({
    required String userId,
    required String code,
    required String signature,
  }) {
    return _request(
      method: 'POST',
      path: '/v1/users/$userId/eu/kyc',
      body: {'code': code, 'signature': signature},
    );
  }

  /// Prepare a EUR SEPA payout. Returns `{ workflowId, messageToSign,
  /// signatureRequest? }`; sign `messageToSign` then call [completeEuOrder].
  Future<Map<String, dynamic>> prepareEuOrder({
    required String userId,
    required String smartWalletId,
    required String amount,
    required String iban,
    required String firstName,
    required String lastName,
    required String country,
    String? memo,
    String? supportingDocumentId,
  }) {
    return _request(
      method: 'POST',
      path: '/v1/users/$userId/eu/orders/prepare',
      body: {
        'smartWalletId': smartWalletId,
        'amount': amount,
        'counterpart': {
          'identifier': {'standard': 'iban', 'iban': iban},
          'details': {
            'firstName': firstName,
            'lastName': lastName,
            'country': country,
          },
        },
        if (memo != null && memo.isNotEmpty) 'memo': memo,
        if (supportingDocumentId != null && supportingDocumentId.isNotEmpty)
          'supportingDocumentId': supportingDocumentId,
      },
    );
  }

  Future<Map<String, dynamic>> completeEuOrder({
    required String userId,
    required String workflowId,
    required String signature,
  }) {
    return _request(
      method: 'POST',
      path: '/v1/users/$userId/eu/orders/complete',
      body: {'workflowId': workflowId, 'signature': signature},
    );
  }

  /// Upload a supporting document (PDF/JPEG, ≤5 MB) for orders ≥ EUR 15,000.
  /// [file] must be created with the field name `file`.
  Future<Map<String, dynamic>> uploadEuSupportingFile({
    required String userId,
    required http.MultipartFile file,
  }) {
    return _sendMultipartJson(
      path: '/v1/users/$userId/eu/files',
      files: [file],
      fields: const {},
    );
  }

  // ---------------------------------------------------------------------------
  // LATAM cash — Pago46 (#65)
  // ---------------------------------------------------------------------------

  Future<Map<String, dynamic>> createCashOrder({
    required String userId,
    required String kind, // 'fund' or 'send'
    required String smartWalletId,
    required String country,
    required String price,
    required String priceCurrency,
    required String description,
  }) {
    return _request(
      method: 'POST',
      path: '/v1/users/$userId/latam/cash/orders/$kind',
      body: {
        'smartWalletId': smartWalletId,
        'country': country,
        'price': price,
        'priceCurrency': priceCurrency,
        'description': description,
      },
    );
  }

  Future<Object?> listCashOrders({required String userId, String? type}) {
    final qs = (type != null && type.isNotEmpty) ? '?type=$type' : '';
    return _requestRaw(
      method: 'GET',
      path: '/v1/users/$userId/latam/cash/orders$qs',
    );
  }

  Future<Map<String, dynamic>> getCashOrder({
    required String userId,
    required String orderId,
  }) {
    return _request(
      method: 'GET',
      path: '/v1/users/$userId/latam/cash/orders/$orderId',
    );
  }

  // ---------------------------------------------------------------------------
  // LATAM Mexico — Etherfuse (#66)
  // ---------------------------------------------------------------------------

  Future<Map<String, dynamic>> activateMxKyc(String userId) {
    return _request(
      method: 'POST',
      path: '/v1/users/$userId/latam/mx/kyc/activate',
    );
  }

  Future<Map<String, dynamic>> getMxKycStatus(String userId) {
    return _request(
      method: 'GET',
      path: '/v1/users/$userId/latam/mx/kyc/status',
    );
  }

  /// [account] is the personal- or business-shaped CLABE registration object.
  Future<Map<String, dynamic>> registerMxBankAccount({
    required String userId,
    required Map<String, dynamic> account,
  }) {
    return _request(
      method: 'POST',
      path: '/v1/users/$userId/latam/mx/kyc/bank-account',
      body: {'account': account},
    );
  }

  /// MXN on/offramp quote. [type] is `onramp` or `offramp`; offramp quotes
  /// carry a `signatureRequest` to sign and submit via [submitSignature].
  Future<Map<String, dynamic>> createMxQuote({
    required String userId,
    required String type,
    required String sourceAmount,
    String? note,
  }) {
    return _request(
      method: 'POST',
      path: '/v1/users/$userId/latam/mx/quote',
      body: {
        'type': type,
        'sourceAmount': sourceAmount,
        if (note != null && note.isNotEmpty) 'note': note,
      },
    );
  }

  Future<Map<String, dynamic>> createMxOrder({
    required String userId,
    required String quoteId,
  }) {
    return _request(
      method: 'POST',
      path: '/v1/users/$userId/latam/mx/orders',
      body: {'quoteId': quoteId},
    );
  }

  Future<Map<String, dynamic>> getMxOrder({
    required String userId,
    required String orderId,
  }) {
    return _request(
      method: 'GET',
      path: '/v1/users/$userId/latam/mx/orders/$orderId',
    );
  }

  // ---------------------------------------------------------------------------
  // Bank payouts — Fin (#68)
  // ---------------------------------------------------------------------------

  Future<Object?> listPayoutCountries(String userId) {
    return _requestRaw(
      method: 'GET',
      path: '/v1/users/$userId/payouts/countries',
    );
  }

  Future<Object?> listPayoutBanks({
    required String userId,
    required String country,
  }) {
    return _requestRaw(
      method: 'GET',
      path: '/v1/users/$userId/payouts/banks?country=$country',
    );
  }

  Future<Object?> listPayoutBankBranches({
    required String userId,
    required String bankId,
  }) {
    return _requestRaw(
      method: 'GET',
      path: '/v1/users/$userId/payouts/bank-branches?bankId=$bankId',
    );
  }

  Future<Map<String, dynamic>> validatePayoutAccount({
    required String userId,
    required String country,
    required String currency,
    required String accountNumber,
    String? bankId,
    String? routingNumber,
  }) {
    return _request(
      method: 'POST',
      path: '/v1/users/$userId/payouts/validate-account',
      body: {
        'country': country,
        'currency': currency,
        'accountNumber': accountNumber,
        if (bankId != null && bankId.isNotEmpty) 'bankId': bankId,
        if (routingNumber != null && routingNumber.isNotEmpty)
          'routingNumber': routingNumber,
      },
    );
  }

  /// Create a bank payout (offramp). Returns `{ signatureRequest, quote? }`;
  /// sign `signatureRequest.hashToSign` and submit via [submitSignature].
  Future<Map<String, dynamic>> createPayout({
    required String userId,
    required String sourceSmartWalletId,
    required String amount,
    required String country,
    required String currency,
    required String bankId,
    required String accountNumber,
    required String accountHolderName,
    String? branchId,
    String? accountType,
    String? routingNumber,
    String? swiftCode,
    String? note,
  }) {
    return _request(
      method: 'POST',
      path: '/v1/users/$userId/payouts',
      body: {
        'sourceSmartWalletId': sourceSmartWalletId,
        'amount': amount,
        'country': country,
        'currency': currency,
        'bankDetails': {
          'bankId': bankId,
          'accountNumber': accountNumber,
          'accountHolderName': accountHolderName,
          if (branchId != null && branchId.isNotEmpty) 'branchId': branchId,
          if (accountType != null && accountType.isNotEmpty)
            'accountType': accountType,
          if (routingNumber != null && routingNumber.isNotEmpty)
            'routingNumber': routingNumber,
          if (swiftCode != null && swiftCode.isNotEmpty) 'swiftCode': swiftCode,
        },
        if (note != null && note.isNotEmpty) 'note': note,
      },
    );
  }

  // ---------------------------------------------------------------------------
  // Payment — funding wallet selection (#69)
  // ---------------------------------------------------------------------------

  Future<Map<String, dynamic>> selectPaymentWallet({
    required String userId,
    required String workflowId,
    required String smartWalletId,
  }) {
    return _request(
      method: 'POST',
      path: '/v1/users/$userId/payment/select-wallet',
      body: {'workflowId': workflowId, 'smartWalletId': smartWalletId},
    );
  }

  // ---------------------------------------------------------------------------
  // Shared — submit a signature for any pending workflow
  // ---------------------------------------------------------------------------

  /// Completes a `signatureRequest`/`messageToSign` workflow by submitting the
  /// signature. Used by payouts, payment, LATAM and other signed flows.
  Future<Map<String, dynamic>> submitSignature({
    required String userId,
    required String workflowId,
    required String signature,
  }) {
    return _request(
      method: 'POST',
      path: '/v1/users/$userId/wallets/submit-signature',
      body: {'workflowId': workflowId, 'signature': signature},
    );
  }

  /// Raw GET/POST for provider-shaped endpoints that may return a JSON array
  /// (payouts catalogs, LATAM order lists) rather than an object.
  Future<Object?> _requestRaw({
    required String method,
    required String path,
    Map<String, dynamic>? body,
  }) async {
    if (baseUrl.isEmpty) {
      throw const ExampleException('Enter the proxy API base URL.');
    }
    if (apiKey.isEmpty) {
      throw const ExampleException('Enter a partner API key.');
    }
    final uri = Uri.parse('${_normalizedBaseUrl(baseUrl, path)}$path');
    final headers = {
      HttpHeaders.acceptHeader: 'application/json',
      HttpHeaders.contentTypeHeader: 'application/json',
      'x-api-key': apiKey,
    };
    final response = switch (method) {
      'GET' => await http.get(uri, headers: headers),
      'POST' => await http.post(
        uri,
        headers: headers,
        body: jsonEncode(body ?? const {}),
      ),
      _ => throw ExampleException('Unsupported method: $method'),
    };
    final decoded = response.body.isEmpty
        ? null
        : jsonDecode(response.body) as Object?;
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final message = decoded is Map<String, dynamic>
          ? _errorMessage(decoded, response.statusCode)
          : 'HTTP ${response.statusCode}';
      throw ExampleException(message);
    }
    return decoded;
  }

  /// Bodies match embedded proxy DTOs (`StartUsaOnboardingInput`, etc.).
  Map<String, dynamic> _kycStartBody(
    WalletCurrencyOption currency,
    SmartWallet wallet, {
    String? nigeriaBvn,
  }) {
    final address =
        wallet.smartAccountAddress ??
        wallet.safeAddress ??
        wallet.walletAddress;
    if (address == null || address.trim().isEmpty) {
      throw const ExampleException(
        'Smart wallet has no on-chain address; cannot start KYC.',
      );
    }
    const walletIndex = 0;
    return switch (currency) {
      WalletCurrencyOption.usd => {
        'usdWalletAddress': address,
        'usdWalletIndex': walletIndex,
      },
      WalletCurrencyOption.cad => {
        'cadWalletAddress': address,
        'cadWalletIndex': walletIndex,
      },
      WalletCurrencyOption.eur => {
        'eurWalletAddress': address,
        'eurWalletIndex': walletIndex,
      },
      WalletCurrencyOption.ngn => {
        'bvn': () {
          final b = nigeriaBvn?.trim() ?? '';
          if (b.length != 11) {
            throw const ExampleException(
              'Nigeria onboarding requires an 11-digit BVN in the KYC step.',
            );
          }
          return b;
        }(),
        'ngnWalletAddress': address,
        'ngnWalletIndex': walletIndex,
      },
    };
  }

  /// Proxy routes already include `/v1/...`. If [baseUrl] ends with `/v1`
  /// (easy to copy from docs), concatenation would produce `/v1/v1/...` and 404.
  static String _normalizedBaseUrl(String raw, String path) {
    var base = raw.trim().replaceFirst(RegExp(r'/$'), '');
    if (base.isEmpty) {
      return base;
    }
    if (path.startsWith('/v1/') && RegExp(r'/v1$').hasMatch(base)) {
      base = base.replaceFirst(RegExp(r'/v1$'), '');
      base = base.replaceFirst(RegExp(r'/$'), '');
    }
    return base;
  }

  Future<Map<String, dynamic>> _request({
    required String method,
    required String path,
    Map<String, dynamic>? body,
  }) async {
    if (baseUrl.isEmpty) {
      throw const ExampleException('Enter the proxy API base URL.');
    }
    if (apiKey.isEmpty) {
      throw const ExampleException('Enter a partner API key.');
    }

    final uri = Uri.parse('${_normalizedBaseUrl(baseUrl, path)}$path');
    final headers = {
      HttpHeaders.acceptHeader: 'application/json',
      HttpHeaders.contentTypeHeader: 'application/json',
      'x-api-key': apiKey,
    };

    final response = switch (method) {
      'GET' => await http.get(uri, headers: headers),
      'POST' => await http.post(
        uri,
        headers: headers,
        body: jsonEncode(body ?? const {}),
      ),
      'PATCH' => await http.patch(
        uri,
        headers: headers,
        body: jsonEncode(body ?? const {}),
      ),
      _ => throw ExampleException('Unsupported method: $method'),
    };

    final decoded = _decodeResponse(response.body);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw ExampleException(_errorMessage(decoded, response.statusCode));
    }
    return decoded;
  }

  Map<String, dynamic> _decodeResponse(String body) {
    if (body.isEmpty) {
      return const {};
    }
    final decoded = jsonDecode(body);
    if (decoded is Map<String, dynamic>) {
      return decoded;
    }
    throw const ExampleException('API returned a non-object JSON response.');
  }

  Map<String, dynamic> _unwrapData(Map<String, dynamic> json) {
    final data = json['data'];
    if (data is Map<String, dynamic>) {
      return data;
    }
    return json;
  }

  Map<String, dynamic> _readObject(Map<String, dynamic> json, String key) {
    final value = json[key];
    if (value is Map<String, dynamic>) {
      return value;
    }
    throw ExampleException('Expected "$key" object in API response.');
  }

  String _errorMessage(Map<String, dynamic> json, int statusCode) {
    final message = json['message'] ?? json['error'] ?? json['detail'];
    if (message is List) {
      return 'HTTP $statusCode: ${message.join(', ')}';
    }
    if (message is String && message.isNotEmpty) {
      return 'HTTP $statusCode: $message';
    }
    return 'HTTP $statusCode: ${jsonEncode(json)}';
  }
}

class CreateUserRequest {
  const CreateUserRequest({
    required this.firstName,
    required this.lastName,
    required this.email,
    required this.phoneNumber,
  });

  final String firstName;
  final String lastName;
  final String email;
  final String phoneNumber;

  Map<String, dynamic> toJson() => {
    'employeeId': 'EMP-${DateTime.now().millisecondsSinceEpoch}',
    'identityId': 'example-${DateTime.now().microsecondsSinceEpoch}',
    'firstName': firstName,
    'lastName': lastName,
    'email': email,
    'phoneNumber': phoneNumber,
    'employerName': 'BKey Example Co',
    'occupation': 'Mobile Engineer',
    'monthlySalary': '450000.00',
    'addressStreet': '15 Admiralty Way',
    'addressCity': 'Lagos',
    'addressState': 'Lagos',
    'addressCountry': 'Nigeria',
    'addressPostalCode': '101241',
  };
}

class ProxyUser {
  const ProxyUser({
    required this.id,
    required this.company,
    required this.bmoniUserId,
    required this.firstName,
    required this.email,
    required this.phoneNumber,
    this.lastName,
    this.employeeId,
    this.identityId,
    this.employerName,
    this.occupation,
  });

  final String id;
  final String company;
  final String bmoniUserId;
  final String firstName;
  final String? lastName;
  final String email;
  final String phoneNumber;
  final String? employeeId;
  final String? identityId;
  final String? employerName;
  final String? occupation;

  factory ProxyUser.fromJson(Map<String, dynamic> json) => ProxyUser(
    id: json['id'] as String? ?? '',
    company: json['company'] as String? ?? '',
    bmoniUserId: json['bmoniUserId'] as String? ?? '',
    firstName: json['firstName'] as String? ?? '',
    lastName: json['lastName'] as String?,
    email: json['email'] as String? ?? '',
    phoneNumber: json['phoneNumber'] as String? ?? '',
    employeeId: json['employeeId'] as String?,
    identityId: json['identityId'] as String?,
    employerName: json['employerName'] as String?,
    occupation: json['occupation'] as String?,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'company': company,
    'employeeId': employeeId,
    'identityId': identityId,
    'bmoniUserId': bmoniUserId,
    'firstName': firstName,
    'lastName': lastName,
    'email': email,
    'phoneNumber': phoneNumber,
    'employerName': employerName,
    'occupation': occupation,
  };
}

class OwnerProofChallenge {
  const OwnerProofChallenge({
    required this.challengeId,
    required this.groupId,
    required this.message,
    required this.expiresAt,
  });

  final String challengeId;
  final String groupId;
  final String message;
  final String expiresAt;

  factory OwnerProofChallenge.fromJson(Map<String, dynamic> json) {
    return OwnerProofChallenge(
      challengeId: json['challengeId'] as String? ?? '',
      groupId: json['groupId'] as String? ?? '',
      message: json['message'] as String? ?? '',
      expiresAt: json['expiresAt'] as String? ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
    'challengeId': challengeId,
    'groupId': groupId,
    'message': message,
    'expiresAt': expiresAt,
  };
}

class SmartWallet {
  const SmartWallet({
    required this.id,
    required this.currency,
    required this.status,
    this.smartAccountAddress,
    this.safeAddress,
    this.walletAddress,
    this.smartWalletId,
    this.threshold,
    this.approvalMode,
    this.createdAt,
  });

  final String id;
  final String currency;
  final String status;
  final String? smartAccountAddress;
  final String? safeAddress;

  /// Present on some upstream payloads as the deployed account address.
  final String? walletAddress;
  final String? smartWalletId;
  final int? threshold;
  final String? approvalMode;
  final String? createdAt;

  factory SmartWallet.fromJson(Map<String, dynamic> json) {
    final id =
        json['id'] as String? ??
        json['smartWalletId'] as String? ??
        json['walletId'] as String? ??
        json['groupWalletId'] as String? ??
        '';
    return SmartWallet(
      id: id,
      currency: json['currency'] as String? ?? '',
      status: json['status'] as String? ?? '',
      smartAccountAddress: json['smartAccountAddress'] as String?,
      safeAddress: json['safeAddress'] as String?,
      walletAddress: json['walletAddress'] as String?,
      smartWalletId: json['smartWalletId'] as String?,
      threshold: json['threshold'] as int?,
      approvalMode: json['approvalMode'] as String?,
      createdAt: json['createdAt'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'currency': currency,
    'status': status,
    'smartAccountAddress': smartAccountAddress,
    'safeAddress': safeAddress,
    'walletAddress': walletAddress,
    'smartWalletId': smartWalletId,
    'threshold': threshold,
    'approvalMode': approvalMode,
    'createdAt': createdAt,
  };
}

class _NigeriaBankWithdrawalDialog extends StatefulWidget {
  const _NigeriaBankWithdrawalDialog({
    required this.client,
    required this.userId,
    required this.smartWalletId,
  });

  final ProxyApiClient client;
  final String userId;
  final String smartWalletId;

  @override
  State<_NigeriaBankWithdrawalDialog> createState() =>
      _NigeriaBankWithdrawalDialogState();
}

class _NigeriaBankWithdrawalDialogState
    extends State<_NigeriaBankWithdrawalDialog> {
  final TextEditingController _accountNumber = TextEditingController();
  final TextEditingController _bankCode = TextEditingController();
  final TextEditingController _bankName = TextEditingController();
  final TextEditingController _holder = TextEditingController();
  final TextEditingController _amount = TextEditingController(text: '100.00');
  String? _verifiedName;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _accountNumber.dispose();
    _bankCode.dispose();
    _bankName.dispose();
    _holder.dispose();
    _amount.dispose();
    super.dispose();
  }

  Future<void> _verify() async {
    final acct = _accountNumber.text.trim();
    final code = _bankCode.text.trim();
    if (acct.length != 10 || code.isEmpty) {
      setState(() => _error = 'Enter a 10-digit account number and bank code.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final v = await widget.client.verifyNigerianAccount(
        userId: widget.userId,
        bankCode: code,
        accountNumber: acct,
      );
      if (!mounted) {
        return;
      }
      final name = v['accountName'] ?? v['accountHolderName'];
      setState(() {
        _verifiedName = name is String && name.trim().isNotEmpty
            ? name.trim()
            : 'Verified (check API response)';
      });
    } catch (e) {
      if (mounted) {
        setState(() => _error = e.toString());
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final account = await widget.client.getOrCreateNigerianWithdrawalAccount(
        userId: widget.userId,
        body: {
          'accountNumber': _accountNumber.text.trim(),
          'bankCode': _bankCode.text.trim(),
          'bankName': _bankName.text.trim(),
          'accountHolderName': _holder.text.trim(),
        },
      );
      final bankAccountId = ProxyApiClient.readBankAccountId(account);
      if (bankAccountId == null || bankAccountId.isEmpty) {
        throw const ExampleException('Missing payout account id from API.');
      }
      final proposal = await widget.client.offrampNigeriaBank(
        userId: widget.userId,
        smartWalletId: widget.smartWalletId,
        bankAccountId: bankAccountId,
        fromAmount: _amount.text.trim(),
      );
      if (!mounted) {
        return;
      }
      Navigator.pop(context, proposal);
    } catch (e) {
      if (mounted) {
        setState(() => _error = e.toString());
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Withdraw to Nigerian bank'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _accountNumber,
              decoration: const InputDecoration(
                labelText: 'Account number (10 digits)',
              ),
              keyboardType: TextInputType.number,
            ),
            TextField(
              controller: _bankCode,
              decoration: const InputDecoration(labelText: 'Bank code (CBN)'),
            ),
            TextField(
              controller: _bankName,
              decoration: const InputDecoration(labelText: 'Bank name'),
            ),
            TextField(
              controller: _holder,
              decoration: const InputDecoration(
                labelText: 'Account holder name',
              ),
            ),
            TextField(
              controller: _amount,
              decoration: const InputDecoration(labelText: 'Amount to offramp'),
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
            ),
            if (_verifiedName != null) ...[
              const SizedBox(height: 8),
              Text('Verified name: $_verifiedName'),
            ],
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: _busy ? null : _verify,
          child: const Text('Verify'),
        ),
        FilledButton(
          onPressed: _busy ? null : _submit,
          child: const Text('Save payout & offramp'),
        ),
      ],
    );
  }
}

/// Demonstrates the regional / provider integrations that are not part of the
/// core onboarding + top-up + withdraw + swap home flow: swap quote (#63),
/// EU SEPA (#64), LATAM cash (#65), LATAM Mexico (#66), US VBA (#67),
/// bank payouts (#68) and payment wallet-selection (#69).
///
/// Each action calls the proxy directly and dumps the raw JSON response.
/// Flows that return a `signatureRequest` (or `messageToSign`) expose a
/// "Sign & submit" button that signs `hashToSign` with
/// [BmoniEmbeddedSdk.signTransactionHash] and completes via the matching
/// endpoint (`eu/orders/complete` for EU, `wallets/submit-signature` otherwise).
class _IntegrationsPage extends StatefulWidget {
  const _IntegrationsPage({
    required this.client,
    required this.userId,
    required this.smartWalletId,
  });

  final ProxyApiClient client;
  final String userId;
  final String smartWalletId;

  @override
  State<_IntegrationsPage> createState() => _IntegrationsPageState();
}

class _IntegrationsPageState extends State<_IntegrationsPage> {
  bool _busy = false;
  String? _output;
  String? _error;

  // Pending signable workflow (last signed flow wins — sufficient for a demo).
  String? _pendingWorkflowId;
  String? _pendingHash;
  Future<Map<String, dynamic>> Function(String signature)? _pendingComplete;
  String? _pendingLabel;

  // Swap quote (#63)
  final _swapFrom = TextEditingController(text: 'USDB');
  final _swapTo = TextEditingController(text: 'cNGN');
  final _swapAmount = TextEditingController(text: '100');

  // EU SEPA (#64)
  final _euAmount = TextEditingController(text: '20.00');
  final _euIban = TextEditingController();
  final _euFirstName = TextEditingController();
  final _euLastName = TextEditingController();
  final _euCountry = TextEditingController(text: 'DE');
  final _euMemo = TextEditingController();
  final _euKycCode = TextEditingController();
  final _euKycSignature = TextEditingController();

  // LATAM cash (#65)
  final _cashCountry = TextEditingController(text: 'MX');
  final _cashPrice = TextEditingController(text: '1000');
  final _cashCurrency = TextEditingController(text: 'MXN');
  final _cashDescription = TextEditingController(text: 'Example cash order');
  final _cashOrderId = TextEditingController();

  // LATAM Mexico (#66)
  final _mxType = TextEditingController(text: 'onramp');
  final _mxAmount = TextEditingController(text: '500');
  final _mxQuoteId = TextEditingController();
  final _mxOrderId = TextEditingController();

  // Payouts (#68)
  final _poCountry = TextEditingController(text: 'NGA');
  final _poCurrency = TextEditingController(text: 'NGN');
  final _poBankId = TextEditingController();
  final _poAccountNumber = TextEditingController();
  final _poAccountHolder = TextEditingController();
  final _poAmount = TextEditingController(text: '1000');

  // Payment (#69)
  final _payWorkflowId = TextEditingController();

  @override
  void dispose() {
    for (final c in [
      _swapFrom,
      _swapTo,
      _swapAmount,
      _euAmount,
      _euIban,
      _euFirstName,
      _euLastName,
      _euCountry,
      _euMemo,
      _euKycCode,
      _euKycSignature,
      _cashCountry,
      _cashPrice,
      _cashCurrency,
      _cashDescription,
      _cashOrderId,
      _mxType,
      _mxAmount,
      _mxQuoteId,
      _mxOrderId,
      _poCountry,
      _poCurrency,
      _poBankId,
      _poAccountNumber,
      _poAccountHolder,
      _poAmount,
      _payWorkflowId,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  String get _userId => widget.userId;
  String get _walletId => widget.smartWalletId;

  Future<void> _run(Future<Object?> Function() task) async {
    if (_busy) {
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await task();
      if (!mounted) {
        return;
      }
      setState(() {
        _output = result == null
            ? '(no response body)'
            : const JsonEncoder.withIndent('  ').convert(result);
      });
    } on ExampleException catch (e) {
      if (mounted) {
        setState(() => _error = e.message);
      }
    } catch (e) {
      if (mounted) {
        setState(() => _error = e.toString());
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  /// Records a `signatureRequest` / `messageToSign` from [json] so the user can
  /// sign and complete it. [complete] submits the produced signature.
  void _capturePending({
    required Map<String, dynamic> json,
    required String label,
    required Future<Map<String, dynamic>> Function(String signature) complete,
  }) {
    String? workflowId;
    String? hash;
    final sr = json['signatureRequest'];
    if (sr is Map) {
      workflowId = sr['workflowId']?.toString();
      hash = sr['hashToSign']?.toString();
    }
    workflowId ??= json['workflowId']?.toString();
    hash ??= json['messageToSign']?.toString();
    setState(() {
      _pendingWorkflowId = workflowId;
      _pendingHash = hash;
      _pendingComplete = complete;
      _pendingLabel = (workflowId != null && hash != null) ? label : null;
    });
  }

  Future<void> _signAndSubmit() async {
    final hash = _pendingHash;
    final complete = _pendingComplete;
    if (hash == null || complete == null) {
      return;
    }
    final pin = await _promptPin();
    if (pin == null) {
      return;
    }
    await _run(() async {
      final signature = await BmoniEmbeddedSdk.signTransactionHash(
        hash,
        pin: pin,
      );
      final result = await complete(signature);
      setState(() {
        _pendingWorkflowId = null;
        _pendingHash = null;
        _pendingComplete = null;
        _pendingLabel = null;
      });
      return result;
    });
  }

  Future<String?> _promptPin() {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Enter wallet PIN'),
        content: TextField(
          controller: controller,
          obscureText: true,
          keyboardType: TextInputType.number,
          autofocus: true,
          decoration: const InputDecoration(labelText: '6-digit PIN'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('Sign'),
          ),
        ],
      ),
    ).whenComplete(controller.dispose);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Integrations')),
      body: AbsorbPointer(
        absorbing: _busy,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(
              'Active wallet: $_walletId',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            if (_pendingLabel != null)
              _SectionCard(
                title: 'Pending signature: $_pendingLabel',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      'workflowId: $_pendingWorkflowId',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const SizedBox(height: 8),
                    FilledButton.icon(
                      onPressed: _busy ? null : _signAndSubmit,
                      icon: const Icon(Icons.draw_outlined),
                      label: const Text('Sign hashToSign & submit'),
                    ),
                  ],
                ),
              ),
            _buildSwapSection(),
            _buildUsVbaSection(),
            _buildEuSection(),
            _buildLatamCashSection(),
            _buildLatamMxSection(),
            _buildPayoutsSection(),
            _buildPaymentSection(),
            if (_error != null)
              _SectionCard(
                title: 'Error',
                child: Text(
                  _error!,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.error,
                  ),
                ),
              ),
            if (_output != null) _LastResponsePanel(value: _output!),
            if (_busy)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Center(child: CircularProgressIndicator.adaptive()),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildSwapSection() {
    return _SectionCard(
      title: 'Swap quote (#63)',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _TwoColumnFields(
            first: _TextInput(controller: _swapFrom, label: 'From currency'),
            second: _TextInput(controller: _swapTo, label: 'To currency'),
          ),
          const SizedBox(height: 12),
          _TextInput(
            controller: _swapAmount,
            label: 'Amount in (exactIn)',
            keyboardType: TextInputType.number,
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton(
                onPressed: _busy
                    ? null
                    : () => _run(
                        () => widget.client.getExchangeRate(
                          userId: _userId,
                          from: _swapFrom.text.trim(),
                          to: _swapTo.text.trim(),
                        ),
                      ),
                child: const Text('GET rate'),
              ),
              FilledButton(
                onPressed: _busy
                    ? null
                    : () => _run(
                        () => widget.client.getSwapQuote(
                          userId: _userId,
                          fromCurrency: _swapFrom.text.trim(),
                          toCurrency: _swapTo.text.trim(),
                          amountType: 'exactIn',
                          amount: _swapAmount.text.trim(),
                        ),
                      ),
                child: const Text('POST quote'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildUsVbaSection() {
    return _SectionCard(
      title: 'US virtual bank account (#67)',
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          OutlinedButton(
            onPressed: _busy
                ? null
                : () =>
                      _run(() => widget.client.getUsVbaReadiness(_userId)),
            child: const Text('Readiness'),
          ),
          FilledButton(
            onPressed: _busy
                ? null
                : () => _run(
                    () => widget.client.provisionUsVba(
                      userId: _userId,
                      smartWalletId: _walletId,
                    ),
                  ),
            child: const Text('Provision'),
          ),
          OutlinedButton(
            onPressed: _busy
                ? null
                : () => _run(() => widget.client.getUsVba(_userId)),
            child: const Text('GET vba'),
          ),
        ],
      ),
    );
  }

  Widget _buildEuSection() {
    return _SectionCard(
      title: 'EU SEPA / Monerium (#64)',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Complete EU KYC with the Monerium authorization code + signature, '
            'then prepare a SEPA payout and sign it.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          _TextInput(controller: _euKycCode, label: 'Monerium auth code'),
          const SizedBox(height: 12),
          _TextInput(controller: _euKycSignature, label: 'KYC signature'),
          const SizedBox(height: 8),
          OutlinedButton(
            onPressed: _busy
                ? null
                : () => _run(
                    () => widget.client.completeEuKyc(
                      userId: _userId,
                      code: _euKycCode.text.trim(),
                      signature: _euKycSignature.text.trim(),
                    ),
                  ),
            child: const Text('POST eu/kyc'),
          ),
          const Divider(height: 24),
          _TextInput(
            controller: _euAmount,
            label: 'Amount (EUR)',
            keyboardType: TextInputType.number,
          ),
          const SizedBox(height: 12),
          _TextInput(controller: _euIban, label: 'Beneficiary IBAN'),
          const SizedBox(height: 12),
          _TwoColumnFields(
            first: _TextInput(
              controller: _euFirstName,
              label: 'Beneficiary first name',
            ),
            second: _TextInput(
              controller: _euLastName,
              label: 'Beneficiary last name',
            ),
          ),
          const SizedBox(height: 12),
          _TwoColumnFields(
            first: _TextInput(
              controller: _euCountry,
              label: 'Country (ISO alpha-2)',
            ),
            second: _TextInput(
              controller: _euMemo,
              label: 'Memo (5–140, optional)',
            ),
          ),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: _busy
                ? null
                : () => _run(() async {
                    final res = await widget.client.prepareEuOrder(
                      userId: _userId,
                      smartWalletId: _walletId,
                      amount: _euAmount.text.trim(),
                      iban: _euIban.text.trim(),
                      firstName: _euFirstName.text.trim(),
                      lastName: _euLastName.text.trim(),
                      country: _euCountry.text.trim(),
                      memo: _euMemo.text.trim().isEmpty
                          ? null
                          : _euMemo.text.trim(),
                    );
                    final workflowId = res['workflowId']?.toString();
                    _capturePending(
                      json: res,
                      label: 'EU SEPA payout',
                      complete: (signature) => widget.client.completeEuOrder(
                        userId: _userId,
                        workflowId: workflowId ?? '',
                        signature: signature,
                      ),
                    );
                    return res;
                  }),
            child: const Text('POST eu/orders/prepare'),
          ),
        ],
      ),
    );
  }

  Widget _buildLatamCashSection() {
    return _SectionCard(
      title: 'LATAM cash — Pago46 (#65)',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _TwoColumnFields(
            first: _TextInput(
              controller: _cashCountry,
              label: 'Country (ISO alpha-2)',
            ),
            second: _TextInput(
              controller: _cashCurrency,
              label: 'Local currency',
            ),
          ),
          const SizedBox(height: 12),
          _TextInput(
            controller: _cashPrice,
            label: 'Price (local)',
            keyboardType: TextInputType.number,
          ),
          const SizedBox(height: 12),
          _TextInput(controller: _cashDescription, label: 'Description'),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton(
                onPressed: _busy
                    ? null
                    : () => _run(
                        () => widget.client.createCashOrder(
                          userId: _userId,
                          kind: 'fund',
                          smartWalletId: _walletId,
                          country: _cashCountry.text.trim(),
                          price: _cashPrice.text.trim(),
                          priceCurrency: _cashCurrency.text.trim(),
                          description: _cashDescription.text.trim(),
                        ),
                      ),
                child: const Text('Fund order'),
              ),
              FilledButton(
                onPressed: _busy
                    ? null
                    : () => _run(() async {
                        final res = await widget.client.createCashOrder(
                          userId: _userId,
                          kind: 'send',
                          smartWalletId: _walletId,
                          country: _cashCountry.text.trim(),
                          price: _cashPrice.text.trim(),
                          priceCurrency: _cashCurrency.text.trim(),
                          description: _cashDescription.text.trim(),
                        );
                        _capturePending(
                          json: res,
                          label: 'LATAM cash send',
                          complete: (signature) => widget.client.submitSignature(
                            userId: _userId,
                            workflowId:
                                (res['signatureRequest']
                                        as Map?)?['workflowId']
                                    ?.toString() ??
                                '',
                            signature: signature,
                          ),
                        );
                        return res;
                      }),
                child: const Text('Send order'),
              ),
              OutlinedButton(
                onPressed: _busy
                    ? null
                    : () => _run(
                        () => widget.client.listCashOrders(userId: _userId),
                      ),
                child: const Text('List orders'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _TextInput(controller: _cashOrderId, label: 'Order id (GET one)'),
          const SizedBox(height: 8),
          OutlinedButton(
            onPressed: _busy
                ? null
                : () => _run(
                    () => widget.client.getCashOrder(
                      userId: _userId,
                      orderId: _cashOrderId.text.trim(),
                    ),
                  ),
            child: const Text('GET order'),
          ),
        ],
      ),
    );
  }

  Widget _buildLatamMxSection() {
    return _SectionCard(
      title: 'LATAM Mexico — Etherfuse (#66)',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton(
                onPressed: _busy
                    ? null
                    : () => _run(() => widget.client.activateMxKyc(_userId)),
                child: const Text('Activate KYC'),
              ),
              OutlinedButton(
                onPressed: _busy
                    ? null
                    : () => _run(() => widget.client.getMxKycStatus(_userId)),
                child: const Text('KYC status'),
              ),
            ],
          ),
          const Divider(height: 24),
          _TwoColumnFields(
            first: _TextInput(
              controller: _mxType,
              label: 'Type (onramp/offramp)',
            ),
            second: _TextInput(
              controller: _mxAmount,
              label: 'Source amount',
              keyboardType: TextInputType.number,
            ),
          ),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: _busy
                ? null
                : () => _run(() async {
                    final res = await widget.client.createMxQuote(
                      userId: _userId,
                      type: _mxType.text.trim(),
                      sourceAmount: _mxAmount.text.trim(),
                    );
                    final quoteId = res['quoteId']?.toString();
                    if (quoteId != null) {
                      _mxQuoteId.text = quoteId;
                    }
                    // Offramp quotes carry a signatureRequest to fund the swap.
                    if (res['signatureRequest'] is Map) {
                      _capturePending(
                        json: res,
                        label: 'MX offramp funding',
                        complete: (signature) => widget.client.submitSignature(
                          userId: _userId,
                          workflowId:
                              (res['signatureRequest'] as Map)['workflowId']
                                  ?.toString() ??
                              '',
                          signature: signature,
                        ),
                      );
                    }
                    return res;
                  }),
            child: const Text('POST quote'),
          ),
          const SizedBox(height: 12),
          _TextInput(controller: _mxQuoteId, label: 'Quote id'),
          const SizedBox(height: 8),
          FilledButton(
            onPressed: _busy
                ? null
                : () => _run(() async {
                    final res = await widget.client.createMxOrder(
                      userId: _userId,
                      quoteId: _mxQuoteId.text.trim(),
                    );
                    final orderId = res['orderId']?.toString();
                    if (orderId != null) {
                      _mxOrderId.text = orderId;
                    }
                    return res;
                  }),
            child: const Text('POST order'),
          ),
          const SizedBox(height: 12),
          _TextInput(controller: _mxOrderId, label: 'Order id (GET one)'),
          const SizedBox(height: 8),
          OutlinedButton(
            onPressed: _busy
                ? null
                : () => _run(
                    () => widget.client.getMxOrder(
                      userId: _userId,
                      orderId: _mxOrderId.text.trim(),
                    ),
                  ),
            child: const Text('GET order'),
          ),
        ],
      ),
    );
  }

  Widget _buildPayoutsSection() {
    return _SectionCard(
      title: 'Bank payouts — Fin (#68)',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _TwoColumnFields(
            first: _TextInput(
              controller: _poCountry,
              label: 'Country (ISO alpha-3)',
            ),
            second: _TextInput(controller: _poCurrency, label: 'Currency'),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton(
                onPressed: _busy
                    ? null
                    : () => _run(
                        () => widget.client.listPayoutCountries(_userId),
                      ),
                child: const Text('Countries'),
              ),
              OutlinedButton(
                onPressed: _busy
                    ? null
                    : () => _run(
                        () => widget.client.listPayoutBanks(
                          userId: _userId,
                          country: _poCountry.text.trim(),
                        ),
                      ),
                child: const Text('Banks'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _TextInput(controller: _poBankId, label: 'Bank id'),
          const SizedBox(height: 12),
          _TwoColumnFields(
            first: _TextInput(
              controller: _poAccountNumber,
              label: 'Account number',
            ),
            second: _TextInput(
              controller: _poAccountHolder,
              label: 'Account holder name',
            ),
          ),
          const SizedBox(height: 12),
          _TextInput(
            controller: _poAmount,
            label: 'Amount (USDB minor units)',
            keyboardType: TextInputType.number,
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton(
                onPressed: _busy
                    ? null
                    : () => _run(
                        () => widget.client.validatePayoutAccount(
                          userId: _userId,
                          country: _poCountry.text.trim(),
                          currency: _poCurrency.text.trim(),
                          accountNumber: _poAccountNumber.text.trim(),
                          bankId: _poBankId.text.trim().isEmpty
                              ? null
                              : _poBankId.text.trim(),
                        ),
                      ),
                child: const Text('Validate account'),
              ),
              FilledButton(
                onPressed: _busy
                    ? null
                    : () => _run(() async {
                        final res = await widget.client.createPayout(
                          userId: _userId,
                          sourceSmartWalletId: _walletId,
                          amount: _poAmount.text.trim(),
                          country: _poCountry.text.trim(),
                          currency: _poCurrency.text.trim(),
                          bankId: _poBankId.text.trim(),
                          accountNumber: _poAccountNumber.text.trim(),
                          accountHolderName: _poAccountHolder.text.trim(),
                        );
                        _capturePending(
                          json: res,
                          label: 'Bank payout',
                          complete: (signature) => widget.client.submitSignature(
                            userId: _userId,
                            workflowId:
                                (res['signatureRequest']
                                        as Map?)?['workflowId']
                                    ?.toString() ??
                                '',
                            signature: signature,
                          ),
                        );
                        return res;
                      }),
                child: const Text('Create payout'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildPaymentSection() {
    return _SectionCard(
      title: 'Payment wallet-selection (#69)',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Selects this wallet to fund a pending payment workflow, then '
            'returns a signatureRequest to authorize it.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          _TextInput(controller: _payWorkflowId, label: 'Payment workflow id'),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: _busy
                ? null
                : () => _run(() async {
                    final res = await widget.client.selectPaymentWallet(
                      userId: _userId,
                      workflowId: _payWorkflowId.text.trim(),
                      smartWalletId: _walletId,
                    );
                    _capturePending(
                      json: res,
                      label: 'Payment authorization',
                      complete: (signature) => widget.client.submitSignature(
                        userId: _userId,
                        workflowId:
                            (res['signatureRequest'] as Map?)?['workflowId']
                                ?.toString() ??
                            _payWorkflowId.text.trim(),
                        signature: signature,
                      ),
                    );
                    return res;
                  }),
            child: const Text('POST select-wallet'),
          ),
        ],
      ),
    );
  }
}

class ExampleException implements Exception {
  const ExampleException(this.message);

  final String message;

  @override
  String toString() => message;
}

class _HeaderBlock extends StatelessWidget {
  const _HeaderBlock({required this.title, required this.description});

  final String title;
  final String description;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 8),
          Text(description, style: Theme.of(context).textTheme.bodyMedium),
        ],
      ),
    );
  }
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 16),
            child,
          ],
        ),
      ),
    );
  }
}

class _TextInput extends StatelessWidget {
  const _TextInput({
    required this.controller,
    required this.label,
    this.hintText,
    this.keyboardType,
    this.obscureText = false,
    this.textCapitalization = TextCapitalization.none,
    this.inputFormatters,
  });

  final TextEditingController controller;
  final String label;
  final String? hintText;
  final TextInputType? keyboardType;
  final bool obscureText;
  final TextCapitalization textCapitalization;
  final List<TextInputFormatter>? inputFormatters;

  @override
  Widget build(BuildContext context) {
    return BMoniTextFormField.outlined(
      controller: controller,
      label: label,
      hintText: hintText,
      keyboardType: keyboardType,
      obscureText: obscureText,
      textCapitalization: textCapitalization,
      inputFormatters: inputFormatters,
      textInputAction: TextInputAction.next,
    );
  }
}

class _TwoColumnFields extends StatelessWidget {
  const _TwoColumnFields({required this.first, required this.second});

  final Widget first;
  final Widget second;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 560) {
          return Column(children: [first, const SizedBox(height: 12), second]);
        }
        return Row(
          children: [
            Expanded(child: first),
            const SizedBox(width: 12),
            Expanded(child: second),
          ],
        );
      },
    );
  }
}

class _CurrencyOptionTile extends StatelessWidget {
  const _CurrencyOptionTile({
    required this.option,
    required this.isSelected,
    required this.onTap,
    this.disabled = false,
    this.footnote,
  });

  final WalletCurrencyOption option;
  final bool isSelected;
  final VoidCallback onTap;
  final bool disabled;
  final String? footnote;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final effectiveSelected = isSelected && !disabled;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: disabled ? null : onTap,
        child: Opacity(
          opacity: disabled ? 0.5 : 1,
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: effectiveSelected
                    ? colorScheme.primary
                    : colorScheme.outline,
              ),
              color: effectiveSelected
                  ? colorScheme.primaryContainer.withValues(alpha: 0.35)
                  : colorScheme.surface,
            ),
            child: Row(
              children: [
                Icon(
                  effectiveSelected
                      ? Icons.radio_button_checked
                      : Icons.radio_button_off,
                  color: effectiveSelected
                      ? colorScheme.primary
                      : colorScheme.outline,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        option.label,
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '${option.smartWalletCurrency} · ${option.kycProviderLabel}',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      if (footnote != null) ...[
                        const SizedBox(height: 4),
                        Text(
                          footnote!,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(
                                color: colorScheme.error,
                                fontWeight: FontWeight.w600,
                              ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _WalletActionRow extends StatelessWidget {
  const _WalletActionRow({
    required this.onTopUp,
    required this.onWithdraw,
    required this.onSwap,
  });

  final VoidCallback onTopUp;
  final VoidCallback onWithdraw;
  final VoidCallback onSwap;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: _WalletActionButton(
            icon: Icons.add,
            label: 'Top up',
            onPressed: onTopUp,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _WalletActionButton(
            icon: Icons.arrow_upward,
            label: 'Withdraw',
            onPressed: onWithdraw,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _WalletActionButton(
            icon: Icons.swap_horiz,
            label: 'Swap',
            onPressed: onSwap,
          ),
        ),
      ],
    );
  }
}

class _WalletActionButton extends StatelessWidget {
  const _WalletActionButton({
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton(
      onPressed: onPressed,
      style: OutlinedButton.styleFrom(
        padding: const EdgeInsets.symmetric(vertical: 14),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [Icon(icon), const SizedBox(height: 6), Text(label)],
      ),
    );
  }
}

class _StatusPanel extends StatelessWidget {
  const _StatusPanel({required this.message, required this.error});

  final String? message;
  final String? error;

  @override
  Widget build(BuildContext context) {
    if (message == null && error == null) {
      return const SizedBox.shrink();
    }
    final colorScheme = Theme.of(context).colorScheme;
    final isError = error != null;
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: isError
              ? colorScheme.errorContainer
              : colorScheme.primaryContainer,
          borderRadius: BorderRadius.circular(12),
        ),
        child: SelectableText.rich(
          TextSpan(
            text: isError ? error : message,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: isError
                  ? colorScheme.onErrorContainer
                  : colorScheme.onPrimaryContainer,
            ),
          ),
        ),
      ),
    );
  }
}

class _SmartWalletSummary extends StatelessWidget {
  const _SmartWalletSummary({required this.wallet});

  final SmartWallet wallet;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _KeyValueRow(label: 'Wallet ID', value: wallet.id),
        _KeyValueRow(label: 'Currency', value: wallet.currency),
        _KeyValueRow(label: 'Status', value: wallet.status.ifEmpty('n/a')),
        _KeyValueRow(
          label: 'Smart account',
          value:
              wallet.smartAccountAddress ??
              wallet.safeAddress ??
              wallet.walletAddress ??
              'n/a',
        ),
      ],
    );
  }
}

class _KeyValueRow extends StatelessWidget {
  const _KeyValueRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 120,
            child: Text(label, style: Theme.of(context).textTheme.labelLarge),
          ),
          Expanded(child: SelectableText(value)),
        ],
      ),
    );
  }
}

class _LastResponsePanel extends StatelessWidget {
  const _LastResponsePanel({required this.value});

  final String value;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return _SectionCard(
      title: 'Last response',
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
        ),
        child: SelectableText(
          value,
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ),
    );
  }
}

class _LoadingView extends StatelessWidget {
  const _LoadingView();

  @override
  Widget build(BuildContext context) {
    return const Center(child: CircularProgressIndicator.adaptive());
  }
}

extension on String {
  String ifEmpty(String fallback) => isEmpty ? fallback : this;
}
