# Cross-Platform Support Plan

Ship the REV System Identification app on **Web**, **Linux**, and **macOS** in addition to Windows.
Linux and macOS are nearly free — all plugins already support them and the Flutter scaffolding exists.
Web requires the most work due to `dart:io` and serial port FFI being unavailable in browsers.

---

## Phase 1 — Linux & macOS Desktop (low effort)

Both platforms already have Flutter scaffolding and all plugins (`flutter_libserialport`,
`system_theme`, `file_picker`, `fluent_ui`) registered and working. The Dart code has
zero `Platform.is*` checks and zero native DLL loads. Main blockers are OS-level
permissions and packaging.

### macOS

- [x] **Add USB/serial entitlements** to `macos/Runner/DebugProfile.entitlements` and
      `macos/Runner/Release.entitlements`:
      ```xml
      <key>com.apple.security.device.usb</key>
      <true/>
      <key>com.apple.security.device.serial</key>
      <true/>
      ```
      Without these, the macOS sandbox blocks access to the SPARK MAX USB-serial bridge.

- [ ] **Verify `flutter build macos`** compiles clean and launches

- [ ] **Test serial port discovery** — confirm SPARK MAX appears in device list

- [ ] **Test full sysid pipeline** — quasistatic + dynamic tests, analysis, PDF export

- [ ] **App signing & notarization** (for distribution outside the App Store):
      - Sign with a Developer ID certificate
      - Notarize via `xcrun notarytool` so Gatekeeper allows launch
      - Or distribute unsigned for dev/team use (users right-click → Open)

- [ ] **DMG packaging** — create a `.dmg` installer with drag-to-Applications layout
      (consider `create-dmg` or `flutter_distributor` with `dmg` target)

### Linux

- [x] **Create udev rule** for SPARK MAX USB-CAN bridge to prevent ModemManager from
      claiming the port for ~15s on plug-in. Create `99-sparkmax.rules`:
      ```
      # REV SPARK MAX / SPARK Flex USB-CAN bridge (STM32 VID 0x0483)
      SUBSYSTEM=="tty", ATTRS{idVendor}=="0483", MODE="0666", ENV{ID_MM_DEVICE_IGNORE}="1"
      ```
      Install to `/etc/udev/rules.d/` and reload with `sudo udevadm control --reload-rules`.

- [x] **Document `dialout` group requirement** — user must be in `dialout` (or `uucp` on
      some distros) to open serial ports: `sudo usermod -aG dialout $USER` then re-login.

- [ ] **Verify `flutter build linux`** compiles clean and launches

- [ ] **Test serial port discovery** — confirm SPARK MAX appears after udev rule installed

- [ ] **Test full sysid pipeline** — quasistatic + dynamic tests, analysis, PDF export

- [ ] **AppImage packaging** — create a portable `.AppImage` for distribution
      (consider `appimage-builder` or `flutter_distributor` with `appimage` target)

- [ ] **Verify GTK3 dependency** is documented — users need `libgtk-3-dev` (usually
      pre-installed on Ubuntu/Fedora desktops)

### Both platforms — design decision

- [ ] **Decide on Fluent UI aesthetic** — the app renders Windows 11 Fluent Design on all
      platforms. Options:
      - **Keep as-is** — acceptable for a niche engineering tool, consistent across platforms
      - **Swap to `macos_ui`/`yaru`** per-platform — significant UI rework, probably not worth it
      - **Use Material 3** everywhere — major rewrite of all screens

---

## Phase 2 — Web Serial Transport (web foundation)

The Web Serial API replaces `flutter_libserialport` in browsers. The existing
`ISparkConnection` interface means the CAN protocol stack, heartbeat, parameter API,
and control API need zero changes — only the transport layer.

- [x] **Add `package:web` to `pubspec.yaml`** — Dart team's official web interop package
      for `dart:js_interop` bindings

- [x] **Create `lib/can/web_spark_connection.dart`** — implements `ISparkConnection`:
      - `open()` → `port.open({baudRate: 115200, dataBits: 8, parity: 'none', stopBits: 1})`
      - Same SLCAN init: wait 300ms → flush → `S8\r` → wait 20ms → `O\r` → wait 100ms → flush
      - `sendRaw()` → `port.writable.getWriter().write(Uint8List)`
      - Read loop → `port.readable.getReader().read()` feeding `_onDataReceived` parser
      - `close()` → `await port.close()`
      - Status frame getters, `responses` stream — same as `SparkConnection`

- [x] **Create conditional export** for `SparkConnection`:
      - `lib/can/spark_connection.dart` becomes the barrel file
      - `lib/can/spark_connection_native.dart` — existing FFI implementation (renamed)
      - `lib/can/spark_connection_web.dart` — re-exports `WebSparkConnection`
      - Barrel: `export 'spark_connection_native.dart' if (dart.library.js_interop) 'spark_connection_web.dart'`

- [x] **Refactor `DeviceManager`** for web port discovery:
      - Desktop path unchanged: `SerialPort.availablePorts` background scan
      - Web path: `navigator.serial.requestPort({filters: [{usbVendorId: 0x0483}]})`
        (user-gesture-triggered)
      - Factory method to create appropriate connection type
      - *Depends on conditional export above*

- [x] **Fix `can_diagnostic_v5.dart`** — change concrete `SparkConnection` parameter to
      `ISparkConnection`, handle `rawCaptureEnabled`/`sendRaw` via interface extension or
      capability check

---

## Phase 3 — Remove `dart:io` from Dart Code (web prerequisite)

`dart:io` is unavailable in browsers. These 5 files block web compilation.
Note: `dart:io` is fine on Linux/macOS — this phase is web-only.

- [x] **Create `lib/data/file_saver.dart`** — platform-abstract file save:
      - `lib/data/file_saver_native.dart`: `File(path).writeAsBytes()`, `FilePicker.saveFile()`
      - `lib/data/file_saver_web.dart`: `Blob` + anchor-click download via `dart:js_interop`
      - Barrel with conditional export

- [x] **Update `report_generator.dart`** — replace `File(path).writeAsBytes()` with `FileSaver`

- [x] **Update `csv_exporter.dart`** — replace `File(path).writeAsString()` with `FileSaver`

- [x] **Update `notebook_exporter.dart`** — replace `File(path).writeAsString()` with `FileSaver`

- [x] **Update `project_file.dart`** — replace `File` read/write with `FileSaver` (save) and
      `FilePicker.pickFiles()` (load — already works on web)

- [x] **Wrap `comms_log.dart`** — conditional import:
      - Desktop: existing `File`/`IOSink` file logging
      - Web: in-memory ring buffer or silent no-op

---

## Phase 4 — Fix Remaining Web Blockers

- [x] **Fix `main.dart`** — `system_theme` conditional:
      - Desktop: existing `SystemTheme.accentColor.load()`
      - Web: skip `SystemTheme` init, use a hardcoded REV-orange accent color
      - Use `kIsWeb` from `package:flutter/foundation.dart`

- [x] **Add web device picker UI** — "Connect Device" button:
      - User clicks → browser shows serial port permission prompt
      - On approval → create `WebSparkConnection`, add to device list
      - `navigator.serial.getPorts()` on page load to auto-reconnect previously-granted ports
      - *Depends on Phase 2*

- [x] **Add browser compatibility banner** — detect `navigator.serial` availability:
      - Chromium browsers (Chrome, Edge, Opera): full hardware + simulation
      - Firefox/Safari: show banner "Hardware not supported in this browser — use
        Chrome or Edge for USB device access", simulation mode works fully

---

## Phase 5 — Build, Test & Deploy

### Web

- [ ] **`flutter build web --release`** compiles without errors

- [ ] **Test simulation mode** in Chrome — run sysid on simulated flywheel/arm/elevator,
      verify charts, PID tuning, pole-zero map

- [ ] **Test hardware mode** in Chrome — connect SPARK MAX, serial permission prompt,
      heartbeat, quasistatic + dynamic tests, PDF export via browser download

- [ ] **Test in Firefox** — simulation works, hardware gracefully blocked with banner

- [ ] **Deploy to static hosting** — GitHub Pages, Netlify, or Vercel.
      `build/web/` folder is self-contained, no backend needed

### Linux

- [ ] **`flutter build linux --release`** on Ubuntu — verify clean build

- [ ] **Test on Ubuntu 22.04+** with SPARK MAX hardware

- [ ] **Test on Fedora** (if targeting multiple distros)

- [ ] **Publish AppImage** or `.deb`/`.rpm`

### macOS

- [ ] **`flutter build macos --release`** — verify clean build

- [ ] **Test on macOS 13+ (Ventura)** with SPARK MAX hardware

- [ ] **Test on Apple Silicon (M1/M2/M3)** — `flutter_libserialport` must compile for arm64

- [ ] **Publish signed+notarized DMG**

---

## Relevant Files

| File | What / Why |
|------|------------|
| `lib/can/spark_connection.dart` | Serial transport — must be conditional-exported for web |
| `lib/can/interfaces.dart` | `ISparkConnection` interface — no changes needed |
| `lib/devices/device_manager.dart` | Port enumeration — needs web alternative |
| `lib/can/comms_log.dart` | `dart:io` `File`/`IOSink` — needs web stub |
| `lib/data/report_generator.dart` | `dart:io` `File.writeAsBytes()` — needs FileSaver |
| `lib/data/project_file.dart` | `dart:io` `File.readAsString()`/`writeAsString()` |
| `lib/data/csv_exporter.dart` | `dart:io` `File.writeAsString()` — needs FileSaver |
| `lib/data/notebook_exporter.dart` | `dart:io` `File.writeAsString()` — needs FileSaver |
| `lib/can/diagnostics/can_diagnostic_v5.dart` | Concrete `SparkConnection` — change to interface |
| `lib/main.dart` | `system_theme` — conditional for web |
| `macos/Runner/DebugProfile.entitlements` | Needs USB/serial entitlement |
| `macos/Runner/Release.entitlements` | Needs USB/serial entitlement |
| `pubspec.yaml` | Add `package:web`, remove unused `ffi` |

## Effort Estimate

| Platform | Effort | Notes |
|----------|--------|-------|
| **Linux** | ~1 day | Already compiles. Udev rule + test + AppImage packaging. |
| **macOS** | ~1 day | Already compiles. Entitlements + test + DMG + notarization. |
| **Web** | ~5-7 days | Web Serial transport, `dart:io` removal, web UX, testing. |

## Key Decisions

- **Fluent UI stays** — Windows-style UI on all platforms, consistent, not worth rewriting
- **Web Serial is Chromium-only** — Firefox/Safari get simulation-only, acceptable trade-off
- **No backend server for web** — direct browser-to-USB via Web Serial API
- **Conditional imports** via `export ... if (dart.library.io)` / `if (dart.library.js_interop)`
- **Linux packaging**: AppImage first (most portable), `.deb`/`.rpm` later if needed
- **macOS**: signed DMG for team distribution, App Store not planned (serial port sandbox issues)