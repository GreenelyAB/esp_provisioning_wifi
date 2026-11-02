## 0.0.1

First release

## 0.0.2

Fixed podspec

## 0.0.3

More podspec fixes

## 0.0.4

Renaming

## 0.0.5

Widened permission_handler constraint to allow 12.x (`>=11.3.0 <13.0.0`). Bumped Android compileSdkVersion to 35.

## 0.1.0

Greenely fork. Breaking API changes:

- New entrypoint `package:saveeye_provisioning/saveeye_provisioning.dart`
  exporting `FlutterEspBleProv` and `EspWifiNetwork`.
- `scanWifiNetworks` returns `List<EspWifiNetwork>` (`ssid`, `rssi`, `auth`
  as a snake-case auth mode) instead of SSID strings.
- `provisionWifi` returns `Future<void>` and throws instead of returning
  `false`.
- Every failure is a `PlatformException` with code `scan_start_failed`,
  `scan_failed`, `not_found`, `connect_failed`, `device_disconnected`,
  `auth_failed`, `network_not_found`, `permission_denied` or `failed`.

Native changes:

- Security scheme (sec0/1/2) follows the device's version info; sec2 uses
  the `wifiprov` username, and the proof of possession is skipped for
  `no_pop` devices.
- The Bluetooth link opened for a Wi-Fi scan is reused for provisioning.
- Each call is answered exactly once, on the main thread.
- Android: esp-idf-provisioning-android lib-2.4.4, Java/Kotlin 17, reports
  denied permissions (Android 12+ also requires `ACCESS_FINE_LOCATION`).
- iOS: ESPProvision `~> 3.2.0`; no force casts on call arguments.

## 0.2.0

- `disconnect()` stops any BLE scan and closes the current Bluetooth link; a
  call still waiting on the link fails with `device_disconnected`. It
  completes without error when nothing is connected.
