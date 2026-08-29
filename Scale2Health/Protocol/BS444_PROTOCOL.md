# Medisana BS444 protocol reference

This implementation follows openScale's `MedisanaBs44xHandler` rather than deriving a new wire format:

<https://github.com/oliexdev/openScale/blob/master/android_app/app/src/main/java/com/health/openscale/core/bluetooth/scales/MedisanaBs44xHandler.kt>

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
5. The scale normally delivers a weight notification followed by a feature notification. The app buffers either characteristic until its complete fixed-size frame is available, then joins the two packets into one measurement.

## Frames

The openScale handler reads fixed offsets and does not specify a start marker or checksum. The iOS parser therefore does not invent or validate a checksum; it validates the minimum frame size and preserves the documented offsets.

### Weight (`CHR_WEIGHT`)

At least 9 bytes:

- bytes `1..2`: unsigned little-endian weight, divided by `100` for kilograms;
- bytes `5..8`: unsigned little-endian timestamp;
- all other bytes are retained only in the raw BLE log.

### Body composition (`CHR_FEATURE`)

At least 16 bytes:

- bytes `8..9`: fat percentage;
- bytes `10..11`: water percentage;
- bytes `12..13`: muscle percentage;
- bytes `14..15`: bone mass in kilograms.

Each value is an unsigned little-endian 16-bit value masked with `0x0FFF`, then divided by `10`. Zero values are treated as absent by the normalized model so the UI and HealthKit writer do not store false zero readings.

## Device identification

The openScale name heuristics carried into the app are:

- `013197*`, `013198*`, or `0202B6*`: Medisana BS444/BS440 and the 2010 epoch;
- `0203B*`: Medisana BS430 and Unix epoch;
- any device advertising the service: generic Medisana BS44x support, with runtime epoch detection.

Because advertisement names and service advertisement behavior must still be checked against the physical device, the app logs the advertised name, UUID, service list, and raw characteristic bytes during manual testing.

## HealthKit boundary

The scale exposes more fields than the stable HealthKit quantity types that can be mapped without inventing semantics. The first version writes only:

- weight → `bodyMass` in kilograms;
- body fat → `bodyFatPercentage` as a fraction (`percent / 100`).

Body water percentage, muscle percentage, and bone mass remain visible in the app but are not written as unrelated HealthKit types. Apple Health does not provide a direct, stable quantity type for those exact values in the target API. No derived lean-body-mass sample is created because that would be a calculated value rather than the scale's reported muscle measurement.
