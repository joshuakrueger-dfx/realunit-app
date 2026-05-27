import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:realunit_wallet/generated/i18n.dart';
import 'package:realunit_wallet/packages/service/dfx/real_unit_registration_service.dart';
import 'package:realunit_wallet/screens/kyc/cubits/kyc/kyc_cubit.dart';
import 'package:realunit_wallet/screens/kyc/steps/email/cubits/email_step/kyc_email_step_cubit.dart';
import 'package:realunit_wallet/screens/kyc/steps/email/subpages/kyc_email_verification_page.dart';
import 'package:realunit_wallet/setup/di.dart';
import 'package:realunit_wallet/styles/colors.dart';
import 'package:realunit_wallet/widgets/buttons/app_filled_button.dart';
import 'package:realunit_wallet/widgets/form/labeled_text_field.dart';

class KycEmailPage extends StatelessWidget {
  const KycEmailPage({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (context) => KycEmailStepCubit(
        getIt<RealUnitRegistrationService>(),
      ),
      child: const KycEmailView(),
    );
  }
}

class KycEmailView extends StatelessWidget {
  const KycEmailView({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(S.of(context).registerEmail)),
      body: const KycEmailForm(),
    );
  }
}

class KycEmailForm extends StatefulWidget {
  const KycEmailForm({super.key});

  @override
  State<KycEmailForm> createState() => _KycEmailFormState();
}

class _KycEmailFormState extends State<KycEmailForm> {
  final _formKey = GlobalKey<FormState>();
  final _emailCtrl = TextEditingController();

  @override
  void dispose() {
    _emailCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return BlocListener<KycEmailStepCubit, KycEmailStepState>(
      listener: (context, state) async {
        if (state is KycEmailStepFailure) {
          final message = state.error == .emailDoesNotMatch
              ? S.of(context).registerEmailDoesNotMatch
              : state.message;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(message),
              backgroundColor: RealUnitColors.status.red600,
            ),
          );
        }
        if (state is KycEmailStepSuccess) {
          if (state.status == .emailRegistered) {
            context.read<KycCubit>().checkKyc();
          }
          if (state.status == .mergeRequested) {
            // KycCubit lives in the KycPageManager BlocProvider, which is an
            // ancestor of THIS page but NOT of a route pushed onto the
            // Navigator. Capture it here (where it resolves) and re-provide it
            // into the pushed route via BlocProvider.value so
            // KycEmailVerificationPage can wire its onSignProduced callback
            // without a `Provider<KycCubit> not found` crash. `.value` does
            // not own the cubit, so popping the route never closes it.
            final kycCubit = context.read<KycCubit>();
            final isConfirmed = await Navigator.push<bool>(
              context,
              MaterialPageRoute<bool>(
                builder: (_) => BlocProvider<KycCubit>.value(
                  value: kycCubit,
                  child: const KycEmailVerificationPage(),
                ),
              ),
            );
            if (isConfirmed == true && context.mounted) {
              // BL-006 — the sign-gate flip is now owned by
              // KycEmailVerificationCubit's success branch (via the
              // `onSignProduced` callback wired in
              // KycEmailVerificationPage). The page-on-pop listener
              // continues to drive the rest of the KYC step rotation
              // via `checkKyc()`, but the gate is no longer flipped
              // speculatively from here.
              context.read<KycCubit>().checkKyc();
            }
          }
        }
      },
      child: SingleChildScrollView(
        padding: const .symmetric(horizontal: 20),
        child: SafeArea(
          child: GestureDetector(
            onTap: () => FocusManager.instance.primaryFocus?.unfocus(),
            child: Form(
              key: _formKey,
              child: Column(
                children: [
                  LabeledTextField(
                    label: S.of(context).email,
                    hintText: 'max@mustermann.ch',
                    controller: _emailCtrl,
                    keyboardType: .emailAddress,
                    hideErrorText: false,
                    validator: (value) {
                      if (value == null || value.isEmpty) {
                        return S.of(context).registerEmailRequired;
                      }
                      if (!RegExp(r'^[^@]+@[^@]+\.[^@]+').hasMatch(value)) {
                        return S.of(context).registerEmailInvalid;
                      }
                      return null;
                    },
                  ),
                  Padding(
                    padding: const .symmetric(vertical: 16.0),
                    child: BlocBuilder<KycEmailStepCubit, KycEmailStepState>(
                      builder: (context, state) {
                        return AppFilledButton(
                          state: state is KycEmailStepLoading ? .loading : .idle,
                          onPressed: () {
                            FocusManager.instance.primaryFocus?.unfocus();
                            if (_formKey.currentState?.validate() ?? false) {
                              context.read<KycEmailStepCubit>().registerEmail(
                                _emailCtrl.text.trim(),
                              );
                            }
                          },
                          label: S.of(context).next,
                        );
                      },
                    ),
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
