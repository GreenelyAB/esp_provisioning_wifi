/// Wi-Fi provisioning of ESP32 devices over BLE.
///
/// Every failure surfaces as a `PlatformException` whose `code` is one of
/// `scan_start_failed`, `scan_failed`, `not_found`, `connect_failed`,
/// `device_disconnected`, `auth_failed`, `network_not_found`,
/// `permission_denied` or `failed`.
library;

export 'src/flutter_esp_ble_prov/esp_wifi_network.dart';
export 'src/flutter_esp_ble_prov/flutter_esp_ble_prov.dart';
