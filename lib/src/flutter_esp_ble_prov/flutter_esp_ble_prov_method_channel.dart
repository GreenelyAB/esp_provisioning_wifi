import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'esp_wifi_network.dart';
import 'flutter_esp_ble_prov_platform_interface.dart';

/// An implementation of [FlutterEspBleProvPlatform] that uses method channels.
class MethodChannelFlutterEspBleProv extends FlutterEspBleProvPlatform {
  /// The method channel used to interact with the native platform.
  @visibleForTesting
  final methodChannel = const MethodChannel('flutter_esp_ble_prov');

  @override
  Future<String?> getPlatformVersion() async {
    final version =
        await methodChannel.invokeMethod<String>('getPlatformVersion');
    return version;
  }

  @override
  Future<List<String>> scanBleDevices(String prefix) async {
    final args = {'prefix': prefix};
    final raw =
        await methodChannel.invokeMethod<List<Object?>>('scanBleDevices', args);
    if (raw == null) return const [];
    return [
      for (final name in raw)
        if (name is String) name else throw _malformed('device name', name),
    ];
  }

  @override
  Future<List<EspWifiNetwork>> scanWifiNetworks(
      String deviceName, String proofOfPossession) async {
    final args = {
      'deviceName': deviceName,
      'proofOfPossession': proofOfPossession,
    };
    final raw = await methodChannel.invokeMethod<List<Object?>>(
        'scanWifiNetworks', args);
    if (raw == null) return const [];
    return [for (final entry in raw) _parseNetwork(entry)];
  }

  @override
  Future<void> provisionWifi(String deviceName, String proofOfPossession,
      String ssid, String passphrase) async {
    final args = {
      'deviceName': deviceName,
      'proofOfPossession': proofOfPossession,
      'ssid': ssid,
      'passphrase': passphrase
    };
    await methodChannel.invokeMethod<void>('provisionWifi', args);
  }

  @override
  Future<void> disconnect() async {
    await methodChannel.invokeMethod<void>('disconnect');
  }

  static EspWifiNetwork _parseNetwork(Object? entry) {
    if (entry is Map) {
      final ssid = entry['ssid'];
      final rssi = entry['rssi'];
      final auth = entry['auth'];
      if (ssid is String && rssi is num && auth is String) {
        return EspWifiNetwork(ssid: ssid, rssi: rssi.toInt(), auth: auth);
      }
    }
    throw _malformed('Wi-Fi network', entry);
  }

  static PlatformException _malformed(String what, Object? value) =>
      PlatformException(
        code: 'failed',
        message: 'Malformed $what from the native plugin: $value',
      );
}
