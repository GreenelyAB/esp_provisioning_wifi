/// A Wi-Fi network as reported by the ESP device's own scan.
class EspWifiNetwork {
  const EspWifiNetwork({
    required this.ssid,
    required this.rssi,
    required this.auth,
  });

  /// Network name.
  final String ssid;

  /// Signal strength in dBm as seen by the device, e.g. `-58`.
  final int rssi;

  /// Snake-case auth mode: `open`, `wep`, `wpa_psk`, `wpa2_psk`,
  /// `wpa_wpa2_psk`, `wpa2_enterprise`, `wpa3_psk`, `wpa2_wpa3_psk` or
  /// `unknown`.
  final String auth;

  @override
  bool operator ==(Object other) =>
      other is EspWifiNetwork &&
      other.ssid == ssid &&
      other.rssi == rssi &&
      other.auth == auth;

  @override
  int get hashCode => Object.hash(ssid, rssi, auth);

  @override
  String toString() => 'EspWifiNetwork(ssid: $ssid, rssi: $rssi, auth: $auth)';
}
