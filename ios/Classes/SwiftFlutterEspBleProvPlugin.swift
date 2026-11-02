import CoreBluetooth
import ESPProvision
import Flutter
import UIKit

/// `FlutterError.code` values shared with the Dart side and the Android plugin.
private enum ErrorCode: String {
    case scanStartFailed = "scan_start_failed"
    case scanFailed = "scan_failed"
    case notFound = "not_found"
    case connectFailed = "connect_failed"
    case deviceDisconnected = "device_disconnected"
    case authFailed = "auth_failed"
    case networkNotFound = "network_not_found"
    case permissionDenied = "permission_denied"
    case failed = "failed"
}

/// Answers a Flutter call exactly once, on the main thread. Late or duplicate answers from the
/// ESPProvision callbacks are dropped.
private final class Reply {
    private let result: FlutterResult
    private let lock = NSLock()
    private var isAnswered = false

    init(_ result: @escaping FlutterResult) {
        self.result = result
    }

    func success(_ value: Any?) {
        answer(value)
    }

    func error(_ code: ErrorCode, _ message: String?) {
        answer(FlutterError(code: code.rawValue, message: message, details: nil))
    }

    private func answer(_ value: Any?) {
        lock.lock()
        if isAnswered {
            lock.unlock()
            return
        }
        isAnswered = true
        lock.unlock()
        onMain { self.result(value) }
    }
}

private func onMain(_ block: @escaping () -> Void) {
    if Thread.isMainThread {
        block()
    } else {
        DispatchQueue.main.async(execute: block)
    }
}

/// The Bluetooth link to one device. Main-thread confined; replaced, never reused, once it fails.
private final class Link {
    let deviceName: String
    let proofOfPossession: String
    let device: ESPDevice
    /// Connected with an established secure session.
    var isReady = false
    /// The call waiting on this link, if any.
    var reply: Reply?
    /// Auth modes from the latest Wi-Fi scan over this link, by SSID.
    var authBySsid: [String: WifiAuthMode] = [:]

    init(deviceName: String, proofOfPossession: String, device: ESPDevice) {
        self.deviceName = deviceName
        self.proofOfPossession = proofOfPossession
        self.device = device
    }
}

/// Reports link drops of one `Link` back to the plugin.
private final class LinkObserver: ESPBLEDelegate {
    weak var plugin: SwiftFlutterEspBleProvPlugin?
    weak var link: Link?

    init(plugin: SwiftFlutterEspBleProvPlugin, link: Link) {
        self.plugin = plugin
        self.link = link
    }

    func peripheralConnected() {}

    func peripheralDisconnected(peripheral: CBPeripheral, error: Error?) {
        onMain { [weak self] in
            guard let self, let link = self.link else { return }
            self.plugin?.linkDropped(link, error: error)
        }
    }

    func peripheralFailedToConnect(peripheral: CBPeripheral?, error: Error?) {
        onMain { [weak self] in
            guard let self, let link = self.link else { return }
            self.plugin?.linkDropped(link, error: error)
        }
    }
}

/// Reads the Bluetooth radio state without showing the system power alert.
private final class BluetoothState: NSObject, CBCentralManagerDelegate {
    private var manager: CBCentralManager?
    private var waiters: [(CBManagerState) -> Void] = []

    /// Calls [completion] with the first settled state (not unknown or resetting).
    func current(_ completion: @escaping (CBManagerState) -> Void) {
        if let manager, manager.state != .unknown, manager.state != .resetting {
            completion(manager.state)
            return
        }
        waiters.append(completion)
        if manager == nil {
            manager = CBCentralManager(
                delegate: self,
                queue: .main,
                options: [CBCentralManagerOptionShowPowerAlertKey: false]
            )
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central.state != .unknown, central.state != .resetting else { return }
        let pending = waiters
        waiters = []
        pending.forEach { $0(central.state) }
    }
}

/// Flutter plugin over the Espressif ESPProvision library. Plugin state is main-thread confined.
public class SwiftFlutterEspBleProvPlugin: NSObject, FlutterPlugin {
    /// Username for security scheme 2, the ESP-IDF default.
    private static let sec2Username = "wifiprov"
    /// How long a Wi-Fi scan waits for a list after the library reported an interim error.
    private static let wifiScanErrorGrace: TimeInterval = 10

    private let bluetooth = BluetoothState()
    /// Devices from the latest BLE scan, by advertised name.
    private var devices: [String: ESPDevice] = [:]
    /// The answer for the BLE scan in progress.
    private var scanReply: Reply?
    fileprivate var link: Link?
    private var linkObserver: LinkObserver?
    /// Bumped by every call that needs a link; a slower device lookup for an older call yields.
    private var linkRequest = 0

    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "flutter_esp_ble_prov", binaryMessenger: registrar.messenger())
        let instance = SwiftFlutterEspBleProvPlugin()
        registrar.addMethodCallDelegate(instance, channel: channel)
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let reply = Reply(result)
        let arguments = call.arguments as? [String: Any] ?? [:]
        func string(_ name: String) -> String? {
            guard let value = arguments[name] as? String else {
                reply.error(.failed, "Missing argument: \(name)")
                return nil
            }
            return value
        }

        switch call.method {
        case "getPlatformVersion":
            reply.success("iOS " + UIDevice.current.systemVersion)
        case "scanBleDevices":
            guard let prefix = string("prefix") else { return }
            whenBluetoothOn(reply, unavailable: .scanStartFailed) {
                self.scanBleDevices(prefix: prefix, reply: reply)
            }
        case "scanWifiNetworks":
            guard let deviceName = string("deviceName"),
                  let pop = string("proofOfPossession") else { return }
            whenBluetoothOn(reply, unavailable: .connectFailed) {
                self.scanWifiNetworks(deviceName: deviceName, pop: pop, reply: reply)
            }
        case "provisionWifi":
            guard let deviceName = string("deviceName"),
                  let pop = string("proofOfPossession"),
                  let ssid = string("ssid"),
                  let passphrase = string("passphrase") else { return }
            whenBluetoothOn(reply, unavailable: .connectFailed) {
                self.provisionWifi(deviceName: deviceName, pop: pop, ssid: ssid, passphrase: passphrase, reply: reply)
            }
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - Bluetooth state

    /// Runs [block] when Bluetooth is authorized and on; answers `permission_denied` when it is
    /// not authorized and [unavailable] when it is off or unsupported.
    private func whenBluetoothOn(_ reply: Reply, unavailable: ErrorCode, block: @escaping () -> Void) {
        bluetooth.current { state in
            switch state {
            case .poweredOn:
                block()
            case .unauthorized:
                reply.error(.permissionDenied, "Bluetooth permission not granted")
            default:
                reply.error(unavailable, "Bluetooth is unavailable (state \(state.rawValue))")
            }
        }
    }

    // MARK: - BLE scan

    /// One scan window of ESPProvision (5 s).
    private func scanBleDevices(prefix: String, reply: Reply) {
        stopBleScan()
        // A connected device stops advertising.
        closeLink(.deviceDisconnected, "Closed for a new BLE scan")
        scanReply = reply
        ESPProvisionManager.shared.searchESPDevices(devicePrefix: prefix, transport: .ble, security: .secure) { found, error in
            onMain {
                if self.scanReply === reply {
                    self.scanReply = nil
                }
                if let error {
                    if case .espDeviceNotFound = error {
                        reply.success([String]())
                    } else {
                        reply.error(.scanFailed, error.description)
                    }
                    return
                }
                let matching = (found ?? []).filter { $0.name.hasPrefix(prefix) }
                for device in matching {
                    self.devices[device.name] = device
                }
                reply.success(matching.map { $0.name })
            }
        }
    }

    /// Stops the scan in progress; its call is answered with an empty list.
    private func stopBleScan() {
        guard scanReply != nil else { return }
        ESPProvisionManager.shared.stopESPDevicesSearch()
        scanReply = nil
    }

    // MARK: - Wi-Fi scan

    private func scanWifiNetworks(deviceName: String, pop: String, reply: Reply) {
        withLink(deviceName: deviceName, pop: pop, reply: reply) { link in
            self.scanWifiList(link: link, attemptsLeft: 3, reply: reply)
        }
    }

    /// ESPProvision can report an interim error and deliver the list afterwards, and reports an
    /// empty result when its status read lands before the device finished scanning
    /// (espressif/esp-idf-provisioning-ios#74), so empty scans are retried and an error only
    /// counts once no list followed it within `wifiScanErrorGrace`.
    private func scanWifiList(link: Link, attemptsLeft: Int, reply: Reply) {
        var isSettled = false
        var lastError: ESPWiFiScanError?
        link.device.scanWifiList { list, error in
            onMain {
                guard !isSettled, self.link === link else { return }
                if let list, !list.isEmpty {
                    isSettled = true
                    self.finishWifiScan(link: link, networks: list, reply: reply)
                    return
                }
                if let error, !Self.isEmptyResult(error) {
                    if lastError == nil {
                        DispatchQueue.main.asyncAfter(deadline: .now() + Self.wifiScanErrorGrace) {
                            guard !isSettled, self.link === link else { return }
                            isSettled = true
                            self.closeLink(.scanFailed, lastError?.description ?? "Wi-Fi scan failed")
                        }
                    }
                    lastError = error
                    return
                }
                isSettled = true
                if attemptsLeft > 1 {
                    self.scanWifiList(link: link, attemptsLeft: attemptsLeft - 1, reply: reply)
                } else {
                    self.finishWifiScan(link: link, networks: [], reply: reply)
                }
            }
        }
    }

    private static func isEmptyResult(_ error: ESPWiFiScanError) -> Bool {
        if case .emptyResultCount = error {
            return true
        }
        return false
    }

    private func finishWifiScan(link: Link, networks: [ESPWifiNetwork], reply: Reply) {
        link.reply = nil
        link.authBySsid = Dictionary(networks.map { ($0.ssid, $0.auth) }, uniquingKeysWith: { first, _ in first })
        reply.success(networks.map { network -> [String: Any] in
            ["ssid": network.ssid, "rssi": Int(network.rssi), "auth": network.auth.wireName]
        })
    }

    // MARK: - Provisioning

    private func provisionWifi(deviceName: String, pop: String, ssid: String, passphrase: String, reply: Reply) {
        withLink(deviceName: deviceName, pop: pop, reply: reply) { link in
            let isOpen = link.authBySsid[ssid].map { $0 == .open } ?? passphrase.isEmpty
            link.device.provision(ssid: ssid, passPhrase: passphrase) { status in
                onMain {
                    guard self.link === link else { return }
                    switch status {
                    case .success:
                        self.provisioned(link: link, reply: reply)
                    case .configApplied:
                        // An open network may never report a station state.
                        if isOpen {
                            self.provisioned(link: link, reply: reply)
                        }
                    case .failure(let error):
                        self.provisionFailed(link: link, error: error, reply: reply)
                    }
                }
            }
        }
    }

    private func provisioned(link: Link, reply: Reply) {
        link.reply = nil
        reply.success(nil)
        // The device switches to the Wi-Fi network; the link has no further use.
        closeLink(.deviceDisconnected, "Provisioned")
    }

    private func provisionFailed(link: Link, error: ESPProvisionError, reply: Reply) {
        NSLog("FlutterEspBleProv: provisioning failed: \(error.description)")
        let code: ErrorCode
        switch error {
        case .wifiStatusAuthenticationError:
            code = .authFailed
        case .wifiStatusNetworkNotFound:
            code = .networkNotFound
        case .wifiStatusDisconnected, .sessionError:
            code = .deviceDisconnected
        case .configurationError(let cause), .wifiStatusError(let cause):
            code = cause is ESPSessionError ? .deviceDisconnected : .failed
        default:
            code = .failed
        }
        if code == .deviceDisconnected {
            closeLink(code, error.description)
        } else {
            link.reply = nil
            reply.error(code, error.description)
        }
    }

    // MARK: - Link

    /// Runs [block] once a ready link to [deviceName] exists, connecting first when needed. A call
    /// still waiting on the current link was abandoned by Dart (it times out its calls), so that
    /// link is presumed stuck and replaced.
    private func withLink(deviceName: String, pop: String, reply: Reply, block: @escaping (Link) -> Void) {
        stopBleScan()
        if let current = link, current.reply == nil, current.isReady,
           current.deviceName == deviceName, current.proofOfPossession == pop,
           current.device.isSessionEstablished() {
            current.reply = reply
            block(current)
            return
        }
        closeLink(.deviceDisconnected, "Superseded by a new call")
        linkRequest += 1
        let request = linkRequest
        resolveDevice(deviceName: deviceName) { device in
            guard request == self.linkRequest else {
                reply.error(.deviceDisconnected, "Superseded by a new call")
                return
            }
            guard let device else {
                reply.error(.notFound, "\(deviceName) was not found")
                return
            }
            self.connect(device: device, deviceName: deviceName, pop: pop, reply: reply, block: block)
        }
    }

    /// The device from the latest BLE scan, or a fresh scan for its name.
    private func resolveDevice(deviceName: String, completion: @escaping (ESPDevice?) -> Void) {
        if let device = devices[deviceName] {
            completion(device)
            return
        }
        // ESPProvision can report the end of its scan more than once.
        var isResolved = false
        ESPProvisionManager.shared.createESPDevice(
            deviceName: deviceName,
            transport: .ble,
            security: .secure,
            proofOfPossession: nil,
            username: nil
        ) { device, _ in
            onMain {
                guard !isResolved else { return }
                isResolved = true
                let match = device.flatMap { $0.name == deviceName ? $0 : nil }
                if let match {
                    self.devices[deviceName] = match
                }
                completion(match)
            }
        }
    }

    /// Connects with the scheme the device reports in its version info (`sec_ver`), sec1 for
    /// firmware that predates it. ESPProvision skips the proof of possession for sec1 devices
    /// with the `no_pop` capability.
    private func connect(device: ESPDevice, deviceName: String, pop: String, reply: Reply, block: @escaping (Link) -> Void) {
        let next = Link(deviceName: deviceName, proofOfPossession: pop, device: device)
        next.reply = reply
        link = next
        let observer = LinkObserver(plugin: self, link: next)
        linkObserver = observer
        device.security = .secure
        device.proofOfPossession = pop
        device.username = Self.sec2Username
        device.bleDelegate = observer
        device.connect(delegate: self) { status in
            onMain {
                guard self.link === next, !next.isReady else { return }
                switch status {
                case .connected:
                    next.isReady = true
                    block(next)
                case .failedToConnect(let error):
                    self.closeLink(.connectFailed, error.description)
                case .disconnected:
                    self.closeLink(.connectFailed, "Disconnected while connecting")
                }
            }
        }
    }

    fileprivate func linkDropped(_ dropped: Link, error: Error?) {
        guard link === dropped else { return }
        closeLink(dropped.isReady ? .deviceDisconnected : .connectFailed,
                  error?.localizedDescription ?? "Bluetooth link lost")
    }

    /// Disconnects the current link and answers the call waiting on it with [code].
    private func closeLink(_ code: ErrorCode, _ message: String?) {
        guard let current = link else { return }
        link = nil
        linkObserver = nil
        current.device.bleDelegate = nil
        current.reply?.error(code, message)
        current.reply = nil
        current.device.disconnect()
    }
}

extension SwiftFlutterEspBleProvPlugin: ESPDeviceConnectionDelegate {
    public func getProofOfPossesion(forDevice: ESPDevice, completionHandler: @escaping (String) -> Void) {
        completionHandler(link?.proofOfPossession ?? "")
    }

    public func getUsername(forDevice: ESPDevice, completionHandler: @escaping (String?) -> Void) {
        completionHandler(Self.sec2Username)
    }
}

private extension WifiAuthMode {
    /// Snake-case name shared with the Android plugin.
    var wireName: String {
        switch self {
        case .open: return "open"
        case .wep: return "wep"
        case .wpaPsk: return "wpa_psk"
        case .wpa2Psk: return "wpa2_psk"
        case .wpaWpa2Psk: return "wpa_wpa2_psk"
        case .wpa2Enterprise: return "wpa2_enterprise"
        case .wpa3Psk: return "wpa3_psk"
        case .wpa2Wpa3Psk: return "wpa2_wpa3_psk"
        case .UNRECOGNIZED: return "unknown"
        }
    }
}
