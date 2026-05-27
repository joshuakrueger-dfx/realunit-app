import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:realunit_wallet/packages/service/dfx/exceptions/api_exception.dart';
import 'package:realunit_wallet/packages/service/dfx/exceptions/bitbox_exception.dart';
import 'package:realunit_wallet/packages/service/dfx/exceptions/payment/buy_exceptions.dart';
import 'package:realunit_wallet/packages/service/dfx/models/payment/buy/buy_payment_info.dart';
import 'package:realunit_wallet/packages/service/dfx/models/payment/payment_info_error.dart';
import 'package:realunit_wallet/packages/service/dfx/real_unit_buy_payment_info_service.dart';
import 'package:realunit_wallet/screens/buy/cubits/buy_payment_info/buy_payment_info_cubit.dart';
import 'package:realunit_wallet/styles/currency.dart';

class _MockBuyPaymentInfoService extends Mock
    implements RealUnitBuyPaymentInfoService {}

BuyPaymentInfo _info({
  bool isValid = true,
  double? minVolume,
  String? error,
  Currency currency = Currency.chf,
}) => BuyPaymentInfo(
  id: 1,
  iban: 'CH56 0483 5012 3456 78',
  bic: 'CRESCHZZ80A',
  name: 'DFX AG',
  street: 'Bahnhofstrasse',
  number: '1',
  zip: '8000',
  city: 'Zurich',
  country: 'CH',
  currency: currency,
  isValid: isValid,
  minVolume: minVolume,
  error: error,
);

void main() {
  late _MockBuyPaymentInfoService service;

  setUpAll(() {
    registerFallbackValue(Currency.chf);
  });

  setUp(() {
    service = _MockBuyPaymentInfoService();
  });

  BuyPaymentInfoCubit build() => BuyPaymentInfoCubit(service);

  group('$BuyPaymentInfoCubit', () {
    test('initial state is BuyPaymentInfoInitial', () {
      expect(build().state, isA<BuyPaymentInfoInitial>());
    });

    test('happy path emits Success with the payment info from the API', () async {
      when(() => service.getPaymentInfo(any(), currency: any(named: 'currency')))
          .thenAnswer((_) async => _info());

      final cubit = build();
      await cubit.getPaymentInfo(amount: '300');

      expect(cubit.state, isA<BuyPaymentInfoSuccess>());
      verify(() => service.getPaymentInfo(300, currency: Currency.chf)).called(1);
    });

    test('API isValid=false with error=AmountTooLow → MinAmountNotMetFailure with API limit', () async {
      when(() => service.getPaymentInfo(any(), currency: any(named: 'currency')))
          .thenAnswer((_) async => _info(isValid: false, error: 'AmountTooLow', minVolume: 100));

      final cubit = build();
      await cubit.getPaymentInfo(amount: '50');

      expect(cubit.state, isA<BuyPaymentInfoMinAmountNotMetFailure>());
      final f = cubit.state as BuyPaymentInfoMinAmountNotMetFailure;
      expect(f.error, PaymentInfoError.minAmountNotMet);
      expect(f.minAmount, 100);
      verify(() => service.getPaymentInfo(50, currency: Currency.chf)).called(1);
    });

    test('EUR min is reported by the API as-is, not scaled in the app', () async {
      // For EUR the API returns its own currency-specific minVolume; the
      // app no longer multiplies a hardcoded CHF baseline by an exchange
      // rate locally — the rate lives server-side.
      when(() => service.getPaymentInfo(any(), currency: any(named: 'currency')))
          .thenAnswer((_) async => _info(
            isValid: false,
            error: 'AmountTooLow',
            minVolume: 92,
            currency: Currency.eur,
          ));

      final cubit = build();
      await cubit.getPaymentInfo(amount: '50', currency: Currency.eur);

      final f = cubit.state as BuyPaymentInfoMinAmountNotMetFailure;
      expect(f.minAmount, 92);
      verify(() => service.getPaymentInfo(50, currency: Currency.eur)).called(1);
    });

    test('API isValid=false with unknown error → generic Failure', () async {
      when(() => service.getPaymentInfo(any(), currency: any(named: 'currency')))
          .thenAnswer((_) async => _info(isValid: false, error: 'AmountTooHigh', minVolume: 100));

      final cubit = build();
      await cubit.getPaymentInfo(amount: '999999999');

      expect(cubit.state, isA<BuyPaymentInfoFailure>());
      expect((cubit.state as BuyPaymentInfoFailure).error, PaymentInfoError.unknown);
    });

    test('empty amount string is treated as 0 → still calls the API', () async {
      when(() => service.getPaymentInfo(any(), currency: any(named: 'currency')))
          .thenAnswer((_) async => _info(isValid: false, error: 'AmountTooLow', minVolume: 100));

      final cubit = build();
      await cubit.getPaymentInfo(amount: '');

      expect(cubit.state, isA<BuyPaymentInfoMinAmountNotMetFailure>());
      verify(() => service.getPaymentInfo(0, currency: Currency.chf)).called(1);
    });

    test('comma decimal separator is normalised to dot', () async {
      when(() => service.getPaymentInfo(any(), currency: any(named: 'currency')))
          .thenAnswer((_) async => _info());

      final cubit = build();
      await cubit.getPaymentInfo(amount: '300,75');

      // 300.75 rounded to 301.
      verify(() => service.getPaymentInfo(301, currency: Currency.chf)).called(1);
    });

    test('KycLevelRequiredException → Failure(kycRequired, requiredLevel)', () async {
      when(() => service.getPaymentInfo(any(), currency: any(named: 'currency')))
          .thenAnswer(
        (_) async => throw const KycLevelRequiredException(
          statusCode: 403,
          code: 'KYC_REQUIRED',
          message: 'KYC required',
          requiredLevel: 30,
          currentLevel: 10,
        ),
      );

      final cubit = build();
      await cubit.getPaymentInfo(amount: '300');

      final f = cubit.state as BuyPaymentInfoFailure;
      expect(f.error, PaymentInfoError.kycRequired);
      expect(f.requiredLevel, 30);
    });

    test('RegistrationRequiredException → Failure(registrationRequired)', () async {
      when(() => service.getPaymentInfo(any(), currency: any(named: 'currency')))
          .thenAnswer(
        (_) async => throw const RegistrationRequiredException(
          statusCode: 403,
          code: 'REGISTRATION_REQUIRED',
          message: 'Sign first',
        ),
      );

      final cubit = build();
      await cubit.getPaymentInfo(amount: '300');

      final f = cubit.state as BuyPaymentInfoFailure;
      expect(f.error, PaymentInfoError.registrationRequired);
    });

    test('generic exception → Failure(unknown)', () async {
      when(() => service.getPaymentInfo(any(), currency: any(named: 'currency')))
          .thenAnswer((_) async => throw Exception('network'));

      final cubit = build();
      await cubit.getPaymentInfo(amount: '300');

      final f = cubit.state as BuyPaymentInfoFailure;
      expect(f.error, PaymentInfoError.unknown);
    });

    test('plain 403 ApiException (code UNKNOWN) → Failure(unknown), NOT registrationRequired',
        () async {
      // Regression guard: the backend returns a *structured*
      // RegistrationRequiredException when a wallet genuinely needs RealUnit
      // onboarding (see the test above). A bare 403 "Forbidden resource" with
      // no structured code is a different authorization denial (account/role
      // gating) and MUST surface as `unknown` — never be force-mapped to
      // `registrationRequired`, which would dump an already-onboarded but
      // backend-blocked user into the registration/KYC flow and dead-end them
      // at "Fehler beim Laden".
      when(() => service.getPaymentInfo(any(), currency: any(named: 'currency')))
          .thenAnswer(
        (_) async => throw const ApiException(
          statusCode: 403,
          code: 'UNKNOWN',
          message: 'Forbidden resource',
        ),
      );

      final cubit = build();
      await cubit.getPaymentInfo(amount: '300');

      final f = cubit.state as BuyPaymentInfoFailure;
      expect(f.error, PaymentInfoError.unknown);
      expect(f.message, contains('Forbidden resource'));
    });

    test('BitboxNotConnectedException → Failure(bitboxDisconnected)', () async {
      when(() => service.getPaymentInfo(any(), currency: any(named: 'currency')))
          .thenAnswer((_) async => throw const BitboxNotConnectedException());

      final cubit = build();
      await cubit.getPaymentInfo(amount: '300');

      final f = cubit.state as BuyPaymentInfoFailure;
      expect(f.error, PaymentInfoError.bitboxDisconnected);
    });

    test('does not emit after close', () async {
      final completer = Completer<BuyPaymentInfo>();
      when(() => service.getPaymentInfo(any(), currency: any(named: 'currency')))
          .thenAnswer((_) => completer.future);

      final cubit = build();
      unawaited(cubit.getPaymentInfo(amount: '300'));
      await cubit.close();
      completer.complete(_info());
    });
  });
}
