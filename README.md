# saveeye_provisioning

Flutter plugin that provisions ESP32 devices (SaveEye meters) with Wi-Fi
credentials over Bluetooth LE. It wraps Espressif's
[esp-idf-provisioning-android](https://github.com/espressif/esp-idf-provisioning-android)
(lib-2.4.4) and [ESPProvision for iOS](https://github.com/espressif/esp-idf-provisioning-ios)
(3.2.x).

This is Greenely's fork of
[saveeye/esp_provisioning_wifi](https://github.com/saveeye/esp_provisioning_wifi).

## Usage

```dart
import 'package:flutter/services.dart';
import 'package:saveeye_provisioning/saveeye_provisioning.dart';

final prov = FlutterEspBleProv();

// One BLE scan window; an empty list means nothing was found.
final List<String> names = await prov.scanBleDevices('SAVEEYE_');

// Connects and lists the networks the device sees, open networks included.
final List<EspWifiNetwork> networks =
    await prov.scanWifiNetworks(names.first, proofOfPossession);
// EspWifiNetwork(ssid: 'Home', rssi: -58, auth: 'wpa2_psk')

try {
  // Completes once the device reports it joined the network.
  await prov.provisionWifi(names.first, proofOfPossession, 'Home', password);
} on PlatformException catch (e) {
  if (e.code == 'auth_failed') {
    // Wrong password.
  }
}
```

Every call is a single attempt with no timeout of its own: callers own
retries and timeouts. The connection opened by `scanWifiNetworks` is reused by
a following `provisionWifi` for the same device and proof of possession, and
replaced when a call on it is still pending (the caller gave up on it).

`EspWifiNetwork.auth` is one of `open`, `wep`, `wpa_psk`, `wpa2_psk`,
`wpa_wpa2_psk`, `wpa2_enterprise`, `wpa3_psk`, `wpa2_wpa3_psk` or `unknown`.

The security scheme follows the version info the device reports: `sec_ver`
0, 1 or 2 (sec1 for firmware without `sec_ver`). Sec2 uses the username
`wifiprov`; the proof of possession is skipped for devices with the `no_pop`
capability.

### Errors

Every failure is a `PlatformException` whose `code` is one of:

| Code | Meaning |
| --- | --- |
| `scan_start_failed` | The BLE scan could not start, usually because Bluetooth is off. |
| `scan_failed` | The BLE scan or the device's Wi-Fi scan failed. |
| `not_found` | The device was not seen by a BLE scan. |
| `connect_failed` | Connecting or establishing the secure session failed. |
| `device_disconnected` | The Bluetooth link dropped during a call. |
| `auth_failed` | The device rejected the Wi-Fi password. |
| `network_not_found` | The device could not find the Wi-Fi network. |
| `permission_denied` | Bluetooth (or, on Android, location) permission is missing. |
| `failed` | Anything else, including malformed arguments. |

## Requirements

### Android 6 (API level 23)+

The Espressif library is published on JitPack. Add it to the app's
repositories:

```groovy
allprojects {
    repositories {
        // ...
        maven { url 'https://jitpack.io' }
    }
}
```

The plugin declares the Bluetooth and location permissions it needs and
requests missing ones before each call: `BLUETOOTH_SCAN`, `BLUETOOTH_CONNECT`
and `ACCESS_FINE_LOCATION` on Android 12+, `ACCESS_FINE_LOCATION` below.

### iOS 13.0+

Add this to `ios/Runner/Info.plist`:

```xml
<key>NSBluetoothAlwaysUsageDescription</key>
<string>Our app uses Bluetooth to find and set up your meter.</string>
```

## Bundled bloc

`EspProvisioningBloc` (`package:saveeye_provisioning/esp_provisioning_bloc.dart`)
is a thin [Bloc](https://pub.dev/packages/flutter_bloc) wrapper over the API
above, kept from the upstream package.
