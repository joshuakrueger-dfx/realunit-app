import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:realunit_wallet/packages/service/app_store.dart';
import 'package:realunit_wallet/packages/service/dfx/dfx_kyc_service.dart';
import 'package:realunit_wallet/packages/service/dfx/exceptions/api_exception.dart';
import 'package:realunit_wallet/packages/service/dfx/models/kyc/dto/kyc_level_dto.dart';
import 'package:realunit_wallet/packages/service/dfx/models/kyc/dto/kyc_session_dto.dart';
import 'package:realunit_wallet/packages/service/dfx/models/kyc/dto/kyc_step_dto.dart';
import 'package:realunit_wallet/packages/service/dfx/models/kyc/kyc_level.dart';
import 'package:realunit_wallet/packages/service/dfx/models/registration/registration_email_status.dart';
import 'package:realunit_wallet/packages/service/dfx/models/registration/kyc/kyc_personal_data.dart';
import 'package:realunit_wallet/packages/service/dfx/models/user/dto/real_unit_user_data_dto.dart';
import 'package:realunit_wallet/packages/service/dfx/models/user/dto/user_dto.dart';
import 'package:realunit_wallet/packages/service/dfx/models/wallet/real_unit_registration_info_dto.dart';
import 'package:realunit_wallet/packages/service/dfx/models/wallet/real_unit_registration_state.dart';
import 'package:realunit_wallet/packages/service/dfx/real_unit_registration_service.dart';
import 'package:realunit_wallet/packages/wallet/wallet.dart';
import 'package:realunit_wallet/screens/kyc/cubits/kyc/kyc_cubit.dart';

class _MockDfxKycService extends Mock implements DfxKycService {}

class _MockRealUnitRegistrationService extends Mock implements RealUnitRegistrationService {}

class _MockAppStore extends Mock implements AppStore {}

class _MockAWallet extends Mock implements AWallet {}

UserKycDto _kycHeader({KycLevel level = KycLevel.level0}) =>
    UserKycDto(hash: 'h', level: level, dataComplete: false);

UserDto _user({
  String? mail = 'test@example.com',
  KycLevel headerLevel = KycLevel.level0,
}) => UserDto(
  mail: mail,
  kyc: _kycHeader(level: headerLevel),
);

KycStepDto _step(
  KycStepName name, {
  KycStepStatus status = KycStepStatus.notStarted,
  KycStepReason? reason,
  bool isCurrent = false,
  bool isRequired = false,
  int sequenceNumber = 0,
}) => KycStepDto(
  name: name,
  status: status,
  reason: reason,
  sequenceNumber: sequenceNumber,
  isCurrent: isCurrent,
  isRequired: isRequired,
);

KycLevelDto _kycStatus({
  required KycLevel level,
  List<KycStepDto> steps = const [],
  KycProcessStatus processStatus = KycProcessStatus.inProgress,
}) => KycLevelDto(kycLevel: level, kycSteps: steps, processStatus: processStatus);

KycSessionDto _session({
  required KycLevel level,
  required List<KycStepDto> steps,
  KycStepSessionDto? currentStep,
  KycProcessStatus processStatus = KycProcessStatus.inProgress,
}) => KycSessionDto(
  kycLevel: level,
  kycSteps: steps,
  currentStep: currentStep,
  processStatus: processStatus,
);

KycStepSessionDto _currentStep(
  KycStepName name, {
  String url = 'https://example.com/session',
  UrlType urlType = UrlType.browser,
  KycStepStatus status = KycStepStatus.inProgress,
  int sequenceNumber = 0,
}) => KycStepSessionDto(
  session: KycSessionInfoDto(url: url, type: urlType),
  name: name,
  status: status,
  sequenceNumber: sequenceNumber,
  isCurrent: true,
);

RealUnitRegistrationInfoDto _walletStatus(
  RealUnitRegistrationState state, {
  RealUnitUserDataDto? userData,
}) => RealUnitRegistrationInfoDto(state: state, realUnitUserDataDto: userData);

const _kycPersonalData = KycPersonalData(
  accountType: KycAccountType.personal,
  firstName: 'Ada',
  lastName: 'Lovelace',
  phone: '+41790000000',
  address: KycAddress(street: 'S', zip: '8000', city: 'Zurich', country: 41),
);

const _fixtureUserData = RealUnitUserDataDto(
  email: 'ada@example.com',
  name: 'Ada Lovelace',
  type: 'HUMAN',
  phoneNumber: '+41790000000',
  birthday: '1815-12-10',
  nationality: 'CH',
  addressStreet: 'S',
  addressPostalCode: '8000',
  addressCity: 'Zurich',
  addressCountry: 'CH',
  swissTaxResidence: true,
  lang: 'de',
  kycData: _kycPersonalData,
);

void main() {
  late DfxKycService kycService;
  late RealUnitRegistrationService registrationService;
  late AppStore appStore;
  late AWallet wallet;

  setUp(() {
    kycService = _MockDfxKycService();
    registrationService = _MockRealUnitRegistrationService();
    appStore = _MockAppStore();
    wallet = _MockAWallet();
    when(() => appStore.wallet).thenReturn(wallet);
    // Default: software wallet — most tests don't care about the signing
    // capability gate.
    when(() => wallet.walletType).thenReturn(WalletType.software);
    // Default: AlreadyRegistered — most tests don't care about the wallet
    // status branch and want to fall through to the processStatus dispatch.
    when(() => registrationService.getRegistrationInfo()).thenAnswer(
      (_) async => _walletStatus(RealUnitRegistrationState.alreadyRegistered),
    );
  });

  KycCubit buildCubit() => KycCubit(kycService, registrationService, appStore);

  group('$KycCubit checkKyc', () {
    blocTest<KycCubit, KycState>(
      'emits KycSuccess(email) when user has no email',
      setUp: () {
        when(() => kycService.getKycStatus()).thenAnswer(
          (_) async => _kycStatus(level: KycLevel.level0),
        );
        when(() => kycService.getUser()).thenAnswer((_) async => _user(mail: null));
      },
      build: buildCubit,
      act: (cubit) => cubit.checkKyc(),
      expect: () => [
        const KycLoading(),
        const KycSuccess(currentStep: KycStep.email),
      ],
    );

    blocTest<KycCubit, KycState>(
      'auto-registers email when mail exists but level < 10, then recurses',
      setUp: () {
        when(() => kycService.getKycStatus()).thenAnswer(
          (_) async => _kycStatus(level: KycLevel.level0),
        );
        when(() => kycService.getUser()).thenAnswer((_) async => _user());
        when(() => registrationService.registerEmail(any())).thenAnswer(
          (_) async => RegistrationEmailStatus.emailRegistered,
        );
      },
      build: buildCubit,
      act: (cubit) => cubit.checkKyc(),
      expect: () => [
        const KycLoading(),
        const KycSuccess(currentStep: KycStep.email),
      ],
      verify: (_) {
        verify(() => registrationService.registerEmail('test@example.com')).called(1);
      },
    );

    blocTest<KycCubit, KycState>(
      'emits KycSuccess(legalDisclaimer) when disclaimer not yet accepted',
      setUp: () {
        when(() => kycService.getKycStatus()).thenAnswer(
          (_) async => _kycStatus(level: KycLevel.level20),
        );
        when(() => kycService.getUser()).thenAnswer((_) async => _user());
      },
      build: buildCubit,
      act: (cubit) => cubit.checkKyc(),
      expect: () => [
        const KycLoading(),
        const KycSuccess(currentStep: KycStep.legalDisclaimer),
      ],
    );

    // Wave 3 — server-side registration state drives routing. The cubit
    // re-fetches `getRegistrationInfo()` after the disclaimer gate and dispatches
    // on its `state` field, with no local sign-produced flag. The DTO that
    // came back from `getRegistrationInfo` is forwarded on the emitted state so
    // downstream pages do not have to re-fetch.
    blocTest<KycCubit, KycState>(
      'emits KycSuccess(registration) with propagated userData when wallet status reports NewRegistration',
      setUp: () {
        when(() => kycService.getKycStatus()).thenAnswer(
          (_) async => _kycStatus(level: KycLevel.level20),
        );
        when(() => kycService.getUser()).thenAnswer((_) async => _user());
        when(() => registrationService.getRegistrationInfo()).thenAnswer(
          (_) async => _walletStatus(
            RealUnitRegistrationState.newRegistration,
            userData: _fixtureUserData,
          ),
        );
      },
      build: buildCubit,
      act: (cubit) async {
        cubit.markLegalDisclaimerAccepted();
        await cubit.checkKyc();
      },
      expect: () => [
        const KycLoading(),
        const KycSuccess(
          currentStep: KycStep.registration,
          realUnitUserData: _fixtureUserData,
        ),
      ],
    );

    blocTest<KycCubit, KycState>(
      'emits KycSuccess(registration) with null userData when the server omits it',
      setUp: () {
        when(() => kycService.getKycStatus()).thenAnswer(
          (_) async => _kycStatus(level: KycLevel.level20),
        );
        when(() => kycService.getUser()).thenAnswer((_) async => _user());
        when(() => registrationService.getRegistrationInfo()).thenAnswer(
          (_) async => _walletStatus(RealUnitRegistrationState.newRegistration),
        );
      },
      build: buildCubit,
      act: (cubit) async {
        cubit.markLegalDisclaimerAccepted();
        await cubit.checkKyc();
      },
      expect: () => [
        const KycLoading(),
        const KycSuccess(currentStep: KycStep.registration),
      ],
    );

    blocTest<KycCubit, KycState>(
      'emits KycSuccess(linkWallet) with propagated userData when wallet status reports AddWallet',
      setUp: () {
        when(() => kycService.getKycStatus()).thenAnswer(
          (_) async => _kycStatus(level: KycLevel.level20),
        );
        when(() => kycService.getUser()).thenAnswer((_) async => _user());
        when(() => registrationService.getRegistrationInfo()).thenAnswer(
          (_) async => _walletStatus(
            RealUnitRegistrationState.addWallet,
            userData: _fixtureUserData,
          ),
        );
      },
      build: buildCubit,
      act: (cubit) async {
        cubit.markLegalDisclaimerAccepted();
        await cubit.checkKyc();
      },
      expect: () => [
        const KycLoading(),
        const KycSuccess(
          currentStep: KycStep.linkWallet,
          realUnitUserData: _fixtureUserData,
        ),
      ],
    );

    // `KycRequired` gets its own dedicated state so the failure page can show
    // a tailored "complete your verification" message instead of the generic
    // "step (-) cannot be completed" fallback.
    blocTest<KycCubit, KycState>(
      'emits KycRequiredFailure when wallet status reports KycRequired',
      setUp: () {
        when(() => kycService.getKycStatus()).thenAnswer(
          (_) async => _kycStatus(level: KycLevel.level20),
        );
        when(() => kycService.getUser()).thenAnswer((_) async => _user());
        when(() => registrationService.getRegistrationInfo()).thenAnswer(
          (_) async => _walletStatus(RealUnitRegistrationState.kycRequired),
        );
      },
      build: buildCubit,
      act: (cubit) async {
        cubit.markLegalDisclaimerAccepted();
        await cubit.checkKyc();
      },
      expect: () => [
        const KycLoading(),
        const KycRequiredFailure(),
      ],
    );

    // Wallet-mode signing-capability gate: the address+signature debug
    // wallet cannot produce an EIP-712 signature. The cubit must surface
    // `KycSignatureUnsupportedFailure` BEFORE emitting `KycSuccess` for any
    // state that would require signing (`NewRegistration` / `AddWallet`).
    // States that don't require signing (`AlreadyRegistered`, `KycRequired`)
    // still flow through normally.
    blocTest<KycCubit, KycState>(
      'emits KycSignatureUnsupportedFailure when debug wallet + NewRegistration',
      setUp: () {
        when(() => wallet.walletType).thenReturn(WalletType.debug);
        when(() => kycService.getKycStatus()).thenAnswer(
          (_) async => _kycStatus(level: KycLevel.level20),
        );
        when(() => kycService.getUser()).thenAnswer((_) async => _user());
        when(() => registrationService.getRegistrationInfo()).thenAnswer(
          (_) async => _walletStatus(
            RealUnitRegistrationState.newRegistration,
            userData: _fixtureUserData,
          ),
        );
      },
      build: buildCubit,
      act: (cubit) async {
        cubit.markLegalDisclaimerAccepted();
        await cubit.checkKyc();
      },
      expect: () => [
        const KycLoading(),
        const KycSignatureUnsupportedFailure(),
      ],
    );

    blocTest<KycCubit, KycState>(
      'emits KycSignatureUnsupportedFailure when debug wallet + AddWallet',
      setUp: () {
        when(() => wallet.walletType).thenReturn(WalletType.debug);
        when(() => kycService.getKycStatus()).thenAnswer(
          (_) async => _kycStatus(level: KycLevel.level20),
        );
        when(() => kycService.getUser()).thenAnswer((_) async => _user());
        when(() => registrationService.getRegistrationInfo()).thenAnswer(
          (_) async => _walletStatus(
            RealUnitRegistrationState.addWallet,
            userData: _fixtureUserData,
          ),
        );
      },
      build: buildCubit,
      act: (cubit) async {
        cubit.markLegalDisclaimerAccepted();
        await cubit.checkKyc();
      },
      expect: () => [
        const KycLoading(),
        const KycSignatureUnsupportedFailure(),
      ],
    );

    blocTest<KycCubit, KycState>(
      'debug wallet + AlreadyRegistered passes through (no signing needed)',
      setUp: () {
        when(() => wallet.walletType).thenReturn(WalletType.debug);
        when(() => kycService.getKycStatus()).thenAnswer(
          (_) async => _kycStatus(
            level: KycLevel.level50,
            processStatus: KycProcessStatus.completed,
          ),
        );
        when(() => kycService.getUser()).thenAnswer((_) async => _user());
        // Default already maps to AlreadyRegistered — make it explicit here.
        when(() => registrationService.getRegistrationInfo()).thenAnswer(
          (_) async => _walletStatus(RealUnitRegistrationState.alreadyRegistered),
        );
      },
      build: buildCubit,
      act: (cubit) async {
        cubit.markLegalDisclaimerAccepted();
        await cubit.checkKyc();
      },
      expect: () => [
        const KycLoading(),
        const KycCompleted(),
      ],
    );

    // Failure-path coverage for the wallet-status round-trip: if
    // `getRegistrationInfo()` itself throws, the outer `catch` in `_runCheckKyc`
    // must surface a `KycFailure` rather than leaking the exception through
    // the disclaimer-passed gate or wedging the state machine.
    blocTest<KycCubit, KycState>(
      'emits KycFailure when getRegistrationInfo throws',
      setUp: () {
        when(() => kycService.getKycStatus()).thenAnswer(
          (_) async => _kycStatus(level: KycLevel.level20),
        );
        when(() => kycService.getUser()).thenAnswer((_) async => _user());
        when(() => registrationService.getRegistrationInfo()).thenThrow(
          Exception('network error'),
        );
      },
      build: buildCubit,
      act: (cubit) async {
        cubit.markLegalDisclaimerAccepted();
        await cubit.checkKyc();
      },
      expect: () => [
        const KycLoading(),
        isA<KycFailure>(),
      ],
    );

    blocTest<KycCubit, KycState>(
      'emits KycAccountMergeRequested when any step carries the accountMergeRequested reason',
      setUp: () {
        when(() => kycService.getKycStatus()).thenAnswer(
          (_) async => _kycStatus(
            level: KycLevel.level20,
            steps: [
              _step(
                KycStepName.contactData,
                reason: KycStepReason.accountMergeRequested,
              ),
            ],
          ),
        );
        when(() => kycService.getUser()).thenAnswer((_) async => _user());
      },
      build: buildCubit,
      act: (cubit) async {
        cubit.markLegalDisclaimerAccepted();
        await cubit.checkKyc();
      },
      expect: () => [
        const KycLoading(),
        const KycAccountMergeRequested(),
      ],
    );

    // From here on the routing is API-driven via `processStatus` —
    // the cubit no longer iterates `kycSteps` to derive completion or
    // pendingness.
    blocTest<KycCubit, KycState>(
      'emits KycCompleted when API reports processStatus=Completed',
      setUp: () {
        when(() => kycService.getKycStatus()).thenAnswer(
          (_) async => _kycStatus(
            level: KycLevel.level50,
            processStatus: KycProcessStatus.completed,
          ),
        );
        when(() => kycService.getUser()).thenAnswer((_) async => _user());
      },
      build: buildCubit,
      act: (cubit) async {
        cubit.markLegalDisclaimerAccepted();
        await cubit.checkKyc();
      },
      expect: () => [const KycLoading(), const KycCompleted()],
    );

    blocTest<KycCubit, KycState>(
      'emits KycMergeProcessing when API reports processStatus=MergeProcessing',
      setUp: () {
        when(() => kycService.getKycStatus()).thenAnswer(
          (_) async => _kycStatus(
            level: KycLevel.level20,
            processStatus: KycProcessStatus.mergeProcessing,
          ),
        );
        when(() => kycService.getUser()).thenAnswer((_) async => _user());
      },
      build: buildCubit,
      act: (cubit) async {
        cubit.markLegalDisclaimerAccepted();
        await cubit.checkKyc();
      },
      expect: () => [const KycLoading(), const KycMergeProcessing()],
    );

    blocTest<KycCubit, KycState>(
      'emits KycPending(ident) when API reports processStatus=PendingReview and ident is the required pending step',
      setUp: () {
        when(() => kycService.getKycStatus()).thenAnswer(
          (_) async => _kycStatus(
            level: KycLevel.level50,
            processStatus: KycProcessStatus.pendingReview,
            steps: [
              _step(KycStepName.ident, status: KycStepStatus.inReview, isRequired: true),
            ],
          ),
        );
        when(() => kycService.getUser()).thenAnswer((_) async => _user());
      },
      build: buildCubit,
      act: (cubit) async {
        cubit.markLegalDisclaimerAccepted();
        await cubit.checkKyc();
      },
      expect: () => [const KycLoading(), const KycPending(KycStep.ident)],
    );

    // PendingReview is authoritative. The cubit must NEVER collapse this
    // branch to `KycCompleted` — that would be the mirror image of the
    // 2026-05-21 ident-misroute (API: review pending → app: dashboard).
    blocTest<KycCubit, KycState>(
      'emits KycUnsupportedStepFailure (not Completed) when PendingReview has no required step at all',
      setUp: () {
        when(() => kycService.getKycStatus()).thenAnswer(
          (_) async => _kycStatus(
            level: KycLevel.level50,
            processStatus: KycProcessStatus.pendingReview,
            steps: [
              _step(KycStepName.ident, status: KycStepStatus.completed),
            ],
          ),
        );
        when(() => kycService.getUser()).thenAnswer((_) async => _user());
      },
      build: buildCubit,
      act: (cubit) async {
        cubit.markLegalDisclaimerAccepted();
        await cubit.checkKyc();
      },
      expect: () => [
        const KycLoading(),
        const KycUnsupportedStepFailure(null),
      ],
    );

    // PendingReview + a required step the app cannot render (e.g.
    // additionalDocuments, residencePermit, statutes, personalData — all
    // absent from `_mapStepName`). Must surface an explicit failure with
    // the step name, never `KycCompleted`.
    blocTest<KycCubit, KycState>(
      'emits KycUnsupportedStepFailure(step) when PendingReview required step is unmapped',
      setUp: () {
        when(() => kycService.getKycStatus()).thenAnswer(
          (_) async => _kycStatus(
            level: KycLevel.level50,
            processStatus: KycProcessStatus.pendingReview,
            steps: [
              _step(
                KycStepName.additionalDocuments,
                status: KycStepStatus.inReview,
                isRequired: true,
              ),
            ],
          ),
        );
        when(() => kycService.getUser()).thenAnswer((_) async => _user());
      },
      build: buildCubit,
      act: (cubit) async {
        cubit.markLegalDisclaimerAccepted();
        await cubit.checkKyc();
      },
      expect: () => [
        const KycLoading(),
        const KycUnsupportedStepFailure(KycStepName.additionalDocuments),
      ],
    );

    blocTest<KycCubit, KycState>(
      'emits KycPending(dfxApproval) when dfxApproval is the only required step in PendingReview',
      setUp: () {
        when(() => kycService.getKycStatus()).thenAnswer(
          (_) async => _kycStatus(
            level: KycLevel.level50,
            processStatus: KycProcessStatus.pendingReview,
            steps: [
              _step(KycStepName.dfxApproval, status: KycStepStatus.inReview, isRequired: true),
            ],
          ),
        );
        when(() => kycService.getUser()).thenAnswer((_) async => _user());
      },
      build: buildCubit,
      act: (cubit) async {
        cubit.markLegalDisclaimerAccepted();
        await cubit.checkKyc();
      },
      expect: () => [const KycLoading(), const KycPending(KycStep.dfxApproval)],
    );

    blocTest<KycCubit, KycState>(
      'calls _continueKyc and emits KycSuccess(currentStep) when processStatus=InProgress',
      setUp: () {
        when(() => kycService.getKycStatus()).thenAnswer(
          (_) async => _kycStatus(
            level: KycLevel.level20,
            processStatus: KycProcessStatus.inProgress,
          ),
        );
        when(() => kycService.getUser()).thenAnswer((_) async => _user());
        when(() => kycService.continueKyc()).thenAnswer(
          (_) async => _session(
            level: KycLevel.level20,
            steps: const [],
            currentStep: _currentStep(
              KycStepName.ident,
              url: 'https://example.com/ident',
            ),
          ),
        );
      },
      build: buildCubit,
      act: (cubit) async {
        cubit.markLegalDisclaimerAccepted();
        await cubit.checkKyc();
      },
      expect: () => [
        const KycLoading(),
        const KycSuccess(
          currentStep: KycStep.ident,
          urlOrToken: 'https://example.com/ident',
        ),
      ],
    );

    blocTest<KycCubit, KycState>(
      'emits KycUnsupportedStepFailure when _continueKyc currentStep has no UI mapping',
      setUp: () {
        when(() => kycService.getKycStatus()).thenAnswer(
          (_) async => _kycStatus(
            level: KycLevel.level20,
            processStatus: KycProcessStatus.inProgress,
          ),
        );
        when(() => kycService.getUser()).thenAnswer((_) async => _user());
        when(() => kycService.continueKyc()).thenAnswer(
          (_) async => _session(
            level: KycLevel.level20,
            steps: const [],
            currentStep: _currentStep(KycStepName.personalData),
          ),
        );
      },
      build: buildCubit,
      act: (cubit) async {
        cubit.markLegalDisclaimerAccepted();
        await cubit.checkKyc();
      },
      expect: () => [
        const KycLoading(),
        const KycUnsupportedStepFailure(KycStepName.personalData),
      ],
    );

    // V45 follow-up: when the API answers `inProgress` but does not name a
    // `currentStep` we surface an explicit failure instead of throwing a
    // `StateError` from a `firstWhere`-on-empty (which used to leak as raw
    // stack-trace text into the user-facing i18n message).
    blocTest<KycCubit, KycState>(
      'emits KycUnsupportedStepFailure(null) when _continueKyc returns no currentStep',
      setUp: () {
        when(() => kycService.getKycStatus()).thenAnswer(
          (_) async => _kycStatus(
            level: KycLevel.level20,
            processStatus: KycProcessStatus.inProgress,
          ),
        );
        when(() => kycService.getUser()).thenAnswer((_) async => _user());
        when(() => kycService.continueKyc()).thenAnswer(
          (_) async => _session(
            level: KycLevel.level20,
            steps: const [],
          ),
        );
      },
      build: buildCubit,
      act: (cubit) async {
        cubit.markLegalDisclaimerAccepted();
        await cubit.checkKyc();
      },
      expect: () => [
        const KycLoading(),
        const KycUnsupportedStepFailure(null),
      ],
    );

    blocTest<KycCubit, KycState>(
      'emits KycFailure when API reports processStatus=Failed (KYC terminated)',
      setUp: () {
        when(() => kycService.getKycStatus()).thenAnswer(
          (_) async => _kycStatus(
            level: KycLevel.terminated,
            processStatus: KycProcessStatus.failed,
          ),
        );
        when(() => kycService.getUser()).thenAnswer((_) async => _user());
      },
      build: buildCubit,
      act: (cubit) async {
        cubit.markLegalDisclaimerAccepted();
        await cubit.checkKyc();
      },
      expect: () => [const KycLoading(), isA<KycFailure>()],
    );

    // `KycLevel.terminated` is internally mapped to value -10, which lands in
    // the `level < 10` auto-register branch before reaching the
    // `processStatus.failed` switch. A real `Failed` from the backend ships
    // with a non-negative level (the user got far enough for compliance to
    // terminate them). Pin that branch explicitly.
    blocTest<KycCubit, KycState>(
      'emits "KYC terminated" KycFailure when level>=10 and processStatus=Failed',
      setUp: () {
        when(() => kycService.getKycStatus()).thenAnswer(
          (_) async => _kycStatus(
            level: KycLevel.level20,
            processStatus: KycProcessStatus.failed,
          ),
        );
        when(() => kycService.getUser()).thenAnswer((_) async => _user());
      },
      build: buildCubit,
      act: (cubit) async {
        cubit.markLegalDisclaimerAccepted();
        await cubit.checkKyc();
      },
      verify: (cubit) {
        final state = cubit.state as KycFailure;
        expect(state.message, 'KYC terminated');
      },
      expect: () => [
        const KycLoading(),
        const KycFailure('KYC terminated'),
      ],
    );

    blocTest<KycCubit, KycState>(
      'returning user at completed processStatus still routes through the disclaimer first',
      setUp: () {
        when(() => kycService.getKycStatus()).thenAnswer(
          (_) async => _kycStatus(
            level: KycLevel.level50,
            processStatus: KycProcessStatus.completed,
          ),
        );
        when(() => kycService.getUser()).thenAnswer((_) async => _user());
      },
      build: buildCubit,
      act: (cubit) async {
        await cubit.checkKyc();
      },
      expect: () => [
        const KycLoading(),
        const KycSuccess(currentStep: KycStep.legalDisclaimer),
      ],
    );

    blocTest<KycCubit, KycState>(
      'does NOT route to twoFa on 403 without TFA_REQUIRED body code',
      setUp: () {
        when(() => kycService.getKycStatus()).thenThrow(
          const ApiException(statusCode: 403, code: 'FORBIDDEN', message: ''),
        );
        when(() => kycService.getUser()).thenAnswer((_) async => _user());
      },
      build: buildCubit,
      act: (cubit) => cubit.checkKyc(),
      expect: () => [
        const KycLoading(),
        isA<KycFailure>(),
      ],
    );

    blocTest<KycCubit, KycState>(
      "routes to twoFa step on ApiException(code: 'TFA_REQUIRED'), regardless of HTTP status",
      setUp: () {
        when(() => kycService.getKycStatus()).thenThrow(
          const ApiException(statusCode: 400, code: 'TFA_REQUIRED', message: ''),
        );
        when(() => kycService.getUser()).thenAnswer((_) async => _user());
      },
      build: buildCubit,
      act: (cubit) => cubit.checkKyc(),
      expect: () => [
        const KycLoading(),
        const KycSuccess(currentStep: KycStep.twoFa),
      ],
    );

    blocTest<KycCubit, KycState>(
      "routes to twoFa step on ApiException(statusCode: 403, code: 'TFA_REQUIRED')",
      setUp: () {
        when(() => kycService.getKycStatus()).thenThrow(
          const ApiException(statusCode: 403, code: 'TFA_REQUIRED', message: ''),
        );
        when(() => kycService.getUser()).thenAnswer((_) async => _user());
      },
      build: buildCubit,
      act: (cubit) => cubit.checkKyc(),
      expect: () => [
        const KycLoading(),
        const KycSuccess(currentStep: KycStep.twoFa),
      ],
    );

    blocTest<KycCubit, KycState>(
      'emits KycFailure on unrelated ApiException',
      setUp: () {
        when(() => kycService.getKycStatus()).thenThrow(
          const ApiException(statusCode: 500, code: 'SERVER_ERROR', message: 'boom'),
        );
        when(() => kycService.getUser()).thenAnswer((_) async => _user());
      },
      build: buildCubit,
      act: (cubit) => cubit.checkKyc(),
      expect: () => [
        const KycLoading(),
        isA<KycFailure>(),
      ],
    );

    blocTest<KycCubit, KycState>(
      'emits KycFailure on generic exception',
      setUp: () {
        when(() => kycService.getKycStatus()).thenThrow(Exception('network down'));
        when(() => kycService.getUser()).thenAnswer((_) async => _user());
      },
      build: buildCubit,
      act: (cubit) => cubit.checkKyc(),
      expect: () => [
        const KycLoading(),
        isA<KycFailure>(),
      ],
    );
  });

  group('$KycCubit timeout & generation handling', () {
    test(
      'a late response from a timed-out call does NOT overwrite the fresh state of a retry (regression for #315 / #317)',
      () async {
        final call1Completer = Completer<KycLevelDto>();
        var firstCall = true;
        when(() => kycService.getKycStatus()).thenAnswer((_) {
          if (firstCall) {
            firstCall = false;
            return call1Completer.future;
          }
          return Future.value(
            _kycStatus(level: KycLevel.level50, processStatus: KycProcessStatus.completed),
          );
        });
        when(() => kycService.getUser()).thenAnswer((_) async => _user());

        final cubit = KycCubit(kycService, registrationService, appStore)
          ..markLegalDisclaimerAccepted();

        final states = <KycState>[];
        final sub = cubit.stream.listen(states.add);

        final call1Future = cubit.checkKyc();

        await Future<void>.delayed(Duration.zero);

        await cubit.checkKyc();

        call1Completer.complete(
          _kycStatus(level: KycLevel.level50, processStatus: KycProcessStatus.completed),
        );
        await call1Future;
        await Future<void>.delayed(Duration.zero);

        await sub.cancel();
        await cubit.close();

        expect(states, [const KycLoading(), const KycCompleted()]);
        expect(cubit.state, const KycCompleted());
      },
    );

    blocTest<KycCubit, KycState>(
      'emits KycFailure when a backend call throws TimeoutException',
      setUp: () {
        when(() => kycService.getKycStatus()).thenAnswer(
          (_) async => throw TimeoutException('backend slow'),
        );
        when(() => kycService.getUser()).thenAnswer((_) async => _user());
      },
      build: buildCubit,
      act: (cubit) => cubit.checkKyc(),
      expect: () => [const KycLoading(), isA<KycFailure>()],
    );

    // The outer 30s timeout on `_runCheckKyc` is the watchdog that surfaces
    // a "did not respond in time" failure when the backend never resolves —
    // distinct from the inner `TimeoutException`-from-the-service path
    // above. fake_async lets us advance virtual time past the 30s budget
    // without a wallclock sleep.
    test(
      'emits "did not respond in time" KycFailure when _runCheckKyc exceeds the 30s outer timeout',
      () {
        fakeAsync((async) {
          when(() => kycService.getKycStatus()).thenAnswer((_) => Completer<KycLevelDto>().future);
          when(() => kycService.getUser()).thenAnswer((_) async => _user());

          final cubit = buildCubit();
          final states = <KycState>[];
          final sub = cubit.stream.listen(states.add);

          unawaited(cubit.checkKyc());
          async.elapse(const Duration(seconds: 31));

          expect(states, [
            const KycLoading(),
            const KycFailure('KYC backend did not respond in time'),
          ]);

          sub.cancel();
          cubit.close();
        });
      },
    );

    // A slow refresh from the merge-processing waiting screen must NOT route the
    // user to the error screen: when the watchdog fires and the previous state
    // was KycMergeProcessing, the cubit returns to KycMergeProcessing instead of
    // emitting KycFailure. Contrast with the watchdog test above (non-merge
    // state -> KycFailure), which still holds.
    test(
      'stays on KycMergeProcessing instead of KycFailure when a refresh exceeds the timeout',
      () {
        fakeAsync((async) {
          // Phase 1: backend reports MergeProcessing -> cubit reaches the waiting state.
          when(() => kycService.getKycStatus()).thenAnswer(
            (_) async => _kycStatus(
              level: KycLevel.level20,
              processStatus: KycProcessStatus.mergeProcessing,
            ),
          );
          when(() => kycService.getUser()).thenAnswer((_) async => _user());

          final cubit = buildCubit();
          final states = <KycState>[];
          final sub = cubit.stream.listen(states.add);

          cubit.markLegalDisclaimerAccepted();
          unawaited(cubit.checkKyc());
          async.flushMicrotasks();

          // Phase 2: refresh while the backend hangs past the 30s watchdog.
          when(() => kycService.getKycStatus()).thenAnswer((_) => Completer<KycLevelDto>().future);
          unawaited(cubit.checkKyc());
          async.elapse(const Duration(seconds: 31));

          expect(states, [
            const KycLoading(),
            const KycMergeProcessing(),
            const KycLoading(),
            const KycMergeProcessing(),
          ]);

          sub.cancel();
          cubit.close();
        });
      },
    );
  });

  group('$KycCubit context forwarding', () {
    blocTest<KycCubit, KycState>(
      'passes context to getKycStatus and continueKyc when provided',
      setUp: () {
        when(() => kycService.getKycStatus(context: 'RealunitBuy')).thenAnswer(
          (_) async => _kycStatus(
            level: KycLevel.level20,
            processStatus: KycProcessStatus.inProgress,
          ),
        );
        when(() => kycService.getUser()).thenAnswer((_) async => _user());
        when(() => kycService.continueKyc(context: 'RealunitBuy')).thenAnswer(
          (_) async => _session(
            level: KycLevel.level20,
            steps: const [],
            currentStep: _currentStep(
              KycStepName.ident,
              url: 'https://example.com/ident',
            ),
          ),
        );
      },
      build: buildCubit,
      act: (cubit) async {
        cubit.markLegalDisclaimerAccepted();
        await cubit.checkKyc(context: 'RealunitBuy');
      },
      expect: () => [
        const KycLoading(),
        const KycSuccess(
          currentStep: KycStep.ident,
          urlOrToken: 'https://example.com/ident',
        ),
      ],
      verify: (_) {
        verify(() => kycService.getKycStatus(context: 'RealunitBuy')).called(1);
        verify(() => kycService.continueKyc(context: 'RealunitBuy')).called(1);
      },
    );

    blocTest<KycCubit, KycState>(
      'context is sticky — subsequent checkKyc() without context reuses the stored one',
      setUp: () {
        when(() => kycService.getKycStatus(context: 'RealunitBuy')).thenAnswer(
          (_) async => _kycStatus(
            level: KycLevel.level50,
            processStatus: KycProcessStatus.completed,
          ),
        );
        when(() => kycService.getUser()).thenAnswer((_) async => _user());
      },
      build: buildCubit,
      act: (cubit) async {
        cubit.markLegalDisclaimerAccepted();
        // First call sets the context.
        await cubit.checkKyc(context: 'RealunitBuy');
        // Second call omits context — should reuse 'RealunitBuy'.
        await cubit.checkKyc();
      },
      verify: (_) {
        verify(() => kycService.getKycStatus(context: 'RealunitBuy')).called(2);
      },
      expect: () => [
        const KycLoading(),
        const KycCompleted(),
        const KycLoading(),
        const KycCompleted(),
      ],
    );
  });

  group('$KycCubit markLegalDisclaimerAccepted', () {
    blocTest<KycCubit, KycState>(
      'progresses through disclaimer gate and lets API drive the next routing decision',
      setUp: () {
        when(() => kycService.getKycStatus()).thenAnswer(
          (_) async => _kycStatus(
            level: KycLevel.level50,
            processStatus: KycProcessStatus.completed,
          ),
        );
        when(() => kycService.getUser()).thenAnswer((_) async => _user());
      },
      build: buildCubit,
      act: (cubit) async {
        await cubit.checkKyc(); // expects legalDisclaimer
        cubit.markLegalDisclaimerAccepted();
        await cubit.checkKyc(); // expects KycCompleted (AlreadyRegistered + processStatus=Completed)
      },
      expect: () => [
        const KycLoading(),
        const KycSuccess(currentStep: KycStep.legalDisclaimer),
        const KycLoading(),
        const KycCompleted(),
      ],
    );
  });
}
