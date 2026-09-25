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
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';
import 'package:webview_flutter_wkwebview/webview_flutter_wkwebview.dart';

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

/// A chain + token pair accepted for crypto top-ups, from
/// `GET /v1/deposit/supported-assets`.
typedef DepositAsset = ({String chain, String currency});

/// A supported Nigerian bank, from `GET …/bank-accounts/nigerian-banks`.
typedef NigerianBank = ({String name, String code});

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
  usd('US Dollar', 'USD', 'USDB', 'US KYC'),
  cad('Canadian Dollar', 'CAD', 'CADC', 'PayTrie KYC'),
  eur('Euro', 'EUR', 'EURe', 'Monerium KYC'),
  ngn('Naira', 'NGN', 'CNGN', 'Anchor KYC'),
  mxn('Mexican Peso', 'MXN', 'MEXe', 'Etherfuse KYC');

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

  /// The Global-KYC path (USD / EUR / MXN) requires a biometric selfie upload
  /// (`POST …/kyc/documents/biometric`) and liveness at activation.
  bool get usesGlobalKyc => this == usd || this == eur || this == mxn;

  /// `sumsubLevelName` for `POST …/kyc/activate`. Required for every country
  /// except Canada, which routes to PayTrie and ignores it. NGN uploads no
  /// selfie, so it uses the ID-only level.
  String? get sumsubLevelName => switch (this) {
    cad => null,
    ngn => 'id-only',
    _ => 'id-and-liveness',
  };

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

  /// From `GET /v1/smart-wallets/supported-currencies`. Empty means "not loaded
  /// yet" — the picker only filters once the API has answered.
  List<String> _supportedWalletCurrencies = const [];
  WalletCurrencyOption _selectedCurrency = WalletCurrencyOption.usd;
  String? _ownerAddress;

  /// Set after a Nigerian offramp returns a proposal. It needs an owner-key
  /// signature once approvals move it to `PENDING_SIGNATURES`.
  String? _pendingProposalId;
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

  static const int _kycPageCount = 6;

  final ImagePicker _imagePicker = ImagePicker();

  Uint8List? _kycIdFrontBytes;
  Uint8List? _kycIdBackBytes;
  String? _kycIdFrontFilename;
  String? _kycIdBackFilename;
  Uint8List? _kycPoaBytes;
  Uint8List? _kycPoaBackBytes;
  String? _kycPoaFilename;
  String? _kycPoaBackFilename;

  /// Biometric selfie for the Global-KYC path (USD / EUR / MXN) — uploaded to
  /// `POST …/kyc/documents/biometric`. Not required for CAD / NGN.
  Uint8List? _kycSelfieBytes;
  String? _kycSelfieFilename;

  String? _kycIdDocType;
  late final TextEditingController _kycIdDocumentNumberController;
  late final TextEditingController _kycIdIssuingCountryController;
  late final TextEditingController _kycIdExpirationController;
  late final TextEditingController _kycIdIssueController;
  String _kycPoaDocType = 'utility_bill';

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
    // Sandbox test BVN from the docs: always verifies, returns fixed holder
    // details. Real BVNs are only accepted in production.
    _kycBvnController = TextEditingController(text: '22222222222');
    _kycIdDocumentNumberController = TextEditingController(text: 'A12345678');
    _kycIdIssuingCountryController = TextEditingController(text: 'NGA');
    _kycIdExpirationController = TextEditingController(text: '2030-01-01');
    _kycIdIssueController = TextEditingController(text: '2020-01-01');
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

  /// True when the API has told us it cannot hold [option]'s stablecoin.
  bool _isCurrencyUnsupported(WalletCurrencyOption option) =>
      _supportedWalletCurrencies.isNotEmpty &&
      !_supportedWalletCurrencies
          .map((c) => c.toUpperCase())
          .contains(option.smartWalletCurrency.toUpperCase());

  /// Best-effort refresh of the supported-currency list. A failure here must not
  /// block wallet creation, so the list simply stays empty and nothing filters.
  Future<void> _loadSupportedWalletCurrencies() async {
    try {
      final currencies = await _client.getSupportedSmartWalletCurrencies();
      if (!mounted || currencies.isEmpty) {
        return;
      }
      setState(() => _supportedWalletCurrencies = currencies);
    } catch (_) {
      // Ignored: the picker falls back to showing every known currency.
    }
  }

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
    await _loadSupportedWalletCurrencies();
    if (!mounted) {
      return;
    }
    final available = WalletCurrencyOption.values
        .where(
          (o) =>
              !_ownedStablecoinCodes.contains(
                o.smartWalletCurrency.toUpperCase(),
              ) &&
              !_isCurrencyUnsupported(o),
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
      _pendingProposalId = null;
      _step = ExampleStep.selectCurrency;
      _message = 'Account created. Choose a wallet currency next.';
      _lastResponse = _prettyJson(user.toJson());
    });
    await _saveSession(isLoggedIn: true);
    await _loadSupportedWalletCurrencies();
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
      _pendingProposalId = null;
      _message = 'Logged out. Unlock with the device PIN to continue.';
    });
    await _saveSession(isLoggedIn: false);
  });

  /// Full reset: wipes the local session, the on-device wallet, and the PIN,
  /// then returns to account setup. The proxy URL + API key are kept so setup
  /// is friction-free. Deleting the device wallet requires the matching PIN
  /// (the SDK runs with `requirePin: true`); a missing/incorrect PIN leaves the
  /// device key in place but still clears the app session.
  Future<void> _confirmAndResetEverything() async {
    if (_isBusy) {
      return;
    }
    final pinController = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Reset app'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'This deletes the local session, the on-device wallet, and the '
              'PIN, then returns to account setup. The proxy URL and API key '
              'are kept. This cannot be undone.',
            ),
            const SizedBox(height: 16),
            TextField(
              controller: pinController,
              obscureText: true,
              keyboardType: TextInputType.number,
              inputFormatters: [
                FilteringTextInputFormatter.digitsOnly,
                LengthLimitingTextInputFormatter(BmoniEmbeddedSdk.pinLength),
              ],
              decoration: const InputDecoration(
                labelText: 'Current PIN (to wipe the device wallet)',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Reset'),
          ),
        ],
      ),
    );
    final pin = pinController.text.trim();
    pinController.dispose();
    if (confirmed != true) {
      return;
    }
    await _runTask(() async {
      String? walletNote;
      try {
        if (await BmoniEmbeddedSdk.hasWallet()) {
          await BmoniEmbeddedSdk.deleteWallet(pin: pin);
        }
        if (await BmoniEmbeddedSdk.hasPin()) {
          await BmoniEmbeddedSdk.removePin(pin);
        }
      } catch (_) {
        walletNote =
            ' The on-device wallet/PIN was not removed (PIN missing or '
            'incorrect) — enter the correct PIN to wipe it.';
      }

      final prefs = await SharedPreferences.getInstance();
      // Keep baseUrl + apiKey for convenient re-setup; clear everything else.
      for (final key in const [
        _ExampleSessionKeys.user,
        _ExampleSessionKeys.smartWallet,
        _ExampleSessionKeys.currency,
        _ExampleSessionKeys.ownerAddress,
        _ExampleSessionKeys.isLoggedIn,
      ]) {
        await prefs.remove(key);
      }

      if (!mounted) {
        return;
      }
      _pinController.clear();
      setState(() {
        _profile = null;
        _smartWallet = null;
        _ownerAddress = null;
        _accountWallets = [];
        _accountBalancesData = const {};
        _addingAnotherWallet = false;
        _pendingProposalId = null;
        _selectedCurrency = WalletCurrencyOption.usd;
        _lastResponse = null;
        _step = ExampleStep.createAccount;
        _message =
            'App reset.${walletNote ?? ''} Create a new account to set up again.';
      });
    });
  }

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
                subtitle: const Text('On-chain deposit address'),
                onTap: () => Navigator.pop(ctx, 'crypto'),
              ),
              ListTile(
                leading: const Icon(Icons.account_balance),
                title: const Text('Bank transfer (VBA)'),
                subtitle: Text(switch (_selectedCurrency) {
                  WalletCurrencyOption.usd =>
                    'Provision a USD virtual bank account for this wallet',
                  WalletCurrencyOption.ngn =>
                    'Route your NGN virtual bank account to this wallet',
                  WalletCurrencyOption.eur =>
                    'Route your EUR virtual bank account (IBAN) to this wallet',
                  WalletCurrencyOption.mxn =>
                    'Deposit MXN by SPEI to your CLABE',
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

  /// Crypto top-up. The chain/token list comes from
  /// `GET /v1/deposit/supported-assets` rather than being hardcoded; USDC on
  /// Base is only the fallback when that catalogue cannot be read.
  Future<void> _executeTopUpCrypto() async {
    final userId = _requiredUserId;
    final smartWalletId = _requiredSmartWallet.id;

    var assets = const <DepositAsset>[];
    try {
      assets = await _client.getSupportedDepositAssets();
    } on ExampleException {
      // Non-fatal — fall back to the documented default pair below.
    }
    var asset = assets.isNotEmpty
        ? assets.first
        : const (chain: 'Base', currency: 'USDC');
    if (assets.length > 1) {
      if (!mounted) {
        return;
      }
      final picked = await _pickDepositAsset(assets);
      if (picked == null || !mounted) {
        return;
      }
      asset = picked;
    }

    final response = await _client.depositToWallet(
      userId: userId,
      smartWalletId: smartWalletId,
      chain: asset.chain,
      currency: asset.currency,
    );
    if (!mounted) {
      return;
    }
    setState(() {
      final address = response['address'];
      final pair = '${asset.currency} on ${asset.chain}';
      _message = address is String && address.isNotEmpty
          ? 'Top up: send $pair to $address — it is converted and credited automatically.'
          : 'Top up: deposit address generated. Send $pair to the returned address.';
      _lastResponse = _prettyJson(response);
    });
  }

  Future<DepositAsset?> _pickDepositAsset(List<DepositAsset> assets) {
    return showDialog<DepositAsset>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Deposit asset'),
        children: [
          for (final asset in assets)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, asset),
              child: Text('${asset.currency} · ${asset.chain}'),
            ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
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
      case WalletCurrencyOption.mxn:
        await _topUpBankMxn(userId);
      case WalletCurrencyOption.cad:
        throw const ExampleException(
          'Bank transfer top-up for CAD is not wired in this example. '
          'Use crypto top-up.',
        );
    }
  }

  /// USD bank top-up: readiness gate (`GET /kyc/usd-readiness`) → provision
  /// (`POST /onboarding/start-usa`) → poll status (`GET /vba/usd`). Provisioning
  /// binds the USD VBA to the smart wallet; there is no separate "link" step.
  Future<void> _topUpBankUsd(String userId, String smartWalletId) async {
    final readiness = await _client.getUsdReadiness(userId);
    if (readiness['ready'] != true) {
      final missing = (readiness['missing'] as List?)?.join(', ') ?? 'unknown';
      setState(() {
        _message = 'USD VBA not ready. Outstanding requirements: $missing.';
        _lastResponse = _prettyJson(readiness);
      });
      return;
    }
    final provision = await _client.startUsaOnboarding(
      userId: userId,
      smartWalletId: smartWalletId,
    );
    final vba = await _client.getUsdVba(userId);
    if (!mounted) {
      return;
    }
    setState(() {
      _message =
          'USD VBA provisioning ${provision['workflowId'] != null ? "started" : "requested"} '
          '(status: ${vba['status'] ?? 'unknown'}). Poll GET /vba/usd for account '
          'details once active.';
      _lastResponse = _prettyJson({'provision': provision, 'vba': vba});
    });
  }

  /// Nigerian bank top-up: route the NGN virtual bank account (created by
  /// `start-nigeria` onboarding) to this wallet — incoming NGN is swept to it
  /// as cNGN.
  Future<void> _topUpBankNgn(String userId, String smartWalletId) async {
    final raw = await _client.getBankAccounts(userId);
    final ng = ProxyApiClient.extractNigerianDeposits(raw);
    if (ng.isEmpty) {
      throw const ExampleException(
        'No NGN deposit account yet. It is created by Nigeria onboarding '
        '(POST /onboarding/start-nigeria).',
      );
    }
    if (!mounted) {
      return;
    }
    final bankAccountId = await _pickDepositBankAccountId(
      context: context,
      accounts: ng,
      title: 'Nigerian deposit VBA',
    );
    if (!mounted || bankAccountId == null) {
      return;
    }
    final link = await _client.linkDepositVba(
      userId: userId,
      smartWalletId: smartWalletId,
      region: 'nigeria',
      bankAccountId: bankAccountId,
    );
    // The NUBAN the user actually transfers to lives on the deposit-accounts
    // endpoint; it is informational here, so a failure must not fail the top-up.
    Object? depositAccounts;
    try {
      depositAccounts = await _client.getDepositAccounts(userId, 'NGN');
    } on ExampleException {
      depositAccounts = null;
    }
    if (!mounted) {
      return;
    }
    setState(() {
      _message =
          'NGN deposit account routed to this wallet. Incoming NGN is swept '
          'to it as cNGN.';
      _lastResponse = _prettyJson({
        'link': link,
        'depositAccounts': depositAccounts,
      });
    });
  }

  /// EUR bank top-up: route the EUR IBAN (created by `start-monerium`
  /// onboarding) to this wallet. (Outbound EUR SEPA payouts are the separate
  /// `/eu/*` module — see the Integrations screen.)
  Future<void> _topUpBankEur(String userId, String smartWalletId) async {
    final raw = await _client.getBankAccounts(userId);
    final eu = ProxyApiClient.extractEuropeanDeposits(raw);
    if (eu.isEmpty) {
      throw const ExampleException(
        'No EUR deposit account yet. It is created by EU onboarding '
        '(POST /onboarding/start-monerium).',
      );
    }
    if (!mounted) {
      return;
    }
    final bankAccountId = await _pickDepositBankAccountId(
      context: context,
      accounts: eu,
      title: 'European deposit IBAN',
    );
    if (!mounted || bankAccountId == null) {
      return;
    }
    final link = await _client.linkDepositVba(
      userId: userId,
      smartWalletId: smartWalletId,
      region: 'eu',
      bankAccountId: bankAccountId,
    );
    if (!mounted) {
      return;
    }
    setState(() {
      _message =
          'EUR IBAN reserved for this wallet. Outbound SEPA payouts use the EU '
          'module on the Integrations screen.';
      _lastResponse = _prettyJson(link);
    });
  }

  /// MXN bank top-up: deposit-driven. The SPEI CLABE exists once Mexico KYC is
  /// approved; MXN sent to it onramps automatically, with no quote or order.
  Future<void> _topUpBankMxn(String userId) async {
    final accounts = await _client.getDepositAccounts(userId, 'MXN');
    if (!mounted) {
      return;
    }
    setState(() {
      _message =
          'Send MXN by SPEI to the CLABE below. It onramps to this wallet '
          'automatically.';
      _lastResponse = _prettyJson(accounts ?? const <String, dynamic>{});
    });
  }

  /// Returns the picked account id; null if cancelled.
  Future<String?> _pickDepositBankAccountId({
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

  /// Withdraw bank offramp is wired for Nigeria only here. USD/EU/LATAM payouts
  /// use the payout rails under Explore integrations. Crypto offramp was removed
  /// from the proxy surface.
  Future<void> _handleWithdraw() async {
    if (_isBusy) {
      return;
    }
    final active = await _ensureKycReady();
    if (!active || !mounted) {
      return;
    }
    if (_selectedCurrency != WalletCurrencyOption.ngn) {
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Bank withdrawal'),
          content: Text(
            'This example wires bank offramp for Nigeria only. For '
            '${_selectedCurrency.label}, use the payout rails under '
            'Explore integrations (bank payouts, EU SEPA, LATAM).',
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
    await _withdrawBankNgn();
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
    final proposalId = ProxyApiClient.readProposalId(proposal);
    setState(() {
      _pendingProposalId = proposalId;
      _message = proposalId == null
          ? 'Nigerian bank offramp proposal created, but the response carried '
                'no proposalId — check the raw body below.'
          : 'Proposal $proposalId created (status '
                '${proposal['status'] ?? 'unknown'}). Once approvals move it to '
                'PENDING_SIGNATURES, sign it with the owner key below.';
      _lastResponse = _prettyJson(proposal);
    });
  }

  /// `GET …/smart-wallets/proposals/:proposalId` — poll for the terminal status.
  Future<void> _checkPendingProposal() => _runTask(() async {
    final proposalId = _pendingProposalId;
    if (proposalId == null) {
      return;
    }
    final proposal = await _client.getProposal(
      userId: _requiredUserId,
      proposalId: proposalId,
    );
    if (!mounted) {
      return;
    }
    final status = (proposal['status'] ?? 'unknown').toString();
    setState(() {
      _message = 'Proposal $proposalId is $status.';
      _lastResponse = _prettyJson(proposal);
      if (status.toUpperCase() == 'COMPLETED') {
        _pendingProposalId = null;
      }
    });
  });

  /// `GET …/proposals/:id/sign-payload` → sign the EIP-712 digest with the owner
  /// key → `POST …/proposals/:id/sign`. The signer must be the same key
  /// registered as `userOwnerAddress`, or the recovered address will not match.
  Future<void> _signPendingProposal() async {
    final proposalId = _pendingProposalId;
    if (proposalId == null || _isBusy) {
      return;
    }
    final pin = await _promptPin();
    if (pin == null) {
      return;
    }
    await _runTask(() async {
      final userId = _requiredUserId;
      final payload = await _client.getProposalSignPayload(
        userId: userId,
        proposalId: proposalId,
      );
      final hash = ProxyApiClient.extractSignableHash(payload);
      if (hash == null) {
        if (!mounted) {
          return;
        }
        setState(() {
          _message =
              'sign-payload returned no 32-byte digest to sign — inspect the '
              'raw payload below before signing anything.';
          _lastResponse = _prettyJson(payload);
        });
        return;
      }
      final signature = await BmoniEmbeddedSdk.signTransactionHash(
        hash,
        pin: pin,
      );
      final signed = await _client.signProposal(
        userId: userId,
        proposalId: proposalId,
        signature: signature,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _message =
            'Signature submitted for proposal $proposalId (status '
            '${signed['status'] ?? 'unknown'}).';
        _lastResponse = _prettyJson({'signPayload': payload, 'sign': signed});
      });
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
          inputFormatters: [
            FilteringTextInputFormatter.digitsOnly,
            LengthLimitingTextInputFormatter(BmoniEmbeddedSdk.pinLength),
          ],
          decoration: InputDecoration(
            labelText: '${BmoniEmbeddedSdk.pinLength}-digit PIN',
          ),
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
    final amount = num.tryParse(_amountController.text.trim());
    if (amount == null || amount <= 0) {
      throw const ExampleException('Enter an amount greater than zero.');
    }
    final response = await _client.convertCurrency(
      userId: _requiredUserId,
      amount: amount,
      from: _selectedCurrency.fiatCode,
      to: _toCurrencyController.text.trim().toUpperCase(),
    );
    setState(() {
      _message = 'Swap preview returned by the exchange endpoint.';
      _lastResponse = _prettyJson(response);
    });
  });

  Future<bool> _ensureKycReady() async {
    // USD readiness is the USD virtual bank account lifecycle (GET /vba/usd),
    // not an onboarding/status rail — that endpoint no longer reports USD.
    if (_selectedCurrency == WalletCurrencyOption.usd) {
      Map<String, dynamic> vba;
      try {
        vba = await _client.getUsdVba(_requiredUserId);
      } on ExampleException {
        // No USD account yet — run the wizard, which activates KYC and
        // provisions the account via POST /onboarding/start-usa.
        await _openKycWizard(const {'status': 'none'});
        return false;
      }
      final status = (vba['status'] ?? '').toString().toLowerCase();
      if (status == 'active') {
        return true;
      }
      if (status == 'provisioning' || status == 'pending') {
        await _showPendingVerificationDialog();
        return false;
      }
      await _openKycWizard(vba);
      return false;
    }

    // Mexico reports its own Etherfuse review status; onboarding/status does
    // not cover it. Poll GET /latam/mx/kyc/status until it reads `approved`.
    if (_selectedCurrency == WalletCurrencyOption.mxn) {
      Map<String, dynamic> mx;
      try {
        mx = await _client.getMxKycStatus(_requiredUserId);
      } on ExampleException {
        await _openKycWizard(const {'status': 'none'});
        return false;
      }
      // Documented statuses: not_started | in_progress | proposed | approved |
      // rejected. `proposed` waits on the user finishing the hosted flow.
      final status = (mx['status'] ?? '').toString().toLowerCase();
      switch (status) {
        case 'approved':
          return true;
        case 'in_progress':
          await _showPendingVerificationDialog();
        case 'proposed':
          if (!mounted) {
            return false;
          }
          final after = await openMxHostedVerification(
            context: context,
            client: _client,
            userId: _requiredUserId,
          );
          if (!mounted) {
            return false;
          }
          setState(() {
            _message =
                'Mexico verification status: ${after['status'] ?? 'unknown'}. '
                'Top up and withdraw unlock once it is approved.';
            _lastResponse = _prettyJson(after);
          });
        default:
          await _openKycWizard(mx);
      }
      return false;
    }

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
        _kycSelfieBytes = null;
        _kycSelfieFilename = null;
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

  Future<void> _pickKycSelfie() => _pickKycImage(
    onBytes: (b, name) => setState(() {
      _kycSelfieBytes = b;
      _kycSelfieFilename = name;
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

    // Global-KYC path (USD / EUR / MXN): the biometric selfie is part of the
    // fixed submit order, before /kyc/readiness. CAD / NGN skip it.
    Map<String, dynamic>? biometricUpload;
    final selfie = _kycSelfieBytes;
    if (_selectedCurrency.usesGlobalKyc) {
      if (selfie == null) {
        throw ExampleException(
          'A biometric selfie is required for ${_selectedCurrency.fiatCode} '
          'onboarding. Pick one on the Documents step.',
        );
      }
      biometricUpload = await _client.uploadKycBiometric(
        userId: userId,
        file: http.MultipartFile.fromBytes(
          'selfie',
          selfie,
          filename: _kycSelfieFilename ?? 'biometric_selfie.jpg',
          contentType: multipartMediaTypeForFilename(_kycSelfieFilename),
        ),
      );
    }

    final readinessResult = await _client.getKycReadiness(userId);

    final activateResult = await _client.activateKyc(
      userId: userId,
      sumsubLevelName: _selectedCurrency.sumsubLevelName,
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
          'KYC profile saved, documents uploaded, verification activated, and '
          '${_selectedCurrency.kycProviderLabel} started. Retry your action.';
      _lastResponse = _prettyJson({
        'patchKyc': patchResult,
        'uploadIdentification': idUpload,
        'uploadProofOfAddress': poaUpload,
        'uploadBiometric': ?biometricUpload,
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
        if (_selectedCurrency.usesGlobalKyc && _kycSelfieBytes == null) {
          setState(() {
            _error =
                'Documents: ${_selectedCurrency.fiatCode} runs the Global KYC '
                'path, which requires a biometric selfie.';
          });
          return false;
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
      // USD readiness is handled via GET /vba/usd, and MXN via
      // GET /latam/mx/kyc/status — neither is reported by onboarding/status.
      WalletCurrencyOption.usd => null,
      WalletCurrencyOption.mxn => null,
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
          if (_step != ExampleStep.loading)
            IconButton(
              tooltip: 'Reset app',
              onPressed: _isBusy ? null : _confirmAndResetEverything,
              icon: const Icon(Icons.restart_alt),
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
                      label: 'BVN (11 digits · sandbox test 22222222222)',
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
                    'Uses POST …/kyc/documents/identification, '
                    '…/documents/proof-of-address and, on the Global KYC path '
                    '(USD / EUR / MXN), …/documents/biometric (multipart).',
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
                      if (_selectedCurrency.usesGlobalKyc)
                        BMoniButton.secondary(
                          onPressed: _isBusy ? null : _pickKycSelfie,
                          text: _kycSelfieBytes == null
                              ? 'Selfie (required)'
                              : 'Selfie ✓',
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
                    '${_kycPoaBytes != null ? "PoA ready" : "no PoA"}'
                    '${_selectedCurrency.usesGlobalKyc
                        ? _kycSelfieBytes != null
                              ? " · selfie ready"
                              : " · no selfie"
                        : ""}',
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Submit runs: PATCH /kyc → upload ID & PoA'
                    '${_selectedCurrency.usesGlobalKyc ? " & biometric" : ""} → '
                    'GET /kyc/readiness → POST /kyc/activate'
                    '${_selectedCurrency.sumsubLevelName != null ? " (sumsubLevelName: ${_selectedCurrency.sumsubLevelName})" : " (no body)"} → '
                    '${_selectedCurrency.kycProviderLabel} '
                    '${_selectedCurrency == WalletCurrencyOption.mxn ? "activation" : "start-* onboarding"}.',
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
                () {
                  final owned = _ownedStablecoinCodes.contains(
                    option.smartWalletCurrency.toUpperCase(),
                  );
                  final unsupported = _isCurrencyUnsupported(option);
                  return _CurrencyOptionTile(
                    option: option,
                    isSelected: option == _selectedCurrency,
                    disabled: owned || unsupported,
                    footnote: owned
                        ? 'Already created for this account'
                        : unsupported
                        ? 'Not in GET /v1/smart-wallets/supported-currencies'
                        : null,
                    onTap: () => setState(() => _selectedCurrency = option),
                  );
                }(),
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
                          ) ||
                          _isCurrencyUnsupported(_selectedCurrency)
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
          smartWalletAddress:
              _requiredSmartWallet.smartAccountAddress ??
              _requiredSmartWallet.walletAddress,
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
              'Top up: crypto (chains and tokens from '
              'GET /v1/deposit/supported-assets) or bank (USD / NGN / EUR '
              'virtual bank account, MXN CLABE). Withdraw: Nigerian bank offramp — a '
              'proposal you then sign with the owner key. More provider ramps '
              '(swap quote, EU SEPA, LATAM cash, MXN offramp, payouts) '
              'live under Explore integrations. Onboarding is checked first.',
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
        if (_pendingProposalId != null) ...[
          const SizedBox(height: 16),
          _SectionCard(
            title: 'Pending offramp proposal',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _KeyValueRow(label: 'Proposal', value: _pendingProposalId!),
                Text(
                  'PENDING_APPROVALS → PENDING_SIGNATURES → COMPLETED. Signing '
                  'before approvals clear is rejected — poll the status first.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: _isBusy ? null : _checkPendingProposal,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Check status'),
                ),
                const SizedBox(height: 8),
                FilledButton.icon(
                  onPressed: _isBusy ? null : _signPendingProposal,
                  icon: const Icon(Icons.draw_outlined),
                  label: const Text('Sign proposal with owner key'),
                ),
              ],
            ),
          ),
        ],
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
    // `account/wallets` returns a top-level JSON array of wallets. Some gateways
    // wrap it as `{ data | value: { smartWallets | wallets: [...] } }`, so use
    // the array-tolerant request and normalise every shape to a list.
    final decoded = await _requestRaw(
      method: 'GET',
      path: '/v1/users/$userId/smart-wallets/account/wallets',
    );
    List<dynamic> rawList = const [];
    if (decoded is List) {
      rawList = decoded;
    } else if (decoded is Map<String, dynamic>) {
      final data = decoded['data'];
      if (data is List) {
        rawList = data;
      } else {
        // Upstream group-wallet uses `wallets`; proxy OpenAPI uses
        // `smartWallets`. Some gateways nest the dashboard under `data`/`value`.
        final layer = data is Map<String, dynamic> ? data : decoded;
        var list = layer['smartWallets'] ?? layer['wallets'];
        if (list is! List) {
          final inner = layer['value'];
          if (inner is List) {
            list = inner;
          } else if (inner is Map<String, dynamic>) {
            list = inner['smartWallets'] ?? inner['wallets'];
          }
        }
        if (list is List) {
          rawList = list;
        }
      }
    }
    final out = <SmartWallet>[];
    for (final item in rawList) {
      if (item is Map) {
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

  /// Biometric selfie upload. Required on the Global KYC path (USD / EUR / MXN)
  /// and not used for CAD / NGN. [file] must be created with the field name
  /// `selfie` (not `files` like the other document endpoints).
  Future<Map<String, dynamic>> uploadKycBiometric({
    required String userId,
    required http.MultipartFile file,
  }) {
    return _sendMultipartJson(
      path: '/v1/users/$userId/kyc/documents/biometric',
      files: [file],
      fields: const {'type': 'selfie'},
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
        // Mexico activates through Etherfuse instead of onboarding/start-*.
        WalletCurrencyOption.mxn => '/v1/users/$userId/latam/mx/kyc/activate',
      },
      body: _kycStartBody(currency, smartWallet, nigeriaBvn: nigeriaBvn),
    );
  }

  /// Crypto top-up. `POST /deposit/wallet` returns a one-time on-chain deposit
  /// address; any supported crypto sent to it is converted and credited to the
  /// smart wallet.
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

  Future<Map<String, dynamic>> getBankAccounts(String userId) async {
    final json = await _request(
      method: 'GET',
      path: '/v1/users/$userId/bank-accounts',
    );
    return bankAccountsRoot(_unwrapData(json));
  }

  /// Routes an existing deposit VBA to a smart wallet
  /// (`POST …/smart-wallets/{id}/onramp/vba/{region}`). [region] is `nigeria`
  /// (NGN → cNGN) or `eu` (IBAN → EURe). The account itself comes from the
  /// rail's onboarding (`start-nigeria` / `start-monerium`).
  Future<Map<String, dynamic>> linkDepositVba({
    required String userId,
    required String smartWalletId,
    required String region,
    required String bankAccountId,
  }) async {
    final json = await _request(
      method: 'POST',
      path: '/v1/users/$userId/smart-wallets/$smartWalletId/onramp/vba/$region',
      body: {'bankAccountId': bankAccountId},
    );
    return _unwrapData(json);
  }

  /// USD virtual bank account flow: gate on readiness
  /// (`GET /kyc/usd-readiness`) → provision (`POST /onboarding/start-usa`) →
  /// poll status (`GET /vba/usd`).
  Future<Map<String, dynamic>> getUsdReadiness(String userId) async {
    final json = await _request(
      method: 'GET',
      path: '/v1/users/$userId/kyc/usd-readiness',
    );
    return _unwrapData(json);
  }

  Future<Map<String, dynamic>> startUsaOnboarding({
    required String userId,
    required String smartWalletId,
  }) async {
    final json = await _request(
      method: 'POST',
      path: '/v1/users/$userId/onboarding/start-usa',
      body: {'smartWalletId': smartWalletId},
    );
    return _unwrapData(json);
  }

  /// Smart-wallet-scoped USD VBA provisioning (Graph Finance). Same account as
  /// `start-usa`, keyed on the wallet in the path; takes no body. Idempotent.
  Future<Map<String, dynamic>> provisionSmartWalletUsdVba({
    required String userId,
    required String smartWalletId,
  }) async {
    final json = await _request(
      method: 'POST',
      path:
          '/v1/users/$userId/smart-wallets/$smartWalletId/onramp/vba/usd/provision',
    );
    return _unwrapData(json);
  }

  Future<Map<String, dynamic>> getUsdVba(String userId) async {
    final json = await _request(
      method: 'GET',
      path: '/v1/users/$userId/vba/usd',
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

  /// Nigerian bank offramp. `fromAmount` is a **decimal** string (`"100.00"`) —
  /// unlike `POST /payouts`, whose `amount` is USDB minor units. Returns a
  /// proposal (`proposalId`, `status`), not a completed payout: it moves
  /// `PENDING_APPROVALS` → `PENDING_SIGNATURES` → `COMPLETED`, and the owner key
  /// signs it via [getProposalSignPayload] + [signProposal].
  Future<Map<String, dynamic>> offrampNigeriaBank({
    required String userId,
    required String smartWalletId,
    required String bankAccountId,
    required String fromAmount,
  }) async {
    final json = await _request(
      method: 'POST',
      path: '/v1/users/$userId/smart-wallets/$smartWalletId/offramp/nigeria',
      body: {'bankAccountId': bankAccountId, 'fromAmount': fromAmount},
    );
    return _unwrapData(json);
  }

  // ---------------------------------------------------------------------------
  // Smart-wallet proposals — approve-then-sign flow (Nigerian offramp)
  // ---------------------------------------------------------------------------

  /// EIP-712 payload for a pending proposal. Returns 404/409 while the proposal
  /// is still `PENDING_APPROVALS`.
  Future<Map<String, dynamic>> getProposalSignPayload({
    required String userId,
    required String proposalId,
  }) async {
    final json = await _request(
      method: 'GET',
      path:
          '/v1/users/$userId/smart-wallets/proposals/$proposalId/sign-payload',
    );
    return _unwrapData(json);
  }

  Future<Map<String, dynamic>> signProposal({
    required String userId,
    required String proposalId,
    required String signature,
  }) async {
    final json = await _request(
      method: 'POST',
      path: '/v1/users/$userId/smart-wallets/proposals/$proposalId/sign',
      body: {'signature': signature},
    );
    return _unwrapData(json);
  }

  Future<Map<String, dynamic>> getProposal({
    required String userId,
    required String proposalId,
  }) async {
    final json = await _request(
      method: 'GET',
      path: '/v1/users/$userId/smart-wallets/proposals/$proposalId',
    );
    return _unwrapData(json);
  }

  // ---------------------------------------------------------------------------
  // Runtime discovery — build pickers instead of hardcoding lists
  // ---------------------------------------------------------------------------

  /// `GET /v1/smart-wallets/supported-currencies` — stablecoin codes a smart
  /// wallet can hold (`USDB`, `CNGN`, `CADC`, `EURe`, `GBPe`, `MEXe`). Not
  /// user-scoped, so it can be called before onboarding.
  Future<List<String>> getSupportedSmartWalletCurrencies() async {
    final decoded = await _requestRaw(
      method: 'GET',
      path: '/v1/smart-wallets/supported-currencies',
    );
    return parseSupportedCurrencies(decoded);
  }

  /// `GET /v1/deposit/supported-assets` — chains and tokens accepted for crypto
  /// top-ups. Also not user-scoped.
  Future<List<DepositAsset>> getSupportedDepositAssets() async {
    final decoded = await _requestRaw(
      method: 'GET',
      path: '/v1/deposit/supported-assets',
    );
    return flattenDepositAssets(decoded);
  }

  /// `GET …/bank-accounts/nigerian-banks` — every supported bank with its CBN
  /// code. Both the name and the code must be sent verbatim to
  /// `verify-nigerian-account` and `withdrawal-accounts/nigeria`.
  Future<List<NigerianBank>> getNigerianBanks(String userId) async {
    final decoded = await _requestRaw(
      method: 'GET',
      path: '/v1/users/$userId/bank-accounts/nigerian-banks',
    );
    return parseNigerianBanks(decoded);
  }

  /// `GET …/bank-accounts/deposit-accounts/{currency}` — the account details
  /// the user transfers to (NGN NUBAN, MXN SPEI CLABE, …).
  Future<Object?> getDepositAccounts(String userId, String currency) {
    return _requestRaw(
      method: 'GET',
      path: '/v1/users/$userId/bank-accounts/deposit-accounts/$currency',
    );
  }

  // ---------------------------------------------------------------------------
  // Tolerant parsers for provider-shaped payloads
  // ---------------------------------------------------------------------------

  /// Unwraps a `data` / `value` envelope, or returns [raw] unchanged.
  static Object? _payload(Object? raw, [Set<String>? keys]) {
    if (raw is! Map) {
      return raw;
    }
    for (final key in keys ?? const {'data', 'value'}) {
      final inner = raw[key];
      if (inner != null) {
        return inner;
      }
    }
    return raw;
  }

  static List<String> parseSupportedCurrencies(Object? raw) {
    final payload = _payload(raw, const {
      'data',
      'value',
      'currencies',
      'supportedCurrencies',
    });
    final out = <String>[];
    void add(Object? value) {
      if (value is String && value.trim().isNotEmpty) {
        final code = value.trim();
        if (!out.contains(code)) {
          out.add(code);
        }
      }
    }

    if (payload is List) {
      for (final item in payload) {
        if (item is Map) {
          add(item['currency'] ?? item['code'] ?? item['symbol']);
        } else {
          add(item);
        }
      }
    }
    return out;
  }

  /// Flattens `GET /v1/deposit/supported-assets` into `(chain, currency)` pairs.
  /// The payload is grouped by chain, and gateways differ on the exact shape, so
  /// accept a list of `{chain, currencies[]}`, a list of `{chain, currency}`, or
  /// a plain `{ "Base": ["USDC", …] }` map.
  static List<DepositAsset> flattenDepositAssets(Object? raw) {
    final payload = _payload(raw, const {'data', 'value', 'assets', 'chains'});
    final out = <DepositAsset>[];
    void add(String? chain, Object? currency) {
      if (chain == null || chain.trim().isEmpty) {
        return;
      }
      final code = switch (currency) {
        final String s => s.trim(),
        final Map m =>
          (m['currency'] ?? m['code'] ?? m['symbol'])?.toString().trim() ?? '',
        _ => '',
      };
      if (code.isEmpty) {
        return;
      }
      final asset = (chain: chain.trim(), currency: code);
      if (!out.contains(asset)) {
        out.add(asset);
      }
    }

    void addGroup(String? chain, Map group) {
      final list = group['currencies'] ?? group['tokens'] ?? group['assets'];
      if (list is List) {
        for (final currency in list) {
          add(chain, currency);
        }
        return;
      }
      add(chain, group['currency'] ?? group['code'] ?? group['symbol']);
    }

    if (payload is List) {
      for (final item in payload) {
        if (item is Map) {
          addGroup(
            (item['chain'] ?? item['network'] ?? item['blockchain'])
                ?.toString(),
            item,
          );
        }
      }
    } else if (payload is Map) {
      payload.forEach((chain, value) {
        if (value is List) {
          for (final currency in value) {
            add(chain.toString(), currency);
          }
        } else if (value is Map) {
          addGroup(chain.toString(), value);
        }
      });
    }
    return out;
  }

  static List<NigerianBank> parseNigerianBanks(Object? raw) {
    final payload = _payload(raw, const {'data', 'value', 'banks'});
    final out = <NigerianBank>[];
    if (payload is! List) {
      return out;
    }
    for (final item in payload) {
      if (item is! Map) {
        continue;
      }
      final name = (item['name'] ?? item['bankName'])?.toString().trim() ?? '';
      final code =
          (item['code'] ?? item['bankCode'] ?? item['cbnCode'])
              ?.toString()
              .trim() ??
          '';
      if (name.isNotEmpty && code.isNotEmpty) {
        out.add((name: name, code: code));
      }
    }
    return out;
  }

  static String? readProposalId(Map<String, dynamic> json) {
    final root = _payload(json);
    if (root is! Map) {
      return null;
    }
    final id = root['proposalId'] ?? root['id'];
    return (id is String && id.trim().isNotEmpty) ? id.trim() : null;
  }

  /// Digs the 32-byte digest out of a `sign-payload` / `signatureRequest`
  /// response. Returns null when nothing 32-byte-shaped is present, so callers
  /// can show the raw body instead of signing a guess.
  static String? extractSignableHash(Object? raw) {
    const hashKeys = {
      'hashToSign',
      'signingPayloadHash',
      'payloadHash',
      'messageToSign',
      'digest',
      'hash',
    };
    final hex = RegExp(r'^0x[0-9a-fA-F]{64}$');

    String? walk(Object? node, int depth) {
      if (node is String) {
        return hex.hasMatch(node.trim()) ? node.trim() : null;
      }
      if (node is! Map || depth > 4) {
        return null;
      }
      for (final key in hashKeys) {
        final found = walk(node[key], depth + 1);
        if (found != null) {
          return found;
        }
      }
      for (final key in const [
        'data',
        'value',
        'signatureRequest',
        'payload',
      ]) {
        final found = walk(node[key], depth + 1);
        if (found != null) {
          return found;
        }
      }
      return null;
    }

    return walk(raw, 0);
  }

  Future<Map<String, dynamic>> convertCurrency({
    required String userId,
    required num amount,
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

  /// Bank payout into a LATAM country (the USD → MXN / CLP / COP corridor),
  /// funded from any stablecoin wallet. Returns a quote plus a
  /// `signatureRequest`; after submitting it, poll [getWorkflowStatus] — there
  /// is no order record for this payout.
  Future<Map<String, dynamic>> createLatamForeignPayout({
    required String userId,
    required String smartWalletId,
    required String usdcAmount,
    required String targetCountry,
    required String targetCurrency,
    required String description,
  }) {
    return _request(
      method: 'POST',
      path: '/v1/users/$userId/latam/cash/payouts/foreign',
      body: {
        'smartWalletId': smartWalletId,
        'usdcAmount': usdcAmount,
        'targetCountry': targetCountry,
        'targetCurrency': targetCurrency,
        'description': description,
      },
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

  Future<Map<String, dynamic>> activateMxKyc(String userId) async {
    final json = await _request(
      method: 'POST',
      path: '/v1/users/$userId/latam/mx/kyc/activate',
    );
    return _unwrapData(json);
  }

  /// Etherfuse review status — `pending` while in flight, `approved` once done.
  /// This is what gates MXN, not `onboarding/status`.
  Future<Map<String, dynamic>> getMxKycStatus(String userId) async {
    final json = await _request(
      method: 'GET',
      path: '/v1/users/$userId/latam/mx/kyc/status',
    );
    return _unwrapData(json);
  }

  /// Hosted verification launch (`url`, `fields`, auto-submitting `html`) —
  /// required for Mexico KYC approval. Call after activation and whenever
  /// status is `proposed`; the JWT inside expires in ~5 minutes.
  Future<Map<String, dynamic>> getMxKycLaunch(String userId) async {
    final json = await _request(
      method: 'GET',
      path: '/v1/users/$userId/latam/mx/kyc/launch/agreements',
    );
    return _unwrapData(json);
  }

  Future<Map<String, dynamic>> startMexicoOnboarding({
    required String userId,
    required String mxnWalletAddress,
    int mxnWalletIndex = 0,
  }) {
    return _request(
      method: 'POST',
      path: '/v1/users/$userId/onboarding/start-mexico',
      body: {
        'mxnWalletAddress': mxnWalletAddress,
        'mxnWalletIndex': mxnWalletIndex,
      },
    );
  }

  /// Whether the MXN wallet still holds the retired MXNe token (`eligible`).
  Future<Map<String, dynamic>> getMxneMigrationStatus(String userId) {
    return _request(
      method: 'GET',
      path: '/v1/users/$userId/latam/mx/mxne-migration/status',
    );
  }

  /// Builds the 1:1 MXNe → MEXe swap and returns its `signatureRequest`.
  /// Errors 400 when there is no MXNe to migrate.
  Future<Map<String, dynamic>> prepareMxneMigration(String userId) {
    return _request(
      method: 'POST',
      path: '/v1/users/$userId/latam/mx/mxne-migration/prepare',
    );
  }

  /// MXN offramp quote. Returns a `signatureRequest` to sign and submit via
  /// [submitSignature]. Onramps need no quote: depositing MXN to the user's
  /// CLABE (`GET …/deposit-accounts/MXN`) onramps automatically.
  Future<Map<String, dynamic>> createMxOfframpQuote({
    required String userId,
    required String sourceAmount,
    String? note,
  }) {
    return _request(
      method: 'POST',
      path: '/v1/users/$userId/latam/mx/quote',
      body: {
        'type': 'offramp',
        'sourceAmount': sourceAmount,
        if (note != null && note.isNotEmpty) 'note': note,
      },
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
  // Shared — submit a signature for any pending workflow
  // ---------------------------------------------------------------------------

  /// Completes a `signatureRequest`/`messageToSign` workflow by submitting the
  /// signature. Used by payouts, LATAM and other signed flows.
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

  /// Settlement of a submitted signature (`status`, `isTerminal`, `result` /
  /// `error`). The only way to see the MXN offramp, MXNe migration and LATAM
  /// payouts settle; poll every ~5s until `isTerminal`.
  Future<Map<String, dynamic>> getWorkflowStatus({
    required String userId,
    required String workflowId,
  }) {
    return _request(
      method: 'GET',
      path: '/v1/users/$userId/wallets/workflows/$workflowId',
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
    // USD onboarding provisions a USD virtual bank account and only needs the
    // destination smart wallet id; the others bind the on-chain wallet address.
    if (currency == WalletCurrencyOption.usd) {
      return {'smartWalletId': wallet.id};
    }
    // POST /latam/mx/kyc/activate takes no request body — it submits the
    // documents already on the KYC profile to Etherfuse for review.
    if (currency == WalletCurrencyOption.mxn) {
      return const {};
    }
    if (address == null || address.trim().isEmpty) {
      throw const ExampleException(
        'Smart wallet has no on-chain address; cannot start KYC.',
      );
    }
    const walletIndex = 0;
    return switch (currency) {
      WalletCurrencyOption.usd => {'smartWalletId': wallet.id},
      WalletCurrencyOption.mxn => const {},
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
    this.isActive = false,
    this.smartAccountAddress,
    this.safeAddress,
    this.walletAddress,
    this.smartWalletId,
    this.threshold,
    this.approvalMode,
    this.pendingDeployUserOperation,
    this.deploySigningPayloadHash,
    this.createdAt,
  });

  final String id;
  final String currency;

  /// Derived display state. The proxy returns [isActive] (not a `status`
  /// string); we map it to `active` / `preparing` for the UI.
  final String status;
  final bool isActive;
  final String? smartAccountAddress;
  final String? safeAddress;

  /// The proxy's `SmartWalletDetailResponse.walletAddress` — the deployed (or
  /// counterfactual) smart-account address.
  final String? walletAddress;
  final String? smartWalletId;
  final int? threshold;
  final String? approvalMode;

  /// Present on a first wallet only while it is still being deployed; null once
  /// the smart account is live (or when an existing treasury is reused).
  final String? pendingDeployUserOperation;
  final String? deploySigningPayloadHash;
  final String? createdAt;

  factory SmartWallet.fromJson(Map<String, dynamic> json) {
    final id =
        json['id'] as String? ??
        json['smartWalletId'] as String? ??
        json['walletId'] as String? ??
        json['groupWalletId'] as String? ??
        '';
    final isActive = json['isActive'] as bool? ?? false;
    // The proxy returns `walletAddress`; older/upstream payloads used
    // `smartAccountAddress` / `safeAddress`. Treat them as the same address.
    final address =
        json['walletAddress'] as String? ??
        json['smartAccountAddress'] as String? ??
        json['safeAddress'] as String?;
    final explicitStatus = (json['status'] as String?)?.trim();
    return SmartWallet(
      id: id,
      currency: json['currency'] as String? ?? '',
      status: (explicitStatus != null && explicitStatus.isNotEmpty)
          ? explicitStatus
          : (isActive ? 'active' : 'preparing'),
      isActive: isActive,
      smartAccountAddress: json['smartAccountAddress'] as String? ?? address,
      safeAddress: json['safeAddress'] as String?,
      walletAddress: address,
      smartWalletId: json['smartWalletId'] as String?,
      threshold: json['threshold'] as int?,
      approvalMode: json['approvalMode'] as String?,
      // Defensive: the proxy types these as strings, but upstream may surface
      // the raw user-operation object — stringify rather than risk a cast throw.
      pendingDeployUserOperation: json['pendingDeployUserOperation']
          ?.toString(),
      deploySigningPayloadHash: json['deploySigningPayloadHash'] as String?,
      createdAt: json['createdAt'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'currency': currency,
    'status': status,
    'isActive': isActive,
    'smartAccountAddress': smartAccountAddress,
    'safeAddress': safeAddress,
    'walletAddress': walletAddress,
    'smartWalletId': smartWalletId,
    'threshold': threshold,
    'approvalMode': approvalMode,
    'pendingDeployUserOperation': pendingDeployUserOperation,
    'deploySigningPayloadHash': deploySigningPayloadHash,
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
  final TextEditingController _amount = TextEditingController(text: '100.00');
  List<NigerianBank> _banks = const [];
  NigerianBank? _bank;
  String? _verifiedName;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadBanks();
  }

  @override
  void dispose() {
    _accountNumber.dispose();
    _amount.dispose();
    super.dispose();
  }

  /// `GET …/bank-accounts/nigerian-banks` — the name and CBN code must be sent
  /// verbatim to verify + register, so pick them instead of typing them.
  Future<void> _loadBanks() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final banks = await widget.client.getNigerianBanks(widget.userId);
      if (!mounted) {
        return;
      }
      setState(() => _banks = banks);
    } catch (e) {
      if (mounted) {
        setState(() => _error = 'Could not load nigerian-banks: $e');
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _verify() async {
    final acct = _accountNumber.text.trim();
    final bank = _bank;
    if (acct.length != 10 || bank == null) {
      setState(
        () => _error = 'Select a bank and enter a 10-digit account number.',
      );
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _verifiedName = null;
    });
    try {
      final v = await widget.client.verifyNigerianAccount(
        userId: widget.userId,
        bankCode: bank.code,
        accountNumber: acct,
      );
      if (!mounted) {
        return;
      }
      final name = v['accountName'] ?? v['accountHolderName'];
      if (name is! String || name.trim().isEmpty) {
        setState(
          () => _error =
              'verify-nigerian-account returned no account holder name; '
              'registration needs it verbatim.',
        );
        return;
      }
      setState(() => _verifiedName = name.trim());
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
    final bank = _bank;
    final holder = _verifiedName;
    // Registration requires the exact name returned by verify, so gate on it
    // rather than letting the user type a name that will be rejected.
    if (bank == null || holder == null) {
      setState(
        () => _error =
            'Verify the account first — registration needs the '
            'exact holder name from verify-nigerian-account.',
      );
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final account = await widget.client.getOrCreateNigerianWithdrawalAccount(
        userId: widget.userId,
        body: {
          'accountNumber': _accountNumber.text.trim(),
          'bankCode': bank.code,
          'bankName': bank.name,
          'accountHolderName': holder,
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
            DropdownButtonFormField<NigerianBank>(
              initialValue: _bank,
              isExpanded: true,
              decoration: InputDecoration(
                labelText: _banks.isEmpty
                    ? 'Bank (loading nigerian-banks…)'
                    : 'Bank (name + CBN code)',
              ),
              items: [
                for (final bank in _banks)
                  DropdownMenuItem(
                    value: bank,
                    child: Text(
                      '${bank.name} · ${bank.code}',
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              onChanged: _busy
                  ? null
                  : (value) => setState(() {
                      _bank = value;
                      // The verified name belongs to the old bank + number pair.
                      _verifiedName = null;
                    }),
            ),
            TextField(
              controller: _accountNumber,
              decoration: const InputDecoration(
                labelText: 'Account number (10 digits)',
              ),
              keyboardType: TextInputType.number,
              inputFormatters: [
                FilteringTextInputFormatter.digitsOnly,
                LengthLimitingTextInputFormatter(10),
              ],
              onChanged: (_) {
                if (_verifiedName != null) {
                  setState(() => _verifiedName = null);
                }
              },
            ),
            TextField(
              controller: _amount,
              decoration: const InputDecoration(
                labelText: 'Amount to offramp (decimal, e.g. 100.00)',
              ),
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              _verifiedName != null
                  ? 'Verified holder: $_verifiedName'
                  : 'Verify to fetch the exact account holder name — '
                        'registration requires it verbatim.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
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
          onPressed: _busy || _verifiedName == null ? null : _submit,
          child: const Text('Save payout & offramp'),
        ),
      ],
    );
  }
}

/// Fetches the Mexico hosted-verification launch payload, shows it in
/// [HostedVerificationPage], and returns the KYC status once the user closes it.
/// The payload's JWT lasts ~5 minutes, so it is fetched right before opening.
Future<Map<String, dynamic>> openMxHostedVerification({
  required BuildContext context,
  required ProxyApiClient client,
  required String userId,
}) async {
  final launch = await client.getMxKycLaunch(userId);
  final html = launch['html'];
  if (html is! String || html.trim().isEmpty) {
    throw const ExampleException(
      'The verification launch payload has no html.',
    );
  }
  if (!context.mounted) {
    return launch;
  }
  await Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => HostedVerificationPage(
        html: html,
        providerHost: Uri.tryParse(launch['url']?.toString() ?? '')?.host,
      ),
    ),
  );
  return client.getMxKycStatus(userId);
}

/// Whether [host] is on the same site as [provider]. Missing hosts never match.
// ponytail: same site = same last two host labels, which covers the provider's
// subdomains; use a public-suffix list if it ever runs on a ccTLD like .com.mx.
bool isSameSite(String? host, String? provider) {
  if (host == null || host.isEmpty || provider == null || provider.isEmpty) {
    return false;
  }
  String site(String h) =>
      h.toLowerCase().split('.').reversed.take(2).join('.');
  return site(host) == site(provider);
}

/// The provider's hosted Mexico verification (agreements, email confirmation,
/// selfie / liveness, any remaining document). [html] is the auto-submitting
/// form from `GET …/latam/mx/kyc/launch/agreements`, loaded as-is.
class HostedVerificationPage extends StatefulWidget {
  const HostedVerificationPage({
    super.key,
    required this.html,
    this.providerHost,
  });

  final String html;

  /// Host of the launch `url`. Pages on that site get camera / microphone
  /// without asking; any other site (e.g. a vendor the provider hands off to)
  /// needs the user's explicit OK.
  final String? providerHost;

  @override
  State<HostedVerificationPage> createState() => _HostedVerificationPageState();
}

class _HostedVerificationPageState extends State<HostedVerificationPage> {
  late final WebViewController _controller;
  int _progress = 0;
  String? _error;

  @override
  void initState() {
    super.initState();
    // Liveness plays the camera feed inline; WKWebView needs that allowed up
    // front.
    final params = WebViewPlatform.instance is WebKitWebViewPlatform
        ? WebKitWebViewControllerCreationParams(
            allowsInlineMediaPlayback: true,
            mediaTypesRequiringUserAction: const {},
          )
        : const PlatformWebViewControllerCreationParams();
    _controller =
        WebViewController.fromPlatformCreationParams(
            params,
            onPermissionRequest: _onPermissionRequest,
          )
          ..setJavaScriptMode(JavaScriptMode.unrestricted)
          ..setNavigationDelegate(
            NavigationDelegate(
              onProgress: (progress) {
                if (mounted) {
                  setState(() => _progress = progress);
                }
              },
              onWebResourceError: (error) {
                if (mounted && (error.isForMainFrame ?? true)) {
                  setState(() => _error = error.description);
                }
              },
            ),
          )
          ..loadHtmlString(widget.html);
    final platform = _controller.platform;
    if (platform is AndroidWebViewController) {
      platform
        ..setMediaPlaybackRequiresUserGesture(false)
        // Android's WebView ignores <input type=file> unless the app answers.
        ..setOnShowFileSelector(_pickFiles);
    }
  }

  /// Camera / microphone for liveness. iOS shows its own prompt (from the
  /// NS*UsageDescription keys); Android needs the app-level runtime permission
  /// first, or the page's getUserMedia fails even when granted here.
  Future<void> _onPermissionRequest(WebViewPermissionRequest request) async {
    const mediaToPermission = {
      WebViewPermissionResourceType.camera: Permission.camera,
      WebViewPermissionResourceType.microphone: Permission.microphone,
    };
    if (!request.types.every(mediaToPermission.containsKey)) {
      await request.deny();
      return;
    }
    final pageHost = Uri.tryParse(await _controller.currentUrl() ?? '')?.host;
    if (!isSameSite(pageHost, widget.providerHost) &&
        !await _confirmOffSiteMedia(pageHost)) {
      await request.deny();
      return;
    }
    if (Platform.isAndroid) {
      final statuses = await [
        for (final type in request.types) mediaToPermission[type]!,
      ].request();
      if (!statuses.values.every((status) => status.isGranted)) {
        await request.deny();
        return;
      }
    }
    await request.grant();
  }

  Future<bool> _confirmOffSiteMedia(String? host) async {
    if (!mounted) {
      return false;
    }
    final allowed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Allow camera access?'),
        content: Text(
          '${host == null || host.isEmpty ? 'This page' : host} is asking to '
          'use your camera. It is not the verification provider.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text("Don't allow"),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Allow'),
          ),
        ],
      ),
    );
    return allowed ?? false;
  }

  // ponytail: images only, via the image_picker already used for KYC uploads.
  // Add file_picker if the provider starts asking for PDFs here.
  Future<List<String>> _pickFiles(FileSelectorParams params) async {
    final picker = ImagePicker();
    if (params.mode == FileSelectorMode.openMultiple &&
        !params.isCaptureEnabled) {
      final files = await picker.pickMultiImage();
      return [for (final f in files) Uri.file(f.path).toString()];
    }
    final file = await picker.pickImage(
      source: params.isCaptureEnabled
          ? ImageSource.camera
          : ImageSource.gallery,
    );
    return file == null ? const [] : [Uri.file(file.path).toString()];
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Identity verification')),
      body: Column(
        children: [
          if (_progress < 100) LinearProgressIndicator(value: _progress / 100),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                'Could not load the verification page: $_error',
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          Expanded(child: WebViewWidget(controller: _controller)),
        ],
      ),
    );
  }
}

/// Demonstrates the regional / provider integrations that are not part of the
/// core onboarding + top-up + withdraw + swap home flow: swap quote (#63),
/// EU SEPA (#64), LATAM cash (#65), LATAM Mexico (#66), US VBA (#67) and
/// bank payouts (#68).
///
/// Each action calls the proxy directly and dumps the raw JSON response.
/// Flows that return a `signatureRequest` (or `messageToSign`) expose a
/// "Sign & submit" button that signs `hashToSign` with
/// [BmoniEmbeddedSdk.signTransactionHash] and completes via the matching
/// endpoint (`eu/orders/complete` for EU, `wallets/submit-signature` otherwise),
/// then settlement is polled via `GET wallets/workflows/{workflowId}`.
class _IntegrationsPage extends StatefulWidget {
  const _IntegrationsPage({
    required this.client,
    required this.userId,
    required this.smartWalletId,
    this.smartWalletAddress,
  });

  final ProxyApiClient client;
  final String userId;
  final String smartWalletId;
  final String? smartWalletAddress;

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

  // Settlement of the last submitted signature
  final _workflowId = TextEditingController();

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
  final _fxUsdcAmount = TextEditingController(text: '25');
  final _fxCountry = TextEditingController(text: 'MX');
  final _fxCurrency = TextEditingController(text: 'MXN');

  // LATAM Mexico (#66)
  final _mxAmount = TextEditingController(text: '500');
  final _mxOrderId = TextEditingController();

  // Payouts (#68)
  final _poCountry = TextEditingController(text: 'NGA');
  final _poCurrency = TextEditingController(text: 'NGN');
  final _poBankId = TextEditingController();
  final _poAccountNumber = TextEditingController();
  final _poAccountHolder = TextEditingController();
  final _poAmount = TextEditingController(text: '1000');

  @override
  void dispose() {
    for (final c in [
      _workflowId,
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
      _fxUsdcAmount,
      _fxCountry,
      _fxCurrency,
      _mxAmount,
      _mxOrderId,
      _poCountry,
      _poCurrency,
      _poBankId,
      _poAccountNumber,
      _poAccountHolder,
      _poAmount,
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

  /// [_capturePending] for flows completed via `wallets/submit-signature`.
  void _captureForSubmit(Map<String, dynamic> json, String label) {
    _capturePending(
      json: json,
      label: label,
      complete: (signature) => widget.client.submitSignature(
        userId: _userId,
        workflowId:
            (json['signatureRequest'] as Map?)?['workflowId']?.toString() ?? '',
        signature: signature,
      ),
    );
  }

  Future<void> _signAndSubmit() async {
    final hash = _pendingHash;
    final complete = _pendingComplete;
    final workflowId = _pendingWorkflowId;
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
        // Pre-fill the settlement check with the workflow just submitted.
        if (workflowId != null) {
          _workflowId.text = workflowId;
        }
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
            _buildWorkflowSection(),
            _buildSwapSection(),
            _buildUsVbaSection(),
            _buildEuSection(),
            _buildLatamCashSection(),
            _buildLatamMxSection(),
            _buildPayoutsSection(),
            if (_error != null)
              _SectionCard(
                title: 'Error',
                child: Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
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

  Widget _buildWorkflowSection() {
    return _SectionCard(
      title: 'Workflow settlement',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'After Sign & submit, poll until isTerminal: COMPLETED carries '
            'result, any other terminal status carries error.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          _TextInput(controller: _workflowId, label: 'Workflow id'),
          const SizedBox(height: 8),
          OutlinedButton(
            onPressed: _busy
                ? null
                : () => _run(
                    () => widget.client.getWorkflowStatus(
                      userId: _userId,
                      workflowId: _workflowId.text.trim(),
                    ),
                  ),
            child: const Text('GET workflow status'),
          ),
        ],
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
      title: 'USD virtual bank account',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Readiness (GET /kyc/usd-readiness) → provision '
            '(POST /onboarding/start-usa, or the smart-wallet route '
            '…/onramp/vba/usd/provision) → status (GET /vba/usd).',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton(
                onPressed: _busy
                    ? null
                    : () => _run(() => widget.client.getUsdReadiness(_userId)),
                child: const Text('Readiness'),
              ),
              FilledButton(
                onPressed: _busy
                    ? null
                    : () => _run(
                        () => widget.client.startUsaOnboarding(
                          userId: _userId,
                          smartWalletId: _walletId,
                        ),
                      ),
                child: const Text('Provision'),
              ),
              OutlinedButton(
                onPressed: _busy
                    ? null
                    : () => _run(
                        () => widget.client.provisionSmartWalletUsdVba(
                          userId: _userId,
                          smartWalletId: _walletId,
                        ),
                      ),
                child: const Text('Provision (wallet route)'),
              ),
              OutlinedButton(
                onPressed: _busy
                    ? null
                    : () => _run(() => widget.client.getUsdVba(_userId)),
                child: const Text('GET vba'),
              ),
            ],
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
                          complete: (signature) =>
                              widget.client.submitSignature(
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
          const Divider(height: 24),
          Text(
            'Bank payout (USD → MXN / CLP / COP): swaps this wallet into USDC '
            'and pays the equivalent fiat. No sender-side Mexico KYC; settles '
            'through the workflow, with no order record.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          _TextInput(
            controller: _fxUsdcAmount,
            label: 'USDC amount',
            keyboardType: TextInputType.number,
          ),
          const SizedBox(height: 12),
          _TwoColumnFields(
            first: _TextInput(
              controller: _fxCountry,
              label: 'Target country (alpha-2)',
            ),
            second: _TextInput(
              controller: _fxCurrency,
              label: 'Target currency',
            ),
          ),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: _busy
                ? null
                : () => _run(() async {
                    final res = await widget.client.createLatamForeignPayout(
                      userId: _userId,
                      smartWalletId: _walletId,
                      usdcAmount: _fxUsdcAmount.text.trim(),
                      targetCountry: _fxCountry.text.trim().toUpperCase(),
                      targetCurrency: _fxCurrency.text.trim().toUpperCase(),
                      description: _cashDescription.text.trim(),
                    );
                    _captureForSubmit(res, 'LATAM bank payout');
                    return res;
                  }),
            child: const Text('POST payouts/foreign'),
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
              OutlinedButton(
                onPressed: _busy
                    ? null
                    : () => _run(
                        () => openMxHostedVerification(
                          context: context,
                          client: widget.client,
                          userId: _userId,
                        ),
                      ),
                child: const Text('Launch verification'),
              ),
              OutlinedButton(
                onPressed: _busy
                    ? null
                    : () => _run(() {
                        final address = widget.smartWalletAddress?.trim();
                        if (address == null || address.isEmpty) {
                          throw const ExampleException(
                            'Smart wallet has no on-chain address.',
                          );
                        }
                        return widget.client.startMexicoOnboarding(
                          userId: _userId,
                          mxnWalletAddress: address,
                        );
                      }),
                child: const Text('Start Mexico onboarding'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'While status is proposed, the user must finish the hosted '
            'verification. Launch opens it in a WebView and shows the status '
            'once it is closed.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const Divider(height: 24),
          Text(
            'Onramp is deposit-driven: MXN sent by SPEI to your CLABE '
            '(GET …/deposit-accounts/MXN) credits the wallet with no quote.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          _TextInput(
            controller: _mxAmount,
            label: 'Offramp source amount',
            keyboardType: TextInputType.number,
          ),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: _busy
                ? null
                : () => _run(() async {
                    final res = await widget.client.createMxOfframpQuote(
                      userId: _userId,
                      sourceAmount: _mxAmount.text.trim(),
                    );
                    // The quote carries a signatureRequest to fund the swap.
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
            child: const Text('POST offramp quote'),
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
          const Divider(height: 24),
          Text(
            'Legacy MXNe → MEXe: if status reports eligible, prepare the 1:1 '
            'swap (no fee) and sign it.',
            style: Theme.of(context).textTheme.bodySmall,
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
                        () => widget.client.getMxneMigrationStatus(_userId),
                      ),
                child: const Text('Migration status'),
              ),
              FilledButton(
                onPressed: _busy
                    ? null
                    : () => _run(() async {
                        final res = await widget.client.prepareMxneMigration(
                          _userId,
                        );
                        _captureForSubmit(res, 'MXNe → MEXe migration');
                        return res;
                      }),
                child: const Text('Prepare migration'),
              ),
            ],
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
                          complete: (signature) =>
                              widget.client.submitSignature(
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
