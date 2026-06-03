import 'dart:async';

import 'package:collection/collection.dart';
import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:realunit_wallet/packages/service/app_store.dart';
import 'package:realunit_wallet/packages/service/dfx/dfx_kyc_service.dart';
import 'package:realunit_wallet/packages/service/dfx/exceptions/api_exception.dart';
import 'package:realunit_wallet/packages/service/dfx/models/kyc/dto/kyc_level_dto.dart';
import 'package:realunit_wallet/packages/service/dfx/models/kyc/kyc_level.dart';
import 'package:realunit_wallet/packages/service/dfx/models/user/dto/real_unit_user_data_dto.dart';
import 'package:realunit_wallet/packages/service/dfx/models/user/dto/user_dto.dart';
import 'package:realunit_wallet/packages/service/dfx/models/wallet/real_unit_registration_state.dart';
import 'package:realunit_wallet/packages/service/dfx/real_unit_registration_service.dart';
import 'package:realunit_wallet/packages/wallet/wallet.dart';

part 'kyc_state.dart';

class KycCubit extends Cubit<KycState> {
  static const _checkKycTimeout = Duration(seconds: 30);

  final DfxKycService _kycService;
  final RealUnitRegistrationService _registrationService;
  final AppStore _appStore;

  bool _legalDisclaimerAccepted = false;
  bool _emailRegistrationAttempted = false;
  String? _kycContext;

  // `Future.timeout` does not cancel the underlying work, so a late HTTP
  // response from an earlier call can still resume and emit state after a
  // retry. Each `checkKyc()` captures its own generation; the run body and
  // any continuations bail when their generation no longer matches the
  // current one. Acts as a cancellation token for non-cancellable work.
  int _runGeneration = 0;

  KycCubit(
    DfxKycService kycService,
    RealUnitRegistrationService registrationService,
    AppStore appStore,
  ) : _kycService = kycService,
      _registrationService = registrationService,
      _appStore = appStore,
      super(const KycInitial());

  Future<void> checkKyc({String? context}) async {
    _kycContext = context ?? _kycContext;
    // The merge-processing waiting screen must survive a slow refresh: the
    // backend may still be re-parenting the merge when the user taps refresh,
    // and surfacing the watchdog timeout as KycFailure would route them to the
    // error screen — the exact failure mode the waiting page exists to avoid.
    // Captured before _runCheckKyc, which immediately replaces the state with
    // KycLoading.
    final wasMergeProcessing = state is KycMergeProcessing;
    final generation = ++_runGeneration;
    try {
      await _runCheckKyc(generation).timeout(_checkKycTimeout);
    } on TimeoutException {
      if (isClosed || generation != _runGeneration) return;
      if (wasMergeProcessing) {
        emit(const KycMergeProcessing());
        return;
      }
      emit(const KycFailure('KYC backend did not respond in time'));
    } catch (e) {
      if (isClosed || generation != _runGeneration) return;
      emit(KycFailure(e.toString()));
    }
  }

  Future<void> _runCheckKyc(int generation) async {
    try {
      if (isClosed || generation != _runGeneration) return;
      emit(const KycLoading());

      final results = await Future.wait([
        _kycService.getKycStatus(context: _kycContext),
        _kycService.getUser(),
      ]);

      if (isClosed || generation != _runGeneration) return;

      final kycStatus = results.elementAt(0) as KycLevelDto;
      final user = results.elementAt(1) as UserDto;
      final level = kycStatus.kycLevel.value;

      if (user.mail == null) {
        emit(const KycSuccess(currentStep: KycStep.email));
        return;
      }

      // Edge case: email exists but level is < 10. Backend hasn't bumped the
      // level after a prior auto-registration attempt — re-fire it once.
      if (level < 10) {
        if (_emailRegistrationAttempted) {
          // Backend did not bump the level after registration; surface the
          // current state instead of recursing forever.
          emit(const KycSuccess(currentStep: KycStep.email));
          return;
        }
        _emailRegistrationAttempted = true;
        await _registrationService.registerEmail(user.mail!);
        if (isClosed || generation != _runGeneration) return;
        await _runCheckKyc(generation);
        return;
      }

      // Disclaimer is a local session gate that must precede every sensitive
      // call. It does not encode business routing — the API does — it just
      // enforces a per-session ceremony on this device before the cubit
      // forwards anything that requires a signed user identity.
      if (!_legalDisclaimerAccepted) {
        emit(const KycSuccess(currentStep: KycStep.legalDisclaimer));
        return;
      }

      // The server-side registration state is the single source of truth for
      // whether this wallet needs a full registration form, a one-tap
      // "add wallet" confirmation, or can skip the step entirely. Replaces
      // the previous client-side `_registrationSignProduced` flag — the cubit
      // re-fetches state after every successful registration round-trip and
      // routes from whatever the API now reports.
      final registrationInfo = await _registrationService.getRegistrationInfo();
      if (isClosed || generation != _runGeneration) return;

      // Signing capability is a physical property of the wallet implementation
      // (debug mode is address-only, cannot produce EIP-712 signatures) and
      // cannot be derived from the server — see CONTRIBUTING.md "API as
      // Decision Authority" exception list for "physical security boundary"
      // gates. Surface a tailored failure instead of letting the sign call
      // throw `UnsupportedError` deep inside the registration flow.
      if (_appStore.wallet.walletType == WalletType.debug &&
          (registrationInfo.state == RealUnitRegistrationState.newRegistration ||
              registrationInfo.state == RealUnitRegistrationState.addWallet)) {
        emit(const KycSignatureUnsupportedFailure());
        return;
      }

      switch (registrationInfo.state) {
        case RealUnitRegistrationState.alreadyRegistered:
          // Fall through to the processStatus dispatch below — the sign
          // gate is satisfied and the user proceeds to the next KYC step.
          break;
        case RealUnitRegistrationState.addWallet:
          // Forward the server-supplied userData so `KycLinkWalletPage` does
          // not have to re-fetch — see CONTRIBUTING.md "Single round-trip per
          // decision". The backend always populates this for `AddWallet`.
          emit(
            KycSuccess(
              currentStep: KycStep.linkWallet,
              realUnitUserData: registrationInfo.realUnitUserDataDto,
            ),
          );
          return;
        case RealUnitRegistrationState.newRegistration:
          // userData may be `null` for first-time registrations (no prior
          // record to pre-fill from); `KycRegistrationPage` renders an empty
          // form in that case.
          emit(
            KycSuccess(
              currentStep: KycStep.registration,
              realUnitUserData: registrationInfo.realUnitUserDataDto,
            ),
          );
          return;
        case RealUnitRegistrationState.kycRequired:
          emit(const KycRequiredFailure());
          return;
      }

      // Account-merge invitation is still surfaced from the step list because
      // it is delivered as a step `reason`, not as `currentStep`. Render
      // verbatim what the backend tagged.
      final hasMergeRequest = kycStatus.kycSteps.any(
        (step) => step.reason == KycStepReason.accountMergeRequested,
      );
      if (hasMergeRequest) {
        emit(const KycAccountMergeRequested());
        return;
      }

      // From here on the API is the authority. Render `processStatus` plus
      // the matching `currentStep` from the session response; no local
      // iteration over `kycSteps`, no local "what counts as actionable"
      // set, no local level threshold. See docs/api-authority-plan.md
      // (Wave 2) for the design.
      switch (kycStatus.processStatus) {
        case KycProcessStatus.completed:
          emit(const KycCompleted());
          return;
        case KycProcessStatus.failed:
          emit(const KycFailure('KYC terminated'));
          return;
        case KycProcessStatus.pendingReview:
          // PendingReview is authoritative: the API says "do not let the user
          // through". Never collapse this branch to `KycCompleted` — that
          // would be the same class of misroute as the 2026-05-21 incident,
          // just in the opposite direction (API: review pending → app:
          // completed). If we cannot identify a required step we surface
          // `KycUnsupportedStepFailure` so the user gets an explicit error
          // instead of a silent dashboard handoff.
          final pending = kycStatus.kycSteps.firstWhereOrNull(
            (s) => s.isRequired && s.status != KycStepStatus.completed,
          );
          if (pending == null) {
            emit(const KycUnsupportedStepFailure(null));
            return;
          }
          final step = _mapStepName(pending.name);
          if (step == null) {
            emit(KycUnsupportedStepFailure(pending.name));
            return;
          }
          emit(KycPending(step));
          return;
        case KycProcessStatus.inProgress:
          await _continueKyc(generation);
          return;
        case KycProcessStatus.mergeProcessing:
          // The user confirmed a merge and the backend is still processing it.
          // Render a waiting state; do not treat the polling timeout as failure.
          emit(const KycMergeProcessing());
          return;
      }
    } on ApiException catch (e) {
      if (isClosed || generation != _runGeneration) return;
      // The body `code` is the authoritative signal — `TfaRequiredException`
      // on the API sets `{code: 'TFA_REQUIRED', level, message}` and happens
      // to use HTTP 403 as transport. Matching on status alone would also
      // capture unrelated forbidden errors and misroute them to 2FA.
      if (e.code == 'TFA_REQUIRED') {
        emit(const KycSuccess(currentStep: KycStep.twoFa));
      } else {
        rethrow;
      }
    } catch (e) {
      if (isClosed || generation != _runGeneration) return;
      emit(KycFailure(e.toString()));
    }
  }

  void markLegalDisclaimerAccepted() {
    _legalDisclaimerAccepted = true;
  }

  /// should only be called after realunit registration was completed
  Future<void> _continueKyc(int generation) async {
    final kycStatus = await _kycService.continueKyc(context: _kycContext);
    if (isClosed || generation != _runGeneration) return;

    // `KycSessionDto.currentStep` is the authoritative source — see
    // `docs/api-authority-audit.md` V45 and `docs/api-authority-plan.md`
    // §W2.2. Never iterate `kycSteps` here: the local filter is the same
    // anti-pattern V1/V2/V3/V5 just eliminated in `_runCheckKyc`. If the
    // session response has no `currentStep` we surface
    // `KycUnsupportedStepFailure` instead of throwing a bare `StateError`
    // through the outer catch (which used to land as raw stack trace text
    // in the i18n message).
    final currentStep = kycStatus.currentStep;
    if (currentStep == null) {
      emit(const KycUnsupportedStepFailure(null));
      return;
    }

    final kycStep = _mapStepName(currentStep.name);
    if (kycStep == null) {
      emit(KycUnsupportedStepFailure(currentStep.name));
      return;
    }

    emit(
      KycSuccess(
        currentStep: kycStep,
        urlOrToken: currentStep.session.url,
      ),
    );
  }

  KycStep? _mapStepName(KycStepName name) => switch (name) {
    KycStepName.contactData => KycStep.registration,
    KycStepName.nationalityData => KycStep.nationality,
    KycStepName.ident => KycStep.ident,
    KycStepName.financialData => KycStep.financialData,
    KycStepName.dfxApproval => KycStep.dfxApproval,
    _ => null,
  };
}
