# EventBus finds @Subscribe methods by reflection.
-keepclassmembers class how.virc.flutter_esp_ble_prov.ConnectionEvents {
    @org.greenrobot.eventbus.Subscribe <methods>;
}
