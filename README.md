# Scale2Health

A local-first iOS app for receiving Medisana BS444 measurements over Bluetooth Low Energy and writing the supported values to Apple Health. It does not use a Medisana/VitaDock account, cloud service, or external server.

## Current first version

- Detects BS44x devices by the openScale name/service heuristics.
- Connects to the `78B2` GATT service, enables weight/body-composition indications, and sends the clock command.
- Reassembles the fixed-size weight and feature notifications and decodes weight (kg/lb/st:lb normalized to kilograms), body fat, body water, muscle percentage, bone mass, scale user, and timestamp.
- Displays the decoded measurement and keeps a bounded raw BLE log for manual troubleshooting.
- Persists the selected peripheral, detected epoch mode, and an optional `Any user`/`User 1...8` measurement filter; scale-side profiles are still managed on the scale.
- Uses CoreBluetooth restoration and makes one delayed reconnect attempt rather than scanning continuously.
- Writes verified weight and body-fat samples to HealthKit after authorization and suppresses duplicates. Other displayed metrics are not written under unrelated HealthKit types.

The protocol details and openScale source reference are in `Scale2Health/Protocol/BS444_PROTOCOL.md`.

## Build

Open `Scale2Health.xcodeproj` in Xcode 15 or newer, set a development team for the app target, and enable the HealthKit capability for the target. The deployment target is iOS 17.

The iOS target and XCTest bundle can be built with Xcode. The platform-independent protocol checks can also be run with:

```sh
swift run Scale2HealthCoreChecks
swift test
```

The Xcode test target contains the XCTest fixture suite for use on a machine with Xcode. It includes a captured BS444 User 1 packet pair verified against the scale display for timestamp, kg unit, weight, body fat, body water, muscle percentage, and bone mass.

## Hardware limitation

A real iPhone and BS444 have verified foreground discovery, connection, raw 19-byte measurement delivery, decoding, and display. Repeated HealthKit writes, background delivery, and state restoration still require complete on-device validation.
