import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:realunit_wallet/generated/i18n.dart';
import 'package:realunit_wallet/packages/service/dfx/dfx_kyc_service.dart';
import 'package:realunit_wallet/packages/service/dfx/models/kyc/kyc_level.dart';
import 'package:realunit_wallet/packages/service/dfx/real_unit_registration_service.dart';
import 'package:realunit_wallet/screens/kyc/cubits/kyc/kyc_cubit.dart';
import 'package:realunit_wallet/screens/kyc/steps/2fa/kyc_2fa_page.dart';
import 'package:realunit_wallet/screens/kyc/steps/email/kyc_email_page.dart';
import 'package:realunit_wallet/screens/kyc/steps/email/subpages/kyc_email_verification_page.dart';
import 'package:realunit_wallet/screens/kyc/steps/financial_data/kyc_financial_data_page.dart';
import 'package:realunit_wallet/screens/kyc/steps/ident/kyc_ident_page.dart';
import 'package:realunit_wallet/screens/kyc/steps/nationality/kyc_nationality_page.dart';
import 'package:realunit_wallet/screens/kyc/steps/registration/kyc_registration_page.dart';
import 'package:realunit_wallet/screens/kyc/subpages/kyc_account_merge_page.dart';
import 'package:realunit_wallet/screens/kyc/subpages/kyc_completed_page.dart';
import 'package:realunit_wallet/screens/kyc/subpages/kyc_failure_page.dart';
import 'package:realunit_wallet/screens/kyc/subpages/kyc_loading_page.dart';
import 'package:realunit_wallet/screens/kyc/subpages/kyc_pending_page.dart';
import 'package:realunit_wallet/screens/legal/legal_disclaimer_page.dart';
import 'package:realunit_wallet/setup/di.dart';

class KycPageManager extends StatelessWidget {
  const KycPageManager({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (context) => KycCubit(
        getIt<DfxKycService>(),
        getIt<RealUnitRegistrationService>(),
      )..checkKyc(),
      child: const KycViewManager(),
    );
  }
}

class KycViewManager extends StatelessWidget {
  const KycViewManager({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<KycCubit, KycState>(
      builder: (context, state) => switch (state) {
        KycLoading() => const KycLoadingPage(),
        KycFailure(:final message) => KycFailurePage(message: message),
        KycUnsupportedStepFailure(:final stepName) => KycFailurePage(
          message: S.of(context).kycUnsupportedStepDescription(stepName?.value ?? '-'),
        ),
        KycAccountMergeRequested() => const KycAccountMergePage(),
        // Re-entrant merge completion (rendered in place, inside the KycCubit
        // provider — so KycEmailVerificationPage resolves KycCubit without a
        // pushed-route BlocProvider.value). mergeAlreadyConfirmed seeds the
        // verification cubit so it skips the one-shot account-id check.
        KycWalletRegistrationRequired() => const KycEmailVerificationPage(
          mergeAlreadyConfirmed: true,
        ),
        KycPending(:final pendingStep) => KycPendingPage(pendingStep: pendingStep),
        KycCompleted() => const KycCompletedPage(),
        KycSuccess(:final currentStep, :final urlOrToken) => switch (currentStep) {
          KycStep.email => const KycEmailPage(),
          KycStep.legalDisclaimer => LegalDisclaimerPage(
            onCompleted: () {
              context.read<KycCubit>().markLegalDisclaimerAccepted();
              context.read<KycCubit>().checkKyc();
            },
          ),
          KycStep.registration => const KycRegistrationPage(),
          KycStep.nationality => KycNationalityPage(url: urlOrToken ?? ''),
          KycStep.twoFa => const Kyc2FaPage(),
          KycStep.ident => KycIdentPage(accessToken: urlOrToken ?? ''),
          KycStep.financialData => KycFinancialDataPage(url: urlOrToken ?? ''),
          // DfxApproval is a backend-side manual review step with no user
          // action — the user has completed everything actionable and is
          // waiting for DFX to approve. Render the pending/review screen
          // instead of a blank Scaffold (previously fell through to the
          // grey catch-all below).
          KycStep.dfxApproval => const KycPendingPage(pendingStep: KycStep.dfxApproval),
        },
        // Never render a blank grey Scaffold — surface the unhandled state so
        // it is diagnosable on-device instead of looking like a hang.
        KycState() => KycFailurePage(
          message: 'Unhandled KYC state: ${state.runtimeType}',
        ),
      },
    );
  }
}
