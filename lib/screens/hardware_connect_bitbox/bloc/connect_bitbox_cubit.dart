import 'dart:async';
import 'dart:developer' as developer;

import 'package:bitbox_flutter/bitbox_flutter.dart' as sdk;
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:realunit_wallet/packages/hardware_wallet/bitbox.dart';
import 'package:realunit_wallet/packages/service/wallet_service.dart';
import 'package:realunit_wallet/packages/utils/device_info.dart';
import 'package:realunit_wallet/packages/wallet/wallet.dart';

part 'connect_bitbox_state.dart';

class ConnectBitboxCubit extends Cubit<BitboxConnectionState> {
  ConnectBitboxCubit(this._service, this._walletService) : super(BitboxNotConnected()) {
    _startScanning();
  }

  Future<void> _startScanning() async {
    if (DeviceInfo.instance.isIOS) await _service.startScan();
    _checkForTimer = Timer.periodic(const Duration(milliseconds: 500), (_) => checkForBitbox());
  }

  final BitboxService _service;
  final WalletService _walletService;
  Timer? _checkForTimer;
  Future<bool>? _pendingInit;

  Future<void> checkForBitbox() async {
    final devices = await _service.getAllUsbDevices();
    if (isClosed) return;
    if (devices.isNotEmpty) {
      emit(BitboxFound(devices.first));
      _checkForTimer?.cancel();
      connectToBitbox(devices.first);
    }
  }

  Future<void> connectToBitbox(sdk.BitboxDevice device) async {
    if (state is BitboxConnecting) return;
    emit(BitboxConnecting(device));
    try {
      var initFailed = false;
      _pendingInit = _service
          .init(device)
          .then((success) {
            if (!success) initFailed = true;
            return success;
          })
          .catchError((Object e) {
            developer.log('init error: $e', name: '$ConnectBitboxCubit');
            initFailed = true;
            return false;
          });

      String channelHash = '';
      final deadline = DateTime.now().add(const Duration(seconds: 90));
      while (channelHash.isEmpty && DateTime.now().isBefore(deadline) && !isClosed) {
        await Future.delayed(const Duration(milliseconds: 500));
        if (isClosed) return;
        if (initFailed) throw Exception('init failed');
        try {
          final hash = await _service.getChannelHash().timeout(const Duration(seconds: 2));
          if (hash.isNotEmpty) channelHash = hash;
        } catch (_) {}
      }

      if (isClosed) return;

      if (channelHash.isEmpty) throw TimeoutException('no channel hash within 90s');

      emit(BitboxCheckHash(device, channelHash));
    } catch (e) {
      developer.log(e.toString(), name: '$ConnectBitboxCubit');
      _pendingInit = null;
      if (isClosed) return;
      emit(BitboxNotConnected());
      _checkForTimer = Timer.periodic(const Duration(milliseconds: 500), (_) => checkForBitbox());
    }
  }

  Future<void> confirmPairing() async {
    final currentState = state;
    if (currentState is! BitboxCheckHash) return;

    try {
      emit(BitboxPairing(currentState.device));
      final initOk = await (_pendingInit ?? Future.value(true)).timeout(
        const Duration(seconds: 120),
        onTimeout: () => false,
      );
      if (!initOk) throw Exception('pairing not confirmed on device');
      await _service.confirmPairing();
      final wallet = await _walletService.createBitboxWallet('Luke-Skywallet');
      _service.startConnectionStatusObserver();
      emit(BitboxConnected(wallet));
    } catch (e) {
      developer.log(e.toString(), name: '$ConnectBitboxCubit');
      _pendingInit = null;
      if (isClosed) return;
      emit(BitboxNotConnected());
      _checkForTimer = Timer.periodic(const Duration(milliseconds: 500), (_) => checkForBitbox());
    }
  }

  void finishSetup() {
    final currentState = state;
    if (currentState is! BitboxConnected) return;
    emit(BitboxFinishSetup(currentState.wallet));
  }

  @override
  Future<void> close() {
    _checkForTimer?.cancel();
    _pendingInit = null;
    return super.close();
  }
}
