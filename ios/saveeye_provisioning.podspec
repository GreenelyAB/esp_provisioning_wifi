#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint saveeye_provisioning.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'saveeye_provisioning'
  s.version          = '0.1.0'
  s.summary          = 'Wi-Fi provisioning of SaveEye (ESP32) devices over BLE.'
  s.description      = <<-DESC
Flutter plugin that scans for ESP32 devices over Bluetooth LE, lists the Wi-Fi
networks they can see and provisions them with Wi-Fi credentials, using
Espressif's ESPProvision library.
                       DESC
  s.homepage         = 'https://github.com/GreenelyAB/esp_provisioning_wifi'
  s.license          = { :file => '../LICENSE' }
  s.author           = 'Greenely AB'
  s.source           = { :path => '.' }
  s.source_files = 'Classes/**/*'
  s.dependency 'Flutter'
  s.dependency 'ESPProvision', '~> 3.2.0'
  # ESPProvision 3.2.0's minimum.
  s.platform = :ios, '13.0'

  # Flutter.framework does not contain a i386 slice.
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.0'
end
