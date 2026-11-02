package how.virc.flutter_esp_ble_prov

import android.Manifest
import android.annotation.SuppressLint
import android.app.Activity
import android.bluetooth.BluetoothDevice
import android.bluetooth.le.ScanResult
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import com.espressif.provisioning.DeviceConnectionEvent
import com.espressif.provisioning.ESPConstants
import com.espressif.provisioning.ESPConstants.ProvisionFailureReason
import com.espressif.provisioning.ESPConstants.SecurityType
import com.espressif.provisioning.ESPDevice
import com.espressif.provisioning.ESPProvisionManager
import com.espressif.provisioning.WiFiAccessPoint
import com.espressif.provisioning.listeners.BleScanListener
import com.espressif.provisioning.listeners.ProvisionListener
import com.espressif.provisioning.listeners.ResponseListener
import com.espressif.provisioning.listeners.WiFiScanListener
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import io.flutter.plugin.common.PluginRegistry
import org.greenrobot.eventbus.EventBus
import org.greenrobot.eventbus.Subscribe
import org.greenrobot.eventbus.ThreadMode
import org.json.JSONObject
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.Future
import java.util.concurrent.atomic.AtomicBoolean

private const val TAG = "FlutterEspBleProv"

/** `PlatformException.code` values shared with the Dart side and the iOS plugin. */
private object ErrorCode {
  const val SCAN_START_FAILED = "scan_start_failed"
  const val SCAN_FAILED = "scan_failed"
  const val NOT_FOUND = "not_found"
  const val CONNECT_FAILED = "connect_failed"
  const val DEVICE_DISCONNECTED = "device_disconnected"
  const val AUTH_FAILED = "auth_failed"
  const val NETWORK_NOT_FOUND = "network_not_found"
  const val PERMISSION_DENIED = "permission_denied"
  const val FAILED = "failed"
}

private val mainHandler = Handler(Looper.getMainLooper())

private fun isMainThread() = Looper.myLooper() == Looper.getMainLooper()

/** Runs [block] on the main thread: inline when already there, posted otherwise. */
private fun onMain(block: () -> Unit) {
  if (isMainThread()) block() else mainHandler.post(block)
}

/**
 * A [Result] that is answered exactly once, always on the main thread. Late or duplicate
 * answers from the Espressif callbacks are dropped.
 */
private class Reply(private val result: Result) {
  private val answered = AtomicBoolean(false)

  val isAnswered: Boolean get() = answered.get()

  fun success(value: Any?) = answer { result.success(value) }

  fun error(code: String, message: String?) = answer { result.error(code, message, null) }

  private fun answer(block: () -> Unit) {
    if (!answered.compareAndSet(false, true)) return
    onMain(block)
  }
}

/** What is needed to connect to a device found by a BLE scan. */
private class BleConnector(val device: BluetoothDevice, val primaryServiceUuid: String)

/**
 * The Bluetooth link to one device. Confined to the main thread. A link is replaced, never
 * reused, once it fails: the Espressif transport can stay blocked on a write that never got an
 * answer.
 */
private class Link(val deviceName: String, val proofOfPossession: String, val esp: ESPDevice) {
  /** The GATT link is up and the secure session is established. */
  var isReady = false

  /** The call waiting on this link, if any. */
  var reply: Reply? = null

  /** Runs once the link is ready. */
  var onReady: ((ESPDevice) -> Unit)? = null

  /** A blocking Espressif call running for this link on the worker pool. */
  var work: Future<*>? = null
}

/**
 * Flutter plugin over the Espressif Android provisioning library.
 *
 * Threading: plugin state lives on the main thread. Espressif calls that write to the device
 * run on [worker], because `BLETransport` parks the calling thread until the device answers;
 * their callbacks are posted back to the main thread and dropped once their [Link] was replaced.
 */
class FlutterEspBleProvPlugin : FlutterPlugin, MethodCallHandler, ActivityAware,
  PluginRegistry.RequestPermissionsResultListener {

  private lateinit var channel: MethodChannel
  private lateinit var context: Context
  private var activityBinding: ActivityPluginBinding? = null
  private val activity: Activity? get() = activityBinding?.activity

  private val worker: ExecutorService = Executors.newCachedThreadPool()
  private val connectionEvents = ConnectionEvents(this)

  private val espManager: ESPProvisionManager get() = ESPProvisionManager.getInstance(context)

  /** Every device seen by a BLE scan, by advertised name. */
  private val devices = mutableMapOf<String, BleConnector>()

  /** The answer for the BLE scan in progress. */
  private var scanReply: Reply? = null

  private var link: Link? = null

  private val permissionWaiters = mutableListOf<(Boolean) -> Unit>()

  // region FlutterPlugin / ActivityAware

  override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    context = binding.applicationContext
    channel = MethodChannel(binding.binaryMessenger, "flutter_esp_ble_prov")
    channel.setMethodCallHandler(this)
    EventBus.getDefault().register(connectionEvents)
  }

  override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    channel.setMethodCallHandler(null)
    stopBleScan()
    closeLink(ErrorCode.DEVICE_DISCONNECTED, "Plugin detached")
    if (EventBus.getDefault().isRegistered(connectionEvents)) {
      EventBus.getDefault().unregister(connectionEvents)
    }
    worker.shutdownNow()
  }

  override fun onAttachedToActivity(binding: ActivityPluginBinding) = attach(binding)

  override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) =
    attach(binding)

  override fun onDetachedFromActivityForConfigChanges() = detach()

  override fun onDetachedFromActivity() = detach()

  private fun attach(binding: ActivityPluginBinding) {
    activityBinding = binding
    binding.addRequestPermissionsResultListener(this)
  }

  private fun detach() {
    activityBinding?.removeRequestPermissionsResultListener(this)
    activityBinding = null
    // A pending permission prompt can't answer anymore.
    finishPermissionRequest(hasPermissions())
  }

  // endregion

  override fun onMethodCall(call: MethodCall, result: Result) {
    Log.d(TAG, "onMethodCall: ${call.method}")
    val reply = Reply(result)
    when (call.method) {
      "getPlatformVersion" -> reply.success("Android ${Build.VERSION.RELEASE}")
      "scanBleDevices" -> {
        val prefix = call.stringArg("prefix", reply) ?: return
        withPermissions(reply) { scanBleDevices(prefix, reply) }
      }
      "scanWifiNetworks" -> {
        val deviceName = call.stringArg("deviceName", reply) ?: return
        val pop = call.stringArg("proofOfPossession", reply) ?: return
        withPermissions(reply) { scanWifiNetworks(deviceName, pop, reply) }
      }
      "provisionWifi" -> {
        val deviceName = call.stringArg("deviceName", reply) ?: return
        val pop = call.stringArg("proofOfPossession", reply) ?: return
        val ssid = call.stringArg("ssid", reply) ?: return
        val passphrase = call.stringArg("passphrase", reply) ?: return
        withPermissions(reply) { provisionWifi(deviceName, pop, ssid, passphrase, reply) }
      }
      else -> result.notImplemented()
    }
  }

  private fun MethodCall.stringArg(name: String, reply: Reply): String? {
    val value = argument<String>(name)
    if (value == null) reply.error(ErrorCode.FAILED, "Missing argument: $name")
    return value
  }

  // region Permissions

  /**
   * Android 12+ needs the nearby-devices permissions plus fine location, as the native apps ask;
   * older versions need fine location for BLE scans.
   */
  private val requiredPermissions: Array<String>
    get() = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
      arrayOf(
        Manifest.permission.BLUETOOTH_SCAN,
        Manifest.permission.BLUETOOTH_CONNECT,
        Manifest.permission.ACCESS_FINE_LOCATION,
      )
    } else {
      arrayOf(Manifest.permission.ACCESS_FINE_LOCATION)
    }

  private fun missingPermissions(): List<String> = requiredPermissions.filter {
    context.checkSelfPermission(it) != PackageManager.PERMISSION_GRANTED
  }

  private fun hasPermissions() = missingPermissions().isEmpty()

  /** Runs [block] once every required permission is granted, prompting for missing ones. */
  private fun withPermissions(reply: Reply, block: () -> Unit) {
    val missing = missingPermissions()
    if (missing.isEmpty()) {
      block()
      return
    }
    val activity = activity
    if (activity == null) {
      reply.error(ErrorCode.PERMISSION_DENIED, "Missing permissions: $missing")
      return
    }
    val isPrompting = permissionWaiters.isNotEmpty()
    permissionWaiters += { granted ->
      if (granted) {
        block()
      } else {
        reply.error(ErrorCode.PERMISSION_DENIED, "Missing permissions: ${missingPermissions()}")
      }
    }
    if (!isPrompting) {
      activity.requestPermissions(missing.toTypedArray(), PERMISSION_REQUEST_CODE)
    }
  }

  override fun onRequestPermissionsResult(
    requestCode: Int,
    permissions: Array<out String>,
    grantResults: IntArray,
  ): Boolean {
    if (requestCode != PERMISSION_REQUEST_CODE) return false
    finishPermissionRequest(hasPermissions())
    return true
  }

  private fun finishPermissionRequest(granted: Boolean) {
    val waiters = permissionWaiters.toList()
    permissionWaiters.clear()
    waiters.forEach { it(granted) }
  }

  // endregion

  // region BLE scan

  /** One scan window of the Espressif `BleScanner` (6 s). */
  @SuppressLint("MissingPermission")
  private fun scanBleDevices(prefix: String, reply: Reply) {
    stopBleScan()
    // A connected device stops advertising.
    closeLink(ErrorCode.DEVICE_DISCONNECTED, "Closed for a new BLE scan")
    scanReply = reply
    val found = linkedSetOf<String>()
    val listener = object : BleScanListener {
      override fun onPeripheralFound(device: BluetoothDevice?, scanResult: ScanResult?) {
        val name = scanResult?.scanRecord?.deviceName ?: return
        val serviceUuid = scanResult.scanRecord?.serviceUuids?.firstOrNull()?.uuid?.toString()
        if (device == null || serviceUuid == null) return
        onMain {
          devices[name] = BleConnector(device, serviceUuid)
          found += name
        }
      }

      override fun scanCompleted() = onMain {
        if (scanReply === reply) scanReply = null
        reply.success(found.toList())
      }

      override fun scanStartFailed() = onMain {
        if (scanReply === reply) scanReply = null
        reply.error(ErrorCode.SCAN_START_FAILED, "Bluetooth is off or the scan could not start")
      }

      override fun onFailure(e: Exception?) = onMain {
        Log.e(TAG, "BLE scan failed", e)
        reply.error(ErrorCode.SCAN_FAILED, e?.message ?: "BLE scan failed")
        if (scanReply === reply) stopBleScan()
      }
    }
    try {
      espManager.searchBleEspDevices(prefix, listener)
    } catch (e: SecurityException) {
      scanReply = null
      reply.error(ErrorCode.PERMISSION_DENIED, e.message)
    } catch (e: Exception) {
      Log.e(TAG, "BLE scan could not start", e)
      scanReply = null
      reply.error(ErrorCode.SCAN_START_FAILED, e.message)
    }
  }

  /** Stops the scan in progress; its call is answered with what it found so far. */
  @SuppressLint("MissingPermission")
  private fun stopBleScan() {
    if (scanReply == null) return
    scanReply = null
    try {
      espManager.stopBleScan()
    } catch (e: Exception) {
      Log.e(TAG, "Failed to stop the BLE scan", e)
    }
  }

  // endregion

  // region Wi-Fi scan and provisioning

  private fun scanWifiNetworks(deviceName: String, pop: String, reply: Reply) {
    withLink(deviceName, pop, reply) { link, esp ->
      runWork(link, ErrorCode.SCAN_FAILED) {
        esp.scanNetworks(object : WiFiScanListener {
          override fun onWifiListReceived(wifiList: ArrayList<WiFiAccessPoint>?) {
            val networks = wifiList.orEmpty().map {
              mapOf(
                "ssid" to it.wifiName.orEmpty(),
                "rssi" to it.rssi,
                "auth" to it.security.asAuthModeName(),
              )
            }
            finish(link) { reply.success(networks) }
          }

          override fun onWiFiScanFailed(e: Exception?) = onMain {
            Log.e(TAG, "Wi-Fi scan failed", e)
            // A retry gets a fresh link rather than a session in an unknown state.
            if (this@FlutterEspBleProvPlugin.link === link) {
              closeLink(ErrorCode.SCAN_FAILED, e?.message ?: "Wi-Fi scan failed")
            }
          }
        })
      }
    }
  }

  private fun provisionWifi(
    deviceName: String,
    pop: String,
    ssid: String,
    passphrase: String,
    reply: Reply,
  ) {
    withLink(deviceName, pop, reply) { link, esp ->
      runWork(link, ErrorCode.DEVICE_DISCONNECTED) {
        esp.provision(ssid, passphrase, object : ProvisionListener {
          override fun createSessionFailed(e: Exception?) =
            linkFailed(link, "Session failed during provisioning", e)

          override fun wifiConfigSent() = Unit

          override fun wifiConfigFailed(e: Exception?) =
            linkFailed(link, "Sending the Wi-Fi config failed", e)

          override fun wifiConfigApplied() = Unit

          override fun wifiConfigApplyFailed(e: Exception?) =
            linkFailed(link, "Applying the Wi-Fi config failed", e)

          override fun provisioningFailedFromDevice(failureReason: ProvisionFailureReason?) {
            Log.e(TAG, "Provisioning failed on the device: $failureReason")
            when (failureReason) {
              ProvisionFailureReason.AUTH_FAILED ->
                finish(link) { reply.error(ErrorCode.AUTH_FAILED, "Wi-Fi password rejected") }
              ProvisionFailureReason.NETWORK_NOT_FOUND ->
                finish(link) { reply.error(ErrorCode.NETWORK_NOT_FOUND, "Wi-Fi network not found") }
              else -> linkFailed(link, "Device reported $failureReason", null)
            }
          }

          override fun deviceProvisioningSuccess() = finish(link) {
            reply.success(null)
            // The device switches to the Wi-Fi network; the link has no further use.
            closeLink(ErrorCode.DEVICE_DISCONNECTED, "Provisioned")
          }

          override fun onProvisioningFailed(e: Exception?) {
            Log.e(TAG, "Provisioning failed", e)
            finish(link) { reply.error(ErrorCode.FAILED, e?.message ?: "Provisioning failed") }
          }
        })
      }
    }
  }

  /**
   * Runs [block] once a ready link to [deviceName] exists, connecting first when needed. A call
   * still waiting on the current link was abandoned by Dart (it times out its calls), so that
   * link is presumed stuck and replaced.
   */
  @SuppressLint("MissingPermission")
  private fun withLink(
    deviceName: String,
    pop: String,
    reply: Reply,
    block: (Link, ESPDevice) -> Unit,
  ) {
    stopBleScan()
    val current = link
    if (current != null && current.reply == null && current.isReady &&
      current.deviceName == deviceName && current.proofOfPossession == pop
    ) {
      current.reply = reply
      block(current, current.esp)
      return
    }
    closeLink(ErrorCode.DEVICE_DISCONNECTED, "Superseded by a new call")
    val connector = devices[deviceName]
    if (connector == null) {
      reply.error(ErrorCode.NOT_FOUND, "$deviceName was not seen by a BLE scan")
      return
    }
    val esp = espManager.createESPDevice(
      ESPConstants.TransportType.TRANSPORT_BLE,
      SecurityType.SECURITY_2,
    )
    val next = Link(deviceName, pop, esp)
    next.reply = reply
    next.onReady = { block(next, it) }
    link = next
    try {
      esp.connectBLEDevice(connector.device, connector.primaryServiceUuid)
    } catch (e: SecurityException) {
      closeLink(ErrorCode.PERMISSION_DENIED, e.message)
    } catch (e: Exception) {
      Log.e(TAG, "BLE connect could not start", e)
      closeLink(ErrorCode.CONNECT_FAILED, e.message)
    }
  }

  /** Called on the main thread for every Espressif connection event. */
  internal fun onConnectionEvent(eventType: Short) {
    val current = link ?: return
    when (eventType) {
      ESPConstants.EVENT_DEVICE_CONNECTED -> {
        if (current.isReady || current.work != null) return
        configureSecurity(current)
        establishSession(current)
      }
      ESPConstants.EVENT_DEVICE_CONNECTION_FAILED,
      ESPConstants.EVENT_DEVICE_DISCONNECTED -> {
        Log.e(TAG, "Bluetooth link lost: event $eventType")
        val code = if (current.isReady) ErrorCode.DEVICE_DISCONNECTED else ErrorCode.CONNECT_FAILED
        closeLink(code, "Bluetooth link lost (event $eventType)")
      }
    }
  }

  /**
   * Picks the security scheme from the version info the device reported on connect: `sec_ver`
   * 0/1/2, sec1 for firmware that predates `sec_ver`. Sec2 needs a username; the proof of
   * possession is skipped for sec0 and for devices with the `no_pop` capability.
   */
  private fun configureSecurity(link: Link) {
    val esp = link.esp
    val prov = try {
      JSONObject(esp.versionInfo.orEmpty()).optJSONObject("prov")
    } catch (e: Exception) {
      Log.e(TAG, "Unreadable version info: ${esp.versionInfo}", e)
      null
    }
    val secVer = prov?.takeIf { it.has("sec_ver") }?.optInt("sec_ver")
    val securityType = when (secVer) {
      null, 1 -> SecurityType.SECURITY_1
      0 -> SecurityType.SECURITY_0
      else -> SecurityType.SECURITY_2
    }
    esp.securityType = securityType
    if (securityType == SecurityType.SECURITY_2 && esp.userName.isNullOrEmpty()) {
      esp.userName = DEFAULT_SEC2_USERNAME
    }
    val noPop = esp.deviceCapabilities?.contains("no_pop") == true
    esp.proofOfPossession =
      if (securityType == SecurityType.SECURITY_0 || noPop) "" else link.proofOfPossession
    Log.d(TAG, "Security $securityType, no_pop: $noPop")
  }

  private fun establishSession(link: Link) {
    runWork(link, ErrorCode.CONNECT_FAILED) {
      link.esp.initSession(object : ResponseListener {
        override fun onSuccess(returnData: ByteArray?) = onMain {
          if (this@FlutterEspBleProvPlugin.link !== link) return@onMain
          link.work = null
          link.isReady = true
          val onReady = link.onReady
          link.onReady = null
          onReady?.invoke(link.esp)
        }

        override fun onFailure(e: Exception?) = onMain {
          Log.e(TAG, "Secure session failed", e)
          if (this@FlutterEspBleProvPlugin.link === link) {
            closeLink(ErrorCode.CONNECT_FAILED, e?.message ?: "Secure session failed")
          }
        }
      })
    }
  }

  /**
   * Runs a blocking Espressif call for [link] on [worker]; a throw closes the link and answers
   * its call with [errorCode].
   */
  private fun runWork(link: Link, errorCode: String, call: () -> Unit) {
    link.work = worker.submit(Runnable {
      try {
        call()
      } catch (e: InterruptedException) {
        // The link was closed while this call was parked.
      } catch (e: Exception) {
        Log.e(TAG, "Espressif call failed", e)
        onMain {
          if (this.link === link) closeLink(errorCode, e.message)
        }
      }
    })
  }

  /** Answers the call waiting on [link] through [answer], unless the link was replaced. */
  private fun finish(link: Link, answer: () -> Unit) = onMain {
    if (this.link !== link) return@onMain
    link.work = null
    link.reply = null
    answer()
  }

  /** The link broke during a call: answer it with `device_disconnected` and drop the link. */
  private fun linkFailed(link: Link, message: String, e: Exception?) = onMain {
    Log.e(TAG, message, e)
    if (this.link === link) closeLink(ErrorCode.DEVICE_DISCONNECTED, e?.message ?: message)
  }

  /** Disconnects the current link and answers the call waiting on it with [code]. */
  private fun closeLink(code: String, message: String?) {
    val current = link ?: return
    link = null
    current.work?.cancel(true)
    current.work = null
    current.onReady = null
    current.reply?.error(code, message)
    current.reply = null
    try {
      current.esp.disconnectDevice()
    } catch (e: Exception) {
      Log.e(TAG, "Failed to disconnect", e)
    }
  }

  // endregion

  private companion object {
    const val PERMISSION_REQUEST_CODE = 0x5E1E
    const val DEFAULT_SEC2_USERNAME = "wifiprov"
  }
}

/** EventBus subscriber; public so EventBus can invoke it reflectively. */
class ConnectionEvents internal constructor(private val plugin: FlutterEspBleProvPlugin) {
  @Subscribe(threadMode = ThreadMode.MAIN)
  fun onEvent(event: DeviceConnectionEvent) {
    plugin.onConnectionEvent(event.eventType)
  }
}

private fun Int.asAuthModeName(): String = when (this) {
  ESPConstants.WIFI_OPEN.toInt() -> "open"
  ESPConstants.WIFI_WEP.toInt() -> "wep"
  ESPConstants.WIFI_WPA_PSK.toInt() -> "wpa_psk"
  ESPConstants.WIFI_WPA2_PSK.toInt() -> "wpa2_psk"
  ESPConstants.WIFI_WPA_WPA2_PSK.toInt() -> "wpa_wpa2_psk"
  ESPConstants.WIFI_WPA2_ENTERPRISE.toInt() -> "wpa2_enterprise"
  ESPConstants.WIFI_WPA3_PSK.toInt() -> "wpa3_psk"
  ESPConstants.WIFI_WPA2_WPA3_PSK.toInt() -> "wpa2_wpa3_psk"
  else -> "unknown"
}
