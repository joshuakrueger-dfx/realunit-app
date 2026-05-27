import 'dart:convert';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:realunit_wallet/packages/service/dfx/dfx_auth_service.dart';
import 'package:realunit_wallet/packages/service/dfx/exceptions/bitbox_exception.dart';
import 'package:realunit_wallet/packages/service/dfx/models/registration/registration_status.dart';
import 'package:realunit_wallet/packages/service/dfx/models/user/dto/real_unit_user_data_dto.dart';
import 'package:realunit_wallet/packages/service/dfx/models/registration/kyc/kyc_personal_data.dart';
import 'package:realunit_wallet/packages/service/dfx/models/wallet/real_unit_wallet_status_dto.dart';
import 'package:realunit_wallet/packages/service/dfx/real_unit_registration_service.dart';
import 'package:realunit_wallet/packages/service/dfx/real_unit_wallet_service.dart';
import 'package:realunit_wallet/packages/wallet/error_mapper.dart';
import 'package:realunit_wallet/screens/kyc/steps/email/cubits/email_verification/kyc_email_verification_cubit.dart';

class _MockAuthService extends Mock implements DFXAuthService {}

class _MockWalletService extends Mock implements RealUnitWalletService {}

class _MockRegistrationService extends Mock implements RealUnitRegistrationService {}

String _fakeJwt(int accountId) {
  final header = base64Url
      .encode(utf8.encode('{"alg":"HS256"}'))
      .replaceAll('=', '');
  final payload = base64Url
      .encode(utf8.encode('{"account":$accountId}'))
      .replaceAll('=', '');
  return '$header.$payload.signature';
}

const _kycData = KycPersonalData(
  accountType: KycAccountType.personal,
  firstName: 'A',
  lastName: 'B',
  phone: '+41',
  address: KycAddress(
    street: 'S',
    zip: '8000',
    city: 'Zurich',
    country: 41,
  ),
);

const _userData = RealUnitUserDataDto(
  email: 'a@b.com',
  name: 'A B',
  type: 'HUMAN',
  phoneNumber: '+41',
  birthday: '2000-01-01',
  nationality: 'CH',
  addressStreet: 'S',
  addressPostalCode: '8000',
  addressCity: 'Zurich',
  addressCountry: 'CH',
  swissTaxResidence: true,
  lang: 'de',
  kycData: _kycData,
);

void main() {
  late _MockAuthService auth;
  late _MockWalletService walletService;
  late _MockRegistrationService registrationService;

  setUpAll(() {
    registerFallbackValue(_userData);
  });

  setUp(() {
    auth = _MockAuthService();
    walletService = _MockWalletService();
    registrationService = _MockRegistrationService();
    when(() => auth.invalidateAuthToken()).thenReturn(null);
  });

  KycEmailVerificationCubit build({
    void Function()? onSignProduced,
    bool initialMergeDetected = false,
    int walletStatusRetries = 1,
    Duration walletStatusRetryDelay = Duration.zero,
  }) =>
      KycEmailVerificationCubit(
        dfxService: auth,
        walletService: walletService,
        registrationService: registrationService,
        onSignProduced: onSignProduced,
        initialMergeDetected: initialMergeDetected,
        walletStatusRetries: walletStatusRetries,
        walletStatusRetryDelay: walletStatusRetryDelay,
      );

  group('initial state', () {
    test('emits $KycEmailVerificationInitial', () {
      expect(build().state, isA<KycEmailVerificationInitial>());
    });
  });

  group('checkEmailVerification', () {
    blocTest<KycEmailVerificationCubit, KycEmailVerificationState>(
      'same account id before + after invalidation → Failure',
      setUp: () {
        // Both calls return the same token, so the same account id is parsed.
        when(() => auth.getAuthToken()).thenAnswer((_) async => _fakeJwt(1));
      },
      build: build,
      act: (c) => c.checkEmailVerification(),
      expect: () => [
        isA<KycEmailVerificationLoading>(),
        isA<KycEmailVerificationFailure>(),
      ],
      verify: (_) {
        verify(() => auth.invalidateAuthToken()).called(1);
        verifyNever(() => registrationService.registerWallet(any()));
      },
    );

    blocTest<KycEmailVerificationCubit, KycEmailVerificationState>(
      'changed account id + existing user data → registerWallet + Success',
      setUp: () {
        final tokens = [_fakeJwt(1), _fakeJwt(2)];
        var i = 0;
        when(() => auth.getAuthToken()).thenAnswer((_) async => tokens[i++]);
        when(() => walletService.getWalletStatus()).thenAnswer(
          (_) async => RealUnitWalletStatusDto(
            isRegistered: true,
            realUnitUserDataDto: _userData,
          ),
        );
        when(() => registrationService.registerWallet(any()))
            .thenAnswer((_) async => RegistrationStatus.completed);
      },
      build: build,
      act: (c) => c.checkEmailVerification(),
      expect: () => [
        isA<KycEmailVerificationLoading>(),
        isA<KycEmailVerificationSuccess>(),
      ],
      verify: (_) => verify(() => registrationService.registerWallet(_userData)).called(1),
    );

    blocTest<KycEmailVerificationCubit, KycEmailVerificationState>(
      'initialMergeDetected (re-entrant resume) skips the one-shot account-id '
      'check and goes straight to registerWallet → Success',
      setUp: () {
        when(() => walletService.getWalletStatus()).thenAnswer(
          (_) async => RealUnitWalletStatusDto(
            isRegistered: true,
            realUnitUserDataDto: _userData,
          ),
        );
        when(() => registrationService.registerWallet(any()))
            .thenAnswer((_) async => RegistrationStatus.completed);
      },
      build: () => build(initialMergeDetected: true),
      act: (c) => c.checkEmailVerification(),
      expect: () => [
        isA<KycEmailVerificationLoading>(),
        isA<KycEmailVerificationSuccess>(),
      ],
      verify: (_) {
        // The account-id delta is the one-shot signal that cannot be re-derived
        // after a restart — re-entrant mode must NOT call it.
        verifyNever(() => auth.getAuthToken());
        verify(() => registrationService.registerWallet(_userData)).called(1);
      },
    );

    blocTest<KycEmailVerificationCubit, KycEmailVerificationState>(
      'changed account id but no userData → RegistrationFailure, no Success '
      '(propagation race: user can retry by tapping the confirm button again)',
      setUp: () {
        final tokens = [_fakeJwt(1), _fakeJwt(2)];
        var i = 0;
        when(() => auth.getAuthToken()).thenAnswer((_) async => tokens[i++]);
        when(() => walletService.getWalletStatus()).thenAnswer(
          (_) async => RealUnitWalletStatusDto(
            isRegistered: false,
            realUnitUserDataDto: null,
          ),
        );
      },
      build: build,
      act: (c) => c.checkEmailVerification(),
      expect: () => [
        isA<KycEmailVerificationLoading>(),
        isA<KycEmailVerificationRegistrationFailure>(),
      ],
      verify: (_) {
        verifyNever(() => registrationService.registerWallet(any()));
      },
    );

    blocTest<KycEmailVerificationCubit, KycEmailVerificationState>(
      'registerWallet throws → RegistrationFailure, no Success '
      '(failure is surfaced so the user can retry instead of proceeding '
      'with a wallet that is not actually registered)',
      setUp: () {
        final tokens = [_fakeJwt(1), _fakeJwt(2)];
        var i = 0;
        when(() => auth.getAuthToken()).thenAnswer((_) async => tokens[i++]);
        when(() => walletService.getWalletStatus()).thenAnswer(
          (_) async => RealUnitWalletStatusDto(
            isRegistered: true,
            realUnitUserDataDto: _userData,
          ),
        );
        when(() => registrationService.registerWallet(any()))
            .thenAnswer((_) async => throw Exception('boom'));
      },
      build: build,
      act: (c) => c.checkEmailVerification(),
      expect: () => [
        isA<KycEmailVerificationLoading>(),
        isA<KycEmailVerificationRegistrationFailure>(),
      ],
      verify: (_) => verify(() => registrationService.registerWallet(_userData)).called(1),
    );

    blocTest<KycEmailVerificationCubit, KycEmailVerificationState>(
      'retry after null-userData race: second call skips account-id check '
      '(propagation completed → registerWallet succeeds → Success)',
      setUp: () {
        // First call: account-id changes, userData not yet propagated.
        // Second call: same account-id (already merged), userData now present.
        // Without the `_mergeDetected` short-circuit the second call would
        // hit the same-account-id guard and emit Failure ("email not yet
        // confirmed") — verifying the retry path works.
        final tokens = [_fakeJwt(1), _fakeJwt(2), _fakeJwt(2), _fakeJwt(2)];
        var i = 0;
        when(() => auth.getAuthToken()).thenAnswer((_) async => tokens[i++]);
        var walletStatusCallCount = 0;
        when(() => walletService.getWalletStatus()).thenAnswer((_) async {
          walletStatusCallCount++;
          return walletStatusCallCount == 1
              ? RealUnitWalletStatusDto(
                  isRegistered: false,
                  realUnitUserDataDto: null,
                )
              : RealUnitWalletStatusDto(
                  isRegistered: true,
                  realUnitUserDataDto: _userData,
                );
        });
        when(() => registrationService.registerWallet(any()))
            .thenAnswer((_) async => RegistrationStatus.completed);
      },
      build: build,
      act: (c) async {
        await c.checkEmailVerification();
        await c.checkEmailVerification();
      },
      expect: () => [
        isA<KycEmailVerificationLoading>(),
        isA<KycEmailVerificationRegistrationFailure>(),
        isA<KycEmailVerificationLoading>(),
        isA<KycEmailVerificationSuccess>(),
      ],
      verify: (_) {
        verify(() => registrationService.registerWallet(_userData)).called(1);
      },
    );
  });

  group('BL-006: BitBox disconnect mid-sign routes to BitboxRequired', () {
    blocTest<KycEmailVerificationCubit, KycEmailVerificationState>(
      'registerWallet throws BitboxNotConnectedException → '
      'KycEmailVerificationBitboxRequired (legacy exception path)',
      setUp: () {
        final tokens = [_fakeJwt(1), _fakeJwt(2)];
        var i = 0;
        when(() => auth.getAuthToken()).thenAnswer((_) async => tokens[i++]);
        when(() => walletService.getWalletStatus()).thenAnswer(
          (_) async => RealUnitWalletStatusDto(
            isRegistered: true,
            realUnitUserDataDto: _userData,
          ),
        );
        when(() => registrationService.registerWallet(any())).thenAnswer(
          (_) async => throw const BitboxNotConnectedException(),
        );
      },
      build: build,
      act: (c) => c.checkEmailVerification(),
      expect: () => [
        isA<KycEmailVerificationLoading>(),
        isA<KycEmailVerificationBitboxRequired>(),
      ],
      verify: (_) =>
          verify(() => registrationService.registerWallet(_userData)).called(1),
    );

    blocTest<KycEmailVerificationCubit, KycEmailVerificationState>(
      'registerWallet throws BitboxNotConnectedSignException → '
      'KycEmailVerificationBitboxRequired (typed pipeline path)',
      setUp: () {
        final tokens = [_fakeJwt(1), _fakeJwt(2)];
        var i = 0;
        when(() => auth.getAuthToken()).thenAnswer((_) async => tokens[i++]);
        when(() => walletService.getWalletStatus()).thenAnswer(
          (_) async => RealUnitWalletStatusDto(
            isRegistered: true,
            realUnitUserDataDto: _userData,
          ),
        );
        when(() => registrationService.registerWallet(any())).thenAnswer(
          (_) async => throw const BitboxNotConnectedSignException(),
        );
      },
      build: build,
      act: (c) => c.checkEmailVerification(),
      expect: () => [
        isA<KycEmailVerificationLoading>(),
        isA<KycEmailVerificationBitboxRequired>(),
      ],
      verify: (_) =>
          verify(() => registrationService.registerWallet(_userData)).called(1),
    );

    blocTest<KycEmailVerificationCubit, KycEmailVerificationState>(
      'reconnect after BitboxNotConnected → second call re-runs the JWT '
      'account-id check (latch reset). Without the reset, the second call '
      'would skip the auth-side step and emit Failure on the same-account-id '
      'guard.',
      setUp: () {
        // First call: account changes 1→2, sign fails with BitBox disconnect.
        // Second call (after reconnect): user re-taps; expects the auth-side
        // check to run AGAIN. We feed (2, 2) so the same-account-id guard
        // would emit Failure if the latch were NOT reset; the test asserts
        // the latch DID reset by observing Failure (not Success) on the
        // retry — proving the merge-detected short-circuit is gone.
        final tokens = [_fakeJwt(1), _fakeJwt(2), _fakeJwt(2), _fakeJwt(2)];
        var i = 0;
        when(() => auth.getAuthToken()).thenAnswer((_) async => tokens[i++]);
        when(() => walletService.getWalletStatus()).thenAnswer(
          (_) async => RealUnitWalletStatusDto(
            isRegistered: true,
            realUnitUserDataDto: _userData,
          ),
        );
        var registerCallCount = 0;
        when(() => registrationService.registerWallet(any())).thenAnswer(
          (_) async {
            registerCallCount++;
            if (registerCallCount == 1) {
              throw const BitboxNotConnectedException();
            }
            return RegistrationStatus.completed;
          },
        );
      },
      build: build,
      act: (c) async {
        await c.checkEmailVerification();
        await c.checkEmailVerification();
      },
      expect: () => [
        isA<KycEmailVerificationLoading>(),
        isA<KycEmailVerificationBitboxRequired>(),
        isA<KycEmailVerificationLoading>(),
        // Latch reset means the second call hits the same-account-id
        // guard and emits Failure (token compare: 2 == 2) rather than
        // proceeding straight to registerWallet on the stale latch.
        // BL-006 invariant pinned: the auth-side check IS re-run.
        isA<KycEmailVerificationFailure>(),
      ],
    );
  });

  group('BL-006: sign-gate flips from inside the cubit on success', () {
    blocTest<KycEmailVerificationCubit, KycEmailVerificationState>(
      'on Success → onSignProduced callback is invoked',
      setUp: () {
        final tokens = [_fakeJwt(1), _fakeJwt(2)];
        var i = 0;
        when(() => auth.getAuthToken()).thenAnswer((_) async => tokens[i++]);
        when(() => walletService.getWalletStatus()).thenAnswer(
          (_) async => RealUnitWalletStatusDto(
            isRegistered: true,
            realUnitUserDataDto: _userData,
          ),
        );
        when(() => registrationService.registerWallet(any()))
            .thenAnswer((_) async => RegistrationStatus.completed);
      },
      build: () {
        var callCount = 0;
        final cubit = build(onSignProduced: () => callCount++);
        // Stash the callback's invocation count on the cubit via a
        // sentinel state-listener so the verify block can assert it.
        addTearDown(() {
          expect(callCount, 1, reason: 'sign-gate flip must fire exactly once on Success');
        });
        return cubit;
      },
      act: (c) => c.checkEmailVerification(),
      expect: () => [
        isA<KycEmailVerificationLoading>(),
        isA<KycEmailVerificationSuccess>(),
      ],
    );

    blocTest<KycEmailVerificationCubit, KycEmailVerificationState>(
      'on RegistrationFailure → onSignProduced is NOT invoked',
      setUp: () {
        final tokens = [_fakeJwt(1), _fakeJwt(2)];
        var i = 0;
        when(() => auth.getAuthToken()).thenAnswer((_) async => tokens[i++]);
        when(() => walletService.getWalletStatus()).thenAnswer(
          (_) async => RealUnitWalletStatusDto(
            isRegistered: true,
            realUnitUserDataDto: _userData,
          ),
        );
        when(() => registrationService.registerWallet(any()))
            .thenAnswer((_) async => throw Exception('boom'));
      },
      build: () {
        var callCount = 0;
        final cubit = build(onSignProduced: () => callCount++);
        addTearDown(() {
          expect(
            callCount,
            0,
            reason: 'sign-gate must NOT flip if registerWallet failed',
          );
        });
        return cubit;
      },
      act: (c) => c.checkEmailVerification(),
      expect: () => [
        isA<KycEmailVerificationLoading>(),
        isA<KycEmailVerificationRegistrationFailure>(),
      ],
    );

    blocTest<KycEmailVerificationCubit, KycEmailVerificationState>(
      'on BitboxRequired → onSignProduced is NOT invoked',
      setUp: () {
        final tokens = [_fakeJwt(1), _fakeJwt(2)];
        var i = 0;
        when(() => auth.getAuthToken()).thenAnswer((_) async => tokens[i++]);
        when(() => walletService.getWalletStatus()).thenAnswer(
          (_) async => RealUnitWalletStatusDto(
            isRegistered: true,
            realUnitUserDataDto: _userData,
          ),
        );
        when(() => registrationService.registerWallet(any())).thenAnswer(
          (_) async => throw const BitboxNotConnectedException(),
        );
      },
      build: () {
        var callCount = 0;
        final cubit = build(onSignProduced: () => callCount++);
        addTearDown(() {
          expect(
            callCount,
            0,
            reason: 'sign-gate must NOT flip on a BitBox disconnect',
          );
        });
        return cubit;
      },
      act: (c) => c.checkEmailVerification(),
      expect: () => [
        isA<KycEmailVerificationLoading>(),
        isA<KycEmailVerificationBitboxRequired>(),
      ],
    );
  });

  group('getAccountId', () {
    test('returns null when there is no token', () async {
      when(() => auth.getAuthToken()).thenAnswer((_) async => null);

      expect(await build().getAccountId(), isNull);
    });

    test('returns the account claim from a valid JWT', () async {
      when(() => auth.getAuthToken()).thenAnswer((_) async => _fakeJwt(42));

      expect(await build().getAccountId(), 42);
    });
  });
}
