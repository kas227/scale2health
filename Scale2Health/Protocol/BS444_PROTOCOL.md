# Medisana BS444 protocol reference

This implementation follows openScale's `MedisanaBs44xHandler` and its BS444 protocol notes rather than deriving a new wire format:

- Handler: <https://github.com/oliexdev/openScale/blob/master/android_app/app/src/main/java/com/health/openscale/core/bluetooth/scales/MedisanaBs44xHandler.kt>
- Protocol notes and captured packets: <https://github.com/oliexdev/openScale/wiki/Medisana-BS444>

## GATT surface

The 16-bit UUIDs below use the Bluetooth base UUID (`0000xxxx-0000-1000-8000-00805F9B34FB`).

| Role | UUID | openScale property | Operation |
| --- | --- | --- | --- |
| Service | `000078B2-0000-1000-8000-00805F9B34FB` | `SERVICE` | GATT service |
| Weight | `00008A21-0000-1000-8000-00805F9B34FB` | `CHR_WEIGHT` | Indicate/notify |
| Body composition | `00008A22-0000-1000-8000-00805F9B34FB` | `CHR_FEATURE` | Indicate/notify |
| Clock command | `00008A81-0000-1000-8000-00805F9B34FB` | `CHR_CMD` | Write with response |
| Optional custom | `00008A82-0000-1000-8000-00805F9B34FB` | `CHR_CUSTOM5` | Indicate/notify; ignored |

## Session sequence

1. Discover the service and the available characteristics.
2. Enable indications/notifications for weight and body-composition characteristics. The optional custom characteristic is subscribed to when present, but its payload is ignored.
3. Write the clock command to `CHR_CMD` after the required notifications are enabled:
   `02 <timestamp byte 0> <timestamp byte 1> <timestamp byte 2> <timestamp byte 3>`.
4. The timestamp is a little-endian 32-bit seconds value. BS444/BS440 name prefixes generally use seconds from `2010-01-01`; the handler also supports Unix seconds. The app chooses the known prefix when available and corrects unknown/incorrect epoch assumptions when a received timestamp is close to the current time.
5. The clock command also triggers replay of retained measurements. The BS444 advertises 30 storage spaces for each of eight recognized users. This is an overlapping snapshot rather than a new-record stream; no record cursor, acknowledgement, or delete command is known.
6. Live and historical weight/body-composition frames are joined by their shared user ID and raw timestamp. Notification order is not a safe correlation key because multiple weight or feature frames can arrive consecutively during replay.

## Frames

The openScale handler reads fixed offsets and does not specify a start marker or checksum. The iOS parser therefore does not invent or validate a checksum; it validates the minimum frame size and preserves the documented offsets.

### Weight (`CHR_WEIGHT`)

The packet is 19 bytes:

- byte `0`: flags; bits `5...6` encode `00` kilograms, `01` pounds, and `10` stone/pounds (`11` is unsupported and rejected);
- bytes `1..2`: unsigned little-endian weight scalar divided by `100`. Kilogram packets are already kilograms. Pound packets and the single imperial scalar carried in stone/pound mode are converted from pounds to kilograms using `1 lb = 0.45359237 kg`;
- bytes `3..4`: unknown;
- bytes `5..8`: unsigned little-endian seconds since `2010-01-01`;
- bytes `9..12`: unknown/scoring data;
- byte `13`: scale user id (`1...8`; `0xFF` means unset);
- bytes `14..18`: unknown/reserved and retained only in the raw BLE log.

### Body composition (`CHR_FEATURE`)

The packet is 19 bytes:

- byte `0`: flags;
- bytes `1..4`: unsigned little-endian seconds since `2010-01-01`;
- byte `5`: scale user id (`1...8`; `0xFF` means unset);
- bytes `6..7`: kcal;
- bytes `8..9`: fat percentage;
- bytes `10..11`: water percentage;
- bytes `12..13`: muscle percentage;
- bytes `14..15`: bone mass in kilograms;
- bytes `16..18`: reserved.

Each composition value is an unsigned little-endian 16-bit value masked with `0x0FFF`, then divided by `10`. Zero values are treated as absent by the normalized model so the UI and HealthKit writer do not store false zero readings.

The feature timestamp and user ID must match the corresponding weight frame. Duplicate suppression is handled by the app using a per-device fingerprint because the protocol exposes no verified record identifier.

## Scale users and unsupported controls

The app can detect user slots `1...8` in both measurement frames. It persists an optional per-scale filter (`Any user` or one numbered user), rejects mismatched weight/feature pairs, and suppresses measurements that do not match the selected filter.

The observed protocol and openScale handler do not provide a supported command for creating or editing user profiles on the scale, so those profiles must still be managed with the scale's controls. The documented feature frame labels bytes `6...7` as kcal; no verified visceral-fat field is available, so the app does not invent or expose one.

## Device identification

The openScale name heuristics carried into the app are:

- `013197*`, `013198*`, or `0202B6*`: Medisana BS444/BS440 and the 2010 epoch;
- `0203B*`: Medisana BS430 and Unix epoch;
- any device advertising the service: generic Medisana BS44x support, with runtime epoch detection.

Because advertisement names and service advertisement behavior must still be checked against the physical device, the app logs the advertised name, UUID, service list, and raw characteristic bytes during manual testing.

## HealthKit boundary

The live User 1 packet mapping has been verified against the scale display, so authorized HealthKit writes are enabled. The scale exposes more fields than the stable HealthKit quantity types that can be mapped without inventing semantics; the app maps only:

- weight → `bodyMass` in kilograms;
- body fat → `bodyFatPercentage` as a fraction (`percent / 100`).

Body water percentage, muscle percentage, and bone mass remain visible in the app but are not written as unrelated HealthKit types. Apple Health does not provide a direct, stable quantity type for those exact values in the target API. No derived lean-body-mass sample is created because that would be a calculated value rather than the scale's reported muscle measurement.
