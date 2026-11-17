//
//  Generated file. Do not edit.
//

import FlutterMacOS
import Foundation

import bluetooth_low_energy_darwin
import flutter_midi_command
import package_info_plus
import record_macos
import share_plus
import shared_preferences_foundation
import universal_ble
import wakelock_plus

func RegisterGeneratedPlugins(registry: FlutterPluginRegistry) {
  BluetoothLowEnergyDarwinPlugin.register(with: registry.registrar(forPlugin: "BluetoothLowEnergyDarwinPlugin"))
  SwiftFlutterMidiCommandPlugin.register(with: registry.registrar(forPlugin: "SwiftFlutterMidiCommandPlugin"))
  FPPPackageInfoPlusPlugin.register(with: registry.registrar(forPlugin: "FPPPackageInfoPlusPlugin"))
  RecordMacOsPlugin.register(with: registry.registrar(forPlugin: "RecordMacOsPlugin"))
  SharePlusMacosPlugin.register(with: registry.registrar(forPlugin: "SharePlusMacosPlugin"))
  SharedPreferencesPlugin.register(with: registry.registrar(forPlugin: "SharedPreferencesPlugin"))
  UniversalBlePlugin.register(with: registry.registrar(forPlugin: "UniversalBlePlugin"))
  WakelockPlusMacosPlugin.register(with: registry.registrar(forPlugin: "WakelockPlusMacosPlugin"))
}
