# Scale2Health

Scale2Health is a small native iOS app that reads measurements directly from a Medisana BS444-compatible scale over Bluetooth Low Energy and writes supported values to Apple Health. It does not require VitaDock, a Medisana account, or a cloud service.

## Project status

This is a personal, vibe-coded project: it was built through iterative prompting, review, automated tests, and testing with a real iPhone and BS444. The repository contains source code, not an App Store release or a prebuilt app. Read and audit it before using it with your own health data.

It is not a medical device. Background Bluetooth behavior is controlled by iOS and cannot be guaranteed in every state.

## What works

- Finds BS44x devices using known device-name and GATT service identifiers.
- Connects to the scale, enables measurement indications, and initializes its clock.
- Decodes weight, body fat, body water, muscle percentage, bone mass, scale user, and timestamp.
- Supports kilograms, pounds, and stone/pounds, normalized to kilograms.
- Lets you select a scale and optionally accept only one of its user slots.
- Restores the CoreBluetooth session and makes a bounded reconnect attempt.
- Writes **weight** and **body-fat percentage** to Apple Health after authorization.
- Suppresses duplicate HealthKit writes and can notify after a successful background sync.
- Replays up to 30 retained measurements per recognized scale user and pairs history records by timestamp.
- Shows up to 100 decoded measurements from the current app run for history-sync verification.
- Keeps a bounded in-memory BLE log for troubleshooting.

Body water, muscle percentage, and bone mass are displayed but are not written to HealthKit because the target HealthKit API has no direct types for those scale values.

The complete protocol notes are in [`Scale2Health/Protocol/BS444_PROTOCOL.md`](Scale2Health/Protocol/BS444_PROTOCOL.md).

## Privacy

There is no account system, analytics SDK, advertising SDK, or outbound networking code.

The data path is:

```text
BS444 scale -> Bluetooth -> Scale2Health -> Apple Health
```

Scale2Health stores the selected peripheral, user filter, detected epoch mode, and up to 512 per-device measurement fingerprints in its local `UserDefaults` container. The received-measurement history and raw BLE log are kept in memory and leave the app only if you explicitly share the log. Apple Health receives only the sample types you authorize.

## Requirements

- Xcode 15 or newer
- iOS 17 or newer
- A physical iPhone for Bluetooth and HealthKit
- An Apple development team configured in Xcode
- A Medisana BS444 or compatible BS44x scale

The BS444 path has been tested on real hardware. Related BS44x models are recognized from the openScale protocol information but have not all been tested with this app.

## Build and install

1. Clone the repository and open `Scale2Health.xcodeproj`.
2. Select the **Scale2Health** target, open **Signing & Capabilities**, and choose your development team.
3. Change the bundle identifier if `com.scale2health.app` is unavailable to your team.
4. Connect and select your iPhone, then run the app from Xcode.
5. Grant Bluetooth, Health, and optional notification permissions when prompted.

The project intentionally does not include a development-team ID, provisioning profile, certificate, or other signing material.

## Tests

Run the platform-independent checks with Swift Package Manager:

```sh
swift run Scale2HealthCoreChecks
swift test
```

The full parser and model test suite is in the `Scale2HealthTests` Xcode target and can be run with **Product -> Test** in Xcode.

## Source layout

- `Scale2Health/Managers/BluetoothManager.swift` — CoreBluetooth lifecycle and reconnect behavior
- `Scale2Health/Protocol/` — BS444 commands, frame parsing, and protocol notes
- `Scale2Health/Managers/HealthKitManager.swift` — HealthKit authorization and writes
- `Scale2Health/Managers/LocalNotificationManager.swift` — background-sync notifications
- `Scale2Health/UI/ContentView.swift` — SwiftUI interface
- `Scale2HealthTests/` — parser and model tests

## Protocol attribution

The BS444 implementation is based on the protocol work in [openScale](https://github.com/oliexdev/openScale), especially its `MedisanaBs44xHandler` and BS444 protocol notes. See the in-repository protocol document for exact references and implementation boundaries.

## License

Scale2Health is licensed under the [GNU General Public License v3.0](LICENSE).
Upstream protocol references and their licenses are documented in
[`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md).
