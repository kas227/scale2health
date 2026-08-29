# Scale2Health

A local-first iOS app for receiving Medisana BS444 measurements over Bluetooth Low Energy and writing the supported values to Apple Health. It does not use a Medisana/VitaDock account, cloud service, or external server.

## Current first version

- Detects BS44x devices by the openScale name/service heuristics.
- Connects to the `78B2` GATT service, enables weight/body-composition indications, and sends the clock command.
- Reassembles the fixed-size weight and feature notifications and decodes weight, body fat, body water, muscle percentage, bone mass, and the scale timestamp.
- Displays the decoded measurement and keeps a bounded raw BLE log for manual troubleshooting.
- Persists the selected peripheral, uses CoreBluetooth restoration, and makes one delayed reconnect attempt rather than scanning continuously.
- Writes weight and body-fat samples to HealthKit. Body-water percentage, muscle percentage, and bone mass are displayed but are not written under unrelated HealthKit types.

The protocol details and openScale source reference are in `Scale2Health/Protocol/BS444_PROTOCOL.md`.

## Build

Open `Scale2Health.xcodeproj` in Xcode 15 or newer, set a development team for the app target, and enable the HealthKit capability for the target. The deployment target is iOS 17.

The iOS target and XCTest bundle can be built with Xcode. The platform-independent protocol checks can also be run with:

```sh
swift run Scale2HealthCoreChecks
swift test
```

The Xcode test target contains the XCTest fixture suite for use on a machine with Xcode.

## Hardware limitation

A real iPhone and BS444 are required to validate advertisement details, characteristic behavior, measurement values, HealthKit authorization, background delivery, and state restoration. Those checks remain explicitly pending until hardware is available.
