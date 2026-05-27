import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_svg/svg.dart';
import 'package:go_router/go_router.dart';
import 'package:realunit_wallet/generated/i18n.dart';
import 'package:realunit_wallet/packages/hardware_wallet/bitbox_credentials.dart';
import 'package:realunit_wallet/packages/service/dfx/dfx_widget_service.dart';
import 'package:realunit_wallet/packages/service/dfx/real_unit_registration_service.dart';
import 'package:realunit_wallet/packages/service/dfx/real_unit_wallet_service.dart';
import 'package:realunit_wallet/screens/hardware_connect_bitbox/show_bitbox_reconnect_sheet.dart';
import 'package:realunit_wallet/screens/home/bloc/home_bloc.dart';
import 'package:realunit_wallet/screens/kyc/cubits/kyc/kyc_cubit.dart';
import 'package:realunit_wallet/screens/kyc/steps/email/cubits/email_verification/kyc_email_verification_cubit.dart';
import 'package:realunit_wallet/setup/di.dart';
import 'package:realunit_wallet/styles/colors.dart';
import 'package:realunit_wallet/widgets/buttons/app_filled_button.dart';

class KycEmailVerificationPage extends StatelessWidget {
  /// When `true` the page was entered via the re-entrant resume path
  /// (KycWalletRegistrationRequired) rather than pushed from the email step:
  /// the auth-side merge already happened in a prior session, so the one-shot
  /// account-id check is seeded as already-detected and success advances the
  /// KYC flow in place (checkKyc) instead of popping a pushed route.
  final bool mergeAlreadyConfirmed;

  const KycEmailVerificationPage({super.key, this.mergeAlreadyConfirmed = false});

  @override
  Widget build(BuildContext context) {
    // Keep a stable reference to the KycCubit owned by the route that
    // pushed this page — the cubit lives one route up the tree so we
    // resolve it before the BlocProvider below shadows nothing.
    final kycCubit = context.read<KycCubit>();
    return BlocProvider(
      create: (context) => KycEmailVerificationCubit(
        dfxService: getIt<DfxWidgetService>(),
        walletService: getIt<RealUnitWalletService>(),
        registrationService: getIt<RealUnitRegistrationService>(),
        // BL-006 — sign-gate flip moves from the outer page listener
        // (kyc_email_page.dart on pop) into the cubit's success branch.
        // The callback hands the existing KycCubit reference so the
        // flip happens exactly when the EIP-712 sign succeeded, not
        // speculatively on a `true` pop.
        onSignProduced: kycCubit.markRegistrationSignProduced,
        initialMergeDetected: mergeAlreadyConfirmed,
      ),
      child: KycEmailVerificationView(mergeAlreadyConfirmed: mergeAlreadyConfirmed),
    );
  }
}

class KycEmailVerificationView extends StatelessWidget {
  final bool mergeAlreadyConfirmed;

  const KycEmailVerificationView({super.key, this.mergeAlreadyConfirmed = false});

  @override
  Widget build(BuildContext context) {
    return BlocListener<KycEmailVerificationCubit, KycEmailVerificationState>(
      listener: (context, state) async {
        if (state is KycEmailVerificationFailure) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(S.of(context).registerEmailVerificationFailed),
              backgroundColor: RealUnitColors.status.red600,
            ),
          );
        }
        if (state is KycEmailVerificationRegistrationFailure) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                S.of(context).registerEmailVerificationRegistrationFailed,
              ),
              backgroundColor: RealUnitColors.status.red600,
            ),
          );
        }
        if (state is KycEmailVerificationSuccess) {
          if (mergeAlreadyConfirmed) {
            // Re-entrant resume: this view is rendered in place by
            // KycViewManager (not a pushed route). Advance the KYC flow via
            // checkKyc — the wallet is now registered, so the registration
            // gate clears and the flow continues. Popping here would tear
            // down the whole /kyc route.
            context.read<KycCubit>().checkKyc();
          } else {
            context.pop(true);
          }
        }
        if (state is KycEmailVerificationBitboxRequired) {
          // BL-006 — surface the reconnect sheet instead of a generic
          // "Registration failed" snackbar. On successful reconnect,
          // immediately re-run the verification flow; the cubit's
          // `_mergeDetected` latch was reset on the disconnect so the
          // JWT account check runs again.
          //
          // Capture the cubit reference up front so the post-await
          // re-run does not depend on the still-mounted BuildContext.
          final cubit = context.read<KycEmailVerificationCubit>();
          final reconnected = await showBitboxReconnectSheet(context);
          if (reconnected && !cubit.isClosed) {
            await cubit.checkEmailVerification();
          }
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(S.of(context).registerEmailVerification),
        ),
        body: SingleChildScrollView(
          padding: const .symmetric(horizontal: 20),
          child: SafeArea(
            child: GestureDetector(
              onTap: () => FocusManager.instance.primaryFocus?.unfocus(),
              child: Column(
                children: [
                  const SizedBox(height: 44.0),
                  SvgPicture.asset(
                    'assets/images/illustrations/email_verification.svg',
                    width: 75,
                  ),
                  const SizedBox(height: 20.0),
                  Column(
                    spacing: 8.0,
                    children: [
                      Text(
                        S.of(context).registerEmailVerificationTitle,
                        style: Theme.of(context).textTheme.headlineMedium,
                      ),
                      Text(
                        S.of(context).registerEmailVerificationDescription,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: RealUnitColors.neutral500,
                        ),
                      ),
                      Padding(
                        padding: const .symmetric(vertical: 16.0),
                        child: BlocBuilder<KycEmailVerificationCubit, KycEmailVerificationState>(
                          builder: (context, state) {
                            final isLoading = state is KycEmailVerificationLoading;
                            final isBitbox = context
                                    .read<HomeBloc>()
                                    .state
                                    .openWallet
                                    ?.currentAccount
                                    .primaryAddress is BitboxCredentials;
                            return Column(
                              spacing: 12,
                              children: [
                                AppFilledButton(
                                  state: isLoading ? .loading : .idle,
                                  onPressed: () => context
                                      .read<KycEmailVerificationCubit>()
                                      .checkEmailVerification(),
                                  label: S.of(context).registerEmailVerificationButton,
                                ),
                                if (isLoading && isBitbox)
                                  Text(
                                    S.of(context).registerEmailVerificationBitboxSignHint,
                                    textAlign: .center,
                                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                      color: RealUnitColors.neutral500,
                                    ),
                                  ),
                              ],
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
