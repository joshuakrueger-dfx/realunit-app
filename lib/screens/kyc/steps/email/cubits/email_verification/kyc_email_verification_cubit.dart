import 'dart:developer' as developer;

import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:realunit_wallet/packages/service/dfx/dfx_auth_service.dart';
import 'package:realunit_wallet/packages/service/dfx/exceptions/bitbox_exception.dart';
import 'package:realunit_wallet/packages/service/dfx/real_unit_registration_service.dart';
import 'package:realunit_wallet/packages/service/dfx/models/wallet/real_unit_wallet_status_dto.dart';
import 'package:realunit_wallet/packages/service/dfx/real_unit_wallet_service.dart';
import 'package:realunit_wallet/packages/utils/jwt_decoder.dart';
import 'package:realunit_wallet/packages/wallet/error_mapper.dart';

part 'kyc_email_verification_state.dart';

class KycEmailVerificationCubit extends Cubit<KycEmailVerificationState> {
  final DFXAuthService _dfxService;
  final RealUnitWalletService _walletService;
  final RealUnitRegistrationService _registrationService;

  /// Invoked when registerWallet succeeded. Closes BL-006 by moving the
  /// sign-gate flip from the page-listener-on-pop into the cubit's own
  /// success branch — the gate is no longer flipped speculatively if
  /// the user dismisses the page mid-flow.
  final void Function()? _onSignProduced;

  // `Future.timeout` does not cancel the underlying work, so a late HTTP
  // response from an earlier call can still resume after a retry. Each
  // `checkEmailVerification` captures its own generation; any continuation
  // bails when its generation no longer matches the current one. Acts as a
  // cancellation token for non-cancellable HTTP work, and lets a fast
  // double-tap supersede the in-flight call instead of racing two emit
  // sequences. Pattern mirrors `KycCubit._runGeneration`.
  int _runGeneration = 0;

  // Once the JWT account-id change has confirmed the merge, the auth side
  // is settled — re-running the account-id comparison on a retry would just
  // emit `Failure` ("email not yet confirmed") because `getAuthToken` keeps
  // returning the new (merged) account. The remaining work that can still
  // race is `getWalletStatus` propagation on the user-data side, so a retry
  // after a `RegistrationFailure` should skip the auth-side check and go
  // straight to `_completeRegistration`.
  //
  // BL-006 invariant: on [BitboxNotConnectedException] we RESET this latch
  // so that after the user reconnects the BitBox and retries, the JWT
  // account-id check runs again. Without the reset a reconnect-then-retry
  // would skip the auth-side step and fail mysteriously on a backend race.
  bool _mergeDetected;

  // The merge-detected seed for this entry. On a BitBox-drop retry the latch
  // resets to THIS value (not unconditionally `false`) so the re-entrant
  // resume path keeps skipping the one-shot account-id check after a
  // reconnect — re-running it post-merge would falsely report "email not
  // confirmed" because the account id no longer changes.
  final bool _initialMergeDetected;

  KycEmailVerificationCubit({
    required DFXAuthService dfxService,
    required RealUnitWalletService walletService,
    required RealUnitRegistrationService registrationService,
    void Function()? onSignProduced,
    // Re-entrant resume path: when the merge was already confirmed on the
    // auth side in a previous session (app restarted mid-merge), the one-shot
    // JWT account-id delta can no longer be observed. Seed the latch as
    // detected so checkEmailVerification skips straight to registerWallet.
    bool initialMergeDetected = false,
    // Bounded auto-retry for the post-merge user-data propagation race.
    // Injectable so tests can drive the immediate-fail contract (retries: 1,
    // zero delay) without waiting on real timers.
    int walletStatusRetries = 4,
    Duration walletStatusRetryDelay = const Duration(seconds: 2),
  }) : _dfxService = dfxService,
       _walletService = walletService,
       _registrationService = registrationService,
       _onSignProduced = onSignProduced,
       _mergeDetected = initialMergeDetected,
       _initialMergeDetected = initialMergeDetected,
       _walletStatusRetries = walletStatusRetries,
       _walletStatusRetryDelay = walletStatusRetryDelay,
       super(const KycEmailVerificationInitial());

  Future<void> checkEmailVerification() async {
    final generation = ++_runGeneration;
    if (isClosed) return;
    emit(const KycEmailVerificationLoading());

    if (!_mergeDetected) {
      final currentAccountId = await getAccountId();
      if (isClosed || generation != _runGeneration) return;
      _dfxService.invalidateAuthToken();
      final newAccountId = await getAccountId();
      if (isClosed || generation != _runGeneration) return;

      if (currentAccountId == newAccountId) {
        // Email link not yet clicked, or token still cached. The user can
        // retry by tapping again once the link in the confirmation mail has
        // actually been visited.
        emit(const KycEmailVerificationFailure());
        return;
      }
      _mergeDetected = true;
    }

    // JWT account changed → backend recognised the merge. Now associate the
    // new wallet with the merged user via the EIP-712 registration signature.
    if (await _completeRegistration(generation)) {
      if (isClosed || generation != _runGeneration) return;
      // Sign succeeded — flip the sign-gate from inside the cubit so the
      // outer page-listener can drop its speculative
      // `markRegistrationSignProduced()` on pop (closes BL-006).
      _onSignProduced?.call();
      emit(const KycEmailVerificationSuccess());
    }
    // else: _completeRegistration already emitted RegistrationFailure or
    // KycEmailVerificationBitboxRequired; we intentionally do NOT emit
    // Success here so the verification page stays open and the user can
    // retry without the failure being papered over.
  }

  /// Returns `true` when the wallet was successfully registered with the
  /// (now-merged) user account. On failure the cubit is already in
  /// [KycEmailVerificationRegistrationFailure] or
  /// [KycEmailVerificationBitboxRequired] so the listener can show the
  /// error to the user.
  // Bounded auto-retry budget for the post-merge user-data propagation race.
  // getWalletStatus is a side-effect-free GET, so polling it a few times is
  // safe; this absorbs the common "auth merged, user-data not propagated yet"
  // window without forcing the user to tap retry manually. Injected so tests
  // run without real delays.
  final int _walletStatusRetries;
  final Duration _walletStatusRetryDelay;

  Future<bool> _completeRegistration(int generation) async {
    try {
      // Backend race: the auth service reports the merged account while the
      // user-data service hasn't propagated `realUnitUserDataDto` yet. Poll a
      // bounded number of times before giving up so the merge completes
      // automatically in the common case instead of dead-ending on a manual
      // retry. The `_mergeDetected` latch already guarantees a later manual
      // retry skips the auth-side check, so a final failure here is still
      // recoverable.
      RealUnitWalletStatusDto? status;
      for (var attempt = 0; attempt < _walletStatusRetries; attempt++) {
        status = await _walletService.getWalletStatus();
        if (isClosed || generation != _runGeneration) return false;
        if (status.realUnitUserDataDto != null) break;
        if (attempt < _walletStatusRetries - 1) {
          await Future<void>.delayed(_walletStatusRetryDelay);
          if (isClosed || generation != _runGeneration) return false;
        }
      }
      if (status?.realUnitUserDataDto == null) {
        developer.log(
          'getWalletStatus still null after $_walletStatusRetries attempts',
        );
        emit(const KycEmailVerificationRegistrationFailure());
        return false;
      }
      await _registrationService.registerWallet(status!.realUnitUserDataDto!);
      if (isClosed || generation != _runGeneration) return false;
      return true;
    } on BitboxNotConnectedException {
      // BL-006 — the BitBox dropped mid-sign. Route to the typed
      // BitboxRequired state so the page can open the reconnect sheet
      // instead of showing a generic "Registration failed" snackbar.
      // Reset `_mergeDetected` so the post-reconnect retry re-runs the
      // auth-side JWT account check (the backend may have rotated tokens
      // during the reconnect window).
      if (isClosed || generation != _runGeneration) return false;
      _mergeDetected = _initialMergeDetected;
      emit(const KycEmailVerificationBitboxRequired());
      return false;
    } on BitboxNotConnectedSignException {
      // Same as above but via the typed-pipeline path (post-Initiative
      // II migration). Kept distinct so a refactor that drops the
      // legacy exception import still routes through the typed
      // hierarchy. Resets `_mergeDetected` for the same reason.
      if (isClosed || generation != _runGeneration) return false;
      _mergeDetected = _initialMergeDetected;
      emit(const KycEmailVerificationBitboxRequired());
      return false;
    } catch (e) {
      if (isClosed || generation != _runGeneration) return false;
      developer.log('registerWallet failed: $e');
      emit(const KycEmailVerificationRegistrationFailure());
      return false;
    }
  }

  Future<int?> getAccountId() async {
    final token = await _dfxService.getAuthToken();
    if (token == null) return null;
    final currentJwt = JwtDecoder.parseJwt(token);
    return currentJwt['account'] as int?;
  }
}
