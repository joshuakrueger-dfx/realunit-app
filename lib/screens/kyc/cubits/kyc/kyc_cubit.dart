import 'dart:async';

import 'package:collection/collection.dart';
import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:realunit_wallet/packages/service/dfx/dfx_kyc_service.dart';
import 'package:realunit_wallet/packages/service/dfx/exceptions/api_exception.dart';
import 'package:realunit_wallet/packages/service/dfx/models/kyc/dto/kyc_level_dto.dart';
import 'package:realunit_wallet/packages/service/dfx/models/kyc/kyc_level.dart';
import 'package:realunit_wallet/packages/service/dfx/models/user/dto/user_dto.dart';
import 'package:realunit_wallet/packages/service/dfx/real_unit_registration_service.dart';

part 'kyc_state.dart';

class KycCubit extends Cubit<KycState> {
  static const _checkKycTimeout = Duration(seconds: 30);

  final DfxKycService _kycService;
  final RealUnitRegistrationService _registrationService;

  bool _legalDisclaimerAccepted = false;
  bool _emailRegistrationAttempted = false;

  // Tracks whether the EIP-712 registration signature has been produced in
  // *this* KYC entry. Wallet-agnostic — for software wallets the sign is a
  // silent local operation, for BitBox it is the visible 13-step ceremony.
  // Per-cubit-instance by design: `KycPageManager` creates a fresh `KycCubit`
  // via `BlocProvider(create:)`, so every `/kyc` entry forces a fresh sign
  // before sensitive steps and stale sessions cannot be re-used.
  bool _registrationSignProduced = false;

  // `Future.timeout` does not cancel the underlying work, so a late HTTP
  // response from an earlier call can still resume and emit state after a
  // retry. Each `checkKyc()` captures its own generation; the run body and
  // any continuations bail when their generation no longer matches the
  // current one. Acts as a cancellation token for non-cancellable work.
  int _runGeneration = 0;

  KycCubit(
    DfxKycService kycService,
    RealUnitRegistrationService registrationService,
  ) : _kycService = kycService,
      _registrationService = registrationService,
      super(const KycInitial());

  Future<void> checkKyc() async {
    final generation = ++_runGeneration;
    try {
      await _runCheckKyc(generation).timeout(_checkKycTimeout);
    } on TimeoutException {
      if (isClosed || generation != _runGeneration) return;
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
        _kycService.getKycStatus(),
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

      // Re-entrant merge-completion gate (BL — see ADR / PR notes). The email
      // is set, so the email step (which is where a merge is normally
      // detected and the verification page pushed) is skipped. If the active
      // wallet address is NOT yet in the account's registered `addresses`,
      // an earlier merge was interrupted before `registerWallet` completed —
      // route into the verification page in re-entrant mode to finish it,
      // instead of dropping the user into a fresh KYC step.
      //
      // ASSUMPTION (must be verified end-to-end): the backend lists the
      // wallet address under `/v2/user.addresses` only AFTER `registerWallet`
      // succeeds. If it appears earlier (on the auth-side merge), this gate
      // never fires and the gap persists; if it never appears, this loops —
      // hence the explicit verification call-out in the PR.
      final walletAddress = _registrationService.walletAddress.toLowerCase();
      if (!user.addresses.contains(walletAddress)) {
        emit(const KycWalletRegistrationRequired());
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

      // Disclaimer + EIP-712 registration sign are local session gates that
      // must precede every sensitive call. They do not encode business
      // routing — the API does — they just enforce a per-session security
      // ceremony on this device before the cubit forwards anything that
      // requires a signed user identity.
      if (!_legalDisclaimerAccepted) {
        emit(const KycSuccess(currentStep: KycStep.legalDisclaimer));
        return;
      }
      if (!_registrationSignProduced) {
        emit(const KycSuccess(currentStep: KycStep.registration));
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

  /// Records that the EIP-712 registration signature has been produced in
  /// this session, so subsequent [checkKyc] calls pass the sign gate.
  /// Callers: any code path that triggers the sign — currently the
  /// new-registration form submit and the existing-customer merge confirm.
  void markRegistrationSignProduced() {
    _registrationSignProduced = true;
  }

  /// should only be called after realunit registration was completed
  Future<void> _continueKyc(int generation) async {
    final kycStatus = await _kycService.continueKyc();
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
