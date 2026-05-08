import 'dart:developer' as developer;

import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:realunit_wallet/packages/hardware_wallet/bitbox.dart';
import 'package:realunit_wallet/packages/hardware_wallet/bitbox_credentials.dart';
import 'package:realunit_wallet/packages/service/app_store.dart';
import 'package:realunit_wallet/packages/service/balance_service.dart';
import 'package:realunit_wallet/packages/service/dfx/dfx_widget_service.dart';
import 'package:realunit_wallet/packages/service/settings_service.dart';
import 'package:realunit_wallet/packages/service/transaction_history_service.dart';
import 'package:realunit_wallet/packages/service/wallet_service.dart';
import 'package:realunit_wallet/packages/wallet/wallet.dart';

part 'home_event.dart';
part 'home_state.dart';

class HomeBloc extends Bloc<HomeEvent, HomeState> {
  HomeBloc(
    this._walletService,
    this._balanceService,
    this._transactionHistoryService,
    this._dfxService,
    this._settingsService,
    this._appStore,
    this._bitboxService,
  ) : super(const HomeState()) {
    on<CheckWalletExistsEvent>(_onCheckWalletExists);
    on<LoadCurrentWalletEvent>(_onLoadCurrentWallet);
    on<LoadWalletEvent>(_onLoadWallet);
    on<SyncWalletServicesEvent>(_onSyncWalletServices);
    on<DeleteCurrentWalletEvent>(_onDeleteCurrentWallet);
    on<CompleteOnboardingEvent>(_onCompleteOnboarding);
    on<AcceptSoftwareTermsEvent>(_onAcceptSoftwareTerms);
    on<DebugAuthCompleteEvent>(_onDebugAuthComplete);

    add(const CheckWalletExistsEvent());
  }

  final WalletService _walletService;
  final BalanceService _balanceService;
  final TransactionHistoryService _transactionHistoryService;
  final DfxWidgetService _dfxService;
  final SettingsService _settingsService;
  final AppStore _appStore;
  final BitboxService _bitboxService;

  void _onCheckWalletExists(CheckWalletExistsEvent event, Emitter<HomeState> emit) {
    final hasWallet = _walletService.hasWallet();
    emit(
      state.copyWith(
        hasWallet: hasWallet,
        softwareTermsAccepted: _settingsService.isSoftwareTermsAccepted,
        onboardingCompleted: hasWallet ? _settingsService.isTermsAccepted : false,
      ),
    );
  }

  Future<void> _onLoadCurrentWallet(LoadCurrentWalletEvent event, Emitter<HomeState> emit) async {
    if (state.openWallet != null || !_walletService.hasWallet()) return;

    emit(state.copyWith(isLoadingWallet: true));
    try {
      final wallet = await _walletService.getCurrentWallet();
      _appStore.wallet = wallet;

      emit(
        state.copyWith(
          openWallet: wallet,
          isLoadingWallet: false,
        ),
      );

      await _setupFiatService(emit);
    } catch (e) {
      developer.log('Something went wrong during wallet loading', error: e);
      emit(state.copyWith(isLoadingWallet: false));

      return;
    }

    _balanceService.updateBalance(_appStore.primaryAddress);
    _balanceService.startSync(_appStore.primaryAddress);
    _transactionHistoryService.apiBasedSync();
  }

  Future<void> _onDeleteCurrentWallet(
    DeleteCurrentWalletEvent event,
    Emitter<HomeState> emit,
  ) async {
    emit(state.copyWith(isLoadingWallet: true));

    _bitboxService.stopConnectionStatusObserver();
    await _appStore.sessionCache.clear();
    if (_walletService.hasWallet()) {
      await _walletService.deleteCurrentWallet();
      _settingsService.setTermsAccepted(false);
    }
    emit(
      HomeState(
        hasWallet: false,
        openWallet: null,
        isLoadingWallet: false,
        isFiatServiceAvailable: false,
        softwareTermsAccepted: state.softwareTermsAccepted,
      ),
    );
  }

  Future<void> _onLoadWallet(LoadWalletEvent event, Emitter<HomeState> emit) async {
    _updateWallet(event.wallet);
    emit(state.copyWith(hasWallet: true, openWallet: _appStore.wallet, isLoadingWallet: false));
    await _setupFiatService(emit);
  }

  void _onSyncWalletServices(
    SyncWalletServicesEvent event,
    Emitter<HomeState> emit,
  ) => _updateWallet(event.wallet);

  void _onCompleteOnboarding(HomeEvent event, Emitter<HomeState> emit) {
    _settingsService.setTermsAccepted(true);
    emit(state.copyWith(onboardingCompleted: true));
  }

  void _onAcceptSoftwareTerms(AcceptSoftwareTermsEvent event, Emitter<HomeState> emit) {
    _settingsService.setSoftwareTermsAccepted(true);
    emit(state.copyWith(softwareTermsAccepted: true));
  }

  Future<void> _onDebugAuthComplete(DebugAuthCompleteEvent event, Emitter<HomeState> emit) async {
    final wallet = await _walletService.createDebugWallet(event.address);
    _appStore.wallet = wallet;
    emit(state.copyWith(hasWallet: true, openWallet: wallet));
    await _setupFiatService(emit);
  }

  Future<void> _setupFiatService(Emitter<HomeState> emit) async {
    if (_appStore.wallet.currentAccount.primaryAddress is BitboxCredentials) {
      // bitbox_flutter's ETHSignMessage panics on a NACK and crashes the engine.
      emit(state.copyWith(isFiatServiceAvailable: false));
      return;
    }
    try {
      await _dfxService.getAuthToken();
      emit(state.copyWith(isFiatServiceAvailable: _dfxService.isAvailable));
    } catch (e) {
      developer.log('Failed to authenticate with DFX service', error: e);
      emit(state.copyWith(isFiatServiceAvailable: false));
    }
  }

  void _updateWallet(AWallet wallet) {
    _appStore.wallet = wallet;
    _balanceService.updateBalance(_appStore.primaryAddress);
    _balanceService.startSync(_appStore.primaryAddress);
    _transactionHistoryService.apiBasedSync();
  }
}
