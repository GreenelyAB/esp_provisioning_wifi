import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saveeye_provisioning/saveeye_provisioning.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('flutter_esp_ble_prov');
  final prov = FlutterEspBleProv();
  final calls = <MethodCall>[];

  void reply(Future<Object?> Function(MethodCall call) handler) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) {
      calls.add(call);
      return handler(call);
    });
  }

  tearDown(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('scanBleDevices returns the advertised names', () async {
    reply((_) async => ['SAVEEYE_1', 'SAVEEYE_2']);

    expect(await prov.scanBleDevices('SAVEEYE_'), ['SAVEEYE_1', 'SAVEEYE_2']);
    expect(calls.single.arguments, {'prefix': 'SAVEEYE_'});
  });

  test('scanBleDevices treats no reply as an empty scan', () async {
    reply((_) async => null);

    expect(await prov.scanBleDevices('SAVEEYE_'), isEmpty);
  });

  test('scanWifiNetworks parses ssid, rssi and auth', () async {
    reply((_) async => [
          {'ssid': 'Home', 'rssi': -58, 'auth': 'wpa2_psk'},
          {'ssid': 'Cafe', 'rssi': -80, 'auth': 'open'},
        ]);

    expect(await prov.scanWifiNetworks('SAVEEYE_1', 'pop'), const [
      EspWifiNetwork(ssid: 'Home', rssi: -58, auth: 'wpa2_psk'),
      EspWifiNetwork(ssid: 'Cafe', rssi: -80, auth: 'open'),
    ]);
    expect(calls.single.arguments,
        {'deviceName': 'SAVEEYE_1', 'proofOfPossession': 'pop'});
  });

  test('scanWifiNetworks rejects a malformed entry with code failed', () async {
    reply((_) async => [
          {'ssid': 'Home', 'auth': 'wpa2_psk'},
        ]);

    expect(
      prov.scanWifiNetworks('SAVEEYE_1', 'pop'),
      throwsA(isA<PlatformException>()
          .having((e) => e.code, 'code', 'failed')),
    );
  });

  test('provisionWifi completes on a null reply', () async {
    reply((_) async => null);

    await prov.provisionWifi('SAVEEYE_1', 'pop', 'Home', 'secret');
    expect(calls.single.method, 'provisionWifi');
    expect(calls.single.arguments, {
      'deviceName': 'SAVEEYE_1',
      'proofOfPossession': 'pop',
      'ssid': 'Home',
      'passphrase': 'secret',
    });
  });

  test('provisionWifi passes native error codes through', () async {
    reply((_) async => throw PlatformException(code: 'auth_failed'));

    expect(
      prov.provisionWifi('SAVEEYE_1', 'pop', 'Home', 'wrong'),
      throwsA(isA<PlatformException>()
          .having((e) => e.code, 'code', 'auth_failed')),
    );
  });
}
