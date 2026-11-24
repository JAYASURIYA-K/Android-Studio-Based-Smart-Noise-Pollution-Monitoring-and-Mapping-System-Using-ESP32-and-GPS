# Smart Noise Pollution Monitoring and Mapping System

**ESP32 + GPS + sound sensor + OLED hardware, with a Flutter Android app that shows live readings and plots measurement points on a map.**

A low-cost portable noise monitor. The ESP32 measures a **relative noise level** from an analog sound sensor, reads its position from a NEO-6M GPS module, shows both on an OLED display, and serves them as live JSON over Wi-Fi. The **Noise Guard** Flutter app reads that data and shows it on a dashboard and on an interactive map, with markers coloured green, yellow or red.

> **Important.** The analog sound module used here is **not** a calibrated sound-level meter. The values are a **relative noise indicator** on a 0-100 scale. They are **not dB or dB(A)**, and the LOW / MODERATE / HIGH categories are **not official noise limits**. This prototype makes no claim of compliance with any noise regulation. See [Calibration and limitations](#calibration-and-limitations).

![System block diagram](docs/system_block_diagram.png)

---

## Features

**Hardware (ESP32)**
- Measures sound in 200 ms windows and converts the signal swing to a smoothed relative noise value (0-100)
- Categories LOW / MODERATE / HIGH with configurable thresholds
- Green LED for LOW, red LED for HIGH, buzzer above a configurable level
- Reads GPS over UART (NMEA, TinyGPSPlus) and sends a position only when the fix is valid and recent
- Keeps working without a GPS fix or without Wi-Fi (latitude and longitude are `null`)
- Non-blocking loop, automatic Wi-Fi reconnect, local web server that serves JSON at `/data`
- OLED shows noise value, category, GPS status, satellites, latitude, longitude and IP address
- Animated OLED start-up intro and system check (hold the BOOT button while powering on to skip)

**Mobile app (Flutter, Android)**
- Connects to the ESP32 by IP address over the phone hotspot, refreshes every 2 seconds
- Home screen with live gauges, noise category, GPS status and last update
- Interactive OpenStreetMap map with green / yellow / red markers, live marker, legend, centre-on-me and a zones toggle
- Tap a marker to see latitude, longitude, reading, category and time
- History of saved points (kept on the phone, newest 500)
- Dashboard with current, session maximum and minimum, number of locations and a graph over time

## How it works

1. The ESP32 joins your **phone hotspot** (2.4 GHz) and starts a small HTTP server.
2. The OLED shows the ESP32's IP address.
3. You type that IP into the app on the same hotspot.
4. The app requests `http://<ESP32_IP>/data` every 2 seconds and shows the result.
5. When the GPS fix is valid, a measurement point is saved at most once every 15 seconds and drawn on the map.

> The phone and the ESP32 must be on the **same hotspot / Wi-Fi network**. This version is not reachable over the internet. See [Future work](#future-work) for a cloud option.

## Hardware

| Part | Connection |
|---|---|
| ESP32 development board | Wi-Fi built in |
| Analog sound sensor module (LM393 + electret microphone, KY-037 / KY-038 type) | AO to **GPIO 34**, + to **3.3 V**, G to GND, DO not used |
| NEO-6M GPS module | GPS TX to **GPIO 16** (RX2), GPS RX to **GPIO 17** (TX2), 9600 baud |
| SSD1306 0.96-inch OLED (I2C, address 0x3C) | SDA to **GPIO 21**, SCL to **GPIO 22** |
| Green LED | **GPIO 25** through a 220-ohm resistor |
| Red LED | **GPIO 26** through a 220-ohm resistor |
| Buzzer (active) | **GPIO 27** to GND |

All grounds are common. Power the sound sensor from **3.3 V** so its output never exceeds the ESP32's ADC limit.

## Repository structure

```
smart-noise-monitor/
├── firmware/
│   ├── noise_monitor/
│   │   └── noise_monitor.ino            # main ESP32 firmware (intro, system check, monitoring, JSON server)
│   └── sensor_calibration/
│       └── sensor_calibration.ino       # prints raw ADC statistics to calibrate the sensor range
├── app/
│   ├── lib/main.dart                    # Noise Guard Flutter app
│   ├── pubspec.yaml
│   └── android/app/src/main/AndroidManifest.xml   # internet permission + cleartext HTTP
├── docs/
│   └── system_block_diagram.png
└── README.md
```

## Getting started

### 1. ESP32 firmware (Arduino IDE)

1. Install the **ESP32 board package** (Boards Manager, "esp32" by Espressif) and choose **ESP32 Dev Module**.
2. Install these libraries (Library Manager): **TinyGPSPlus**, **Adafruit SSD1306**, **Adafruit GFX Library**, **ArduinoJson** (version 7).
3. Open `firmware/noise_monitor/noise_monitor.ino` and set your hotspot:
   ```cpp
   const char* WIFI_SSID = "YOUR_HOTSPOT_NAME";
   const char* WIFI_PASS = "YOUR_HOTSPOT_PASSWORD";
   ```
   Never commit your real Wi-Fi password to a public repository.
4. Phone hotspot settings: **2.4 GHz band**, **WPA2-Personal** security, and switch **off** "turn off hotspot automatically". Turn the hotspot on before powering the ESP32.
5. Upload the sketch. After the intro and system check, note the **IP address** on the OLED.
6. Optional: set `SHOW_INTRO = false` to skip the animation, or change the intro texts at the top of the sketch.

Check the output in the Serial Monitor (115200 baud) or open `http://<ESP32_IP>/data` in a browser on the same hotspot.

### 2. Calibrate the sound range

1. Upload `firmware/sensor_calibration/sensor_calibration.ino` and open the Serial Monitor at 115200 baud.
2. In a quiet room, note the `rms` value and set it as `NOISE_FLOOR_RMS` in `noise_monitor.ino`.
3. Play a loud sound close to the microphone, note the largest `rms` and set it as `LOUD_RMS`.
4. Upload `noise_monitor.ino` again. Quiet should read near 0 and loud sounds should reach HIGH.

### 3. Flutter app

Requirements: Flutter SDK (stable), Android Studio with the Android SDK, an Android phone with USB debugging. On Windows, turn on **Developer Mode** (needed for plugin symlinks).

This repository contains the app source and the Android file that was changed. Create a Flutter project, then copy the files over it:

```bash
flutter create --platforms=android noise_monitoring_app
```

Copy into the new project (replace the existing files):

```
app/lib/main.dart                                  ->  lib/main.dart
app/pubspec.yaml                                   ->  pubspec.yaml
app/android/app/src/main/AndroidManifest.xml       ->  android/app/src/main/AndroidManifest.xml
```

Delete the generated `test/widget_test.dart` (it refers to the sample counter app), then:

```bash
flutter pub get
flutter run
```

Build an APK:

```bash
flutter build apk --release
```

The APK is created at `build/app/outputs/flutter-apk/app-release.apk`.

If your `pubspec.yaml` has an `environment: sdk:` line that your Flutter version rejects, keep the one generated by your own Flutter and only copy the `dependencies:` section.

### 4. Use it

1. Connect the phone to its own hotspot and power the ESP32.
2. Open **Noise Guard**, type the IP shown on the OLED, and tap **CONNECT**. The header shows **LIVE** when data arrives.
3. Take the unit outdoors (clear sky) and wait a few minutes for a GPS fix. Points then appear on the map and in History.

## Data format

The ESP32 returns this JSON at `/data` (example values only):

```json
{
  "deviceId": "noise_device_01",
  "latitude": 10.7905,
  "longitude": 78.7047,
  "rawVariation": 180,
  "relativeNoise": 18.0,
  "noiseCategory": "MODERATE",
  "timestamp": "2026-01-01T10:00:00Z",
  "gpsValid": true,
  "satellites": 9
}
```

Without a GPS fix, `latitude`, `longitude` and `timestamp` are `null` and `gpsValid` is `false`.

## Marker, heatmap and noise map

- A **marker** shows one real measurement at one place.
- A **heatmap** would show how measurements are spread over an area. It needs many measurements and a method to combine them.
- A **true noise pollution map** needs calibrated dB(A) data and standards-based processing.

The **zones** toggle in this app only draws a circle around each real measured point. It does not interpolate or invent values for places where nothing was measured.

## Calibration and limitations

- The LM393-based module's trimmer only sets the threshold of the digital output (DO). It does not amplify the analog output (AO), so the analog signal is small and the sensor is not sensitive. Readings are a **relative indicator**.
- To report real **dB(A)**, use a calibrated sound-level sensor or an amplified/digital microphone (for example MAX4466 or INMP441), and calibrate against a reference sound-level meter (see IEC 61672-1).
- The phone and the ESP32 must share the same hotspot / Wi-Fi network.
- GPS needs a clear view of the sky; indoors there is usually no fix.
- Map tiles need internet access on the phone (the phone hotspot's mobile data works).
- History is stored on the phone only.

## Observed during prototyping

- The ESP32 joined a 2.4 GHz phone hotspot and displayed its IP address on the OLED.
- The GPS module sent NMEA data (character counter increasing) and produced a valid fix with 9 satellites outdoors; indoors it reported NO FIX.
- The OLED displayed noise value, category, GPS status, latitude and longitude.
- The analog sound module showed limited sensitivity, as described above.

No accuracy or dB figures are claimed.

## Screenshots

Add screenshots of the OLED, the app's Home, Map, History and Dashboard screens to a `docs/` folder and show them here, for example:

```markdown
![Home screen](docs/home.png)
```

## Future work

- Cloud database (for example Firebase) so several phones can view the same device and history from anywhere
- Calibrated sound-level sensor and calibration against a reference meter
- Heatmap built from many real measurements
- Multiple sensor nodes, battery backup and self-diagnostics

## Tech stack

ESP32 (Arduino C++), TinyGPSPlus, Adafruit SSD1306 / GFX, ArduinoJson, Flutter and Dart, `http`, `flutter_map` with OpenStreetMap, `latlong2`, `fl_chart`, `shared_preferences`, `intl`.

## Author

Final-year B.E. Electronics and Communication Engineering project.
Replace this line with your name and details.

## License

Add a license of your choice (for example MIT) before publishing.

Map data (c) OpenStreetMap contributors.
