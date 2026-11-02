import 'esp_wifi_network.dart';
import 'flutter_esp_ble_prov_platform_interface.dart';

/// Provisions ESP32 devices with Wi-Fi credentials over BLE.
///
/// Every call is a single attempt; retries and timeouts belong to the caller.
/// Failures throw a `PlatformException` whose `code` is one of
/// `scan_start_failed`, `scan_failed`, `not_found`, `connect_failed`,
/// `device_disconnected`, `auth_failed`, `network_not_found`,
/// `permission_denied` or `failed`.
class FlutterEspBleProv {
  /// Runs one BLE scan window and returns the advertised names that start
  /// with [prefix]. An empty list means no device was found.
  Future<List<String>> scanBleDevices(String prefix) {
    return FlutterEspBleProvPlatform.instance.scanBleDevices(prefix);
  }

  /// Connects to [deviceName] with [proofOfPossession] and returns the Wi-Fi
  /// networks the device can see, open networks included.
  ///
  /// The security scheme (sec1 or sec2) follows the device's reported
  /// version info; the proof of possession is skipped when the device
  /// advertises the `no_pop` capability.
  Future<List<EspWifiNetwork>> scanWifiNetworks(
      String deviceName, String proofOfPossession) {
    return FlutterEspBleProvPlatform.instance
        .scanWifiNetworks(deviceName, proofOfPossession);
  }

  /// Sends [ssid] and [passphrase] to [deviceName] and completes once the
  /// device reports it joined the network.
  Future<void> provisionWifi(String deviceName, String proofOfPossession,
      String ssid, String passphrase) {
    return FlutterEspBleProvPlatform.instance
        .provisionWifi(deviceName, proofOfPossession, ssid, passphrase);
  }

  /// Stops any BLE scan and closes the link to the current device, if any.
  ///
  /// A call still waiting on that link fails with `device_disconnected`.
  /// Completes without error when nothing is connected.
  Future<void> disconnect() {
    return FlutterEspBleProvPlatform.instance.disconnect();
  }

  /// Returns the native platform version.
  Future<String?> getPlatformVersion() {
    return FlutterEspBleProvPlatform.instance.getPlatformVersion();
  }
}
