# SpeedTest

A native macOS menu bar app (Swift + SwiftUI) that measures your internet speed against
[speed.cloudflare.com](https://speed.cloudflare.com) or Apple's built-in `networkQuality`.

- Menu bar shows the last result (`↓ 504 ↑ 380`), live while a test runs
- Animated, real-time download and upload progress bars
- Ping and jitter from the server-side TCP RTT
- Server setting: Automatic (Cloudflare, switching to Apple while Cloudflare rate-limits you), Cloudflare, or Apple
- Public IP address and network provider (ip.sb → ipwho.is → ipinfo.io → Cloudflare trace), with a copy button
- History of the last 50 tests with a chart
- Notification when a test finishes, auto-test on an interval, launch at login

Requires macOS 14+.

## Build

```sh
./build.sh            # builds build/SpeedTest.app
./build.sh --install  # also copies it to /Applications and launches it
```

Launch at login works best from `/Applications`.

## How it measures

**Cloudflare**

| Step     | Method |
|----------|--------|
| Latency  | 12 `GET /__down?bytes=0` requests on a warm connection; median and jitter of the `cfL4` RTT in `Server-Timing` |
| Download | 6 parallel streams of `GET /__down?bytes=25000000` for 10 s |
| Upload   | 6 parallel streams of `POST /__up` with 10 MB bodies for 10 s |

The first 1.5 s of each transfer is excluded from the final number (TCP slow start).
The live number is a 1-second sliding window.

Cloudflare rate-limits heavy use per IP (HTTP 429 with `Retry-After`). In Automatic mode the app
first requests one download chunk and reads only its status (~130 ms); on a 429 the whole test runs
on Apple, and so do later tests until `Retry-After` passes. A 429 that arrives mid-test stops the test
instead of starting it over on Apple, so each result comes from exactly one provider.

**Apple** runs `/usr/bin/networkQuality -u -M 10 -c` (download) and `-d -M 10 -c` (upload) and reads
the JSON. It only reports at the end, so the bars move by elapsed time; ping is the median TCP
handshake time.

## Layout

```
Sources/SpeedTest/
  SpeedTestApp.swift     MenuBarExtra scene and menu bar label
  AppState.swift         Test flow, history, settings, auto-test timer
  Models.swift           Result, provider and latency types
  CloudflareEngine.swift Cloudflare latency/throughput measurement
  NetworkQualityEngine.swift  Apple networkQuality wrapper
  NetworkInfo.swift      Public IP lookup with fallback sources
  ContentView.swift      Popover UI: Test, History, Settings
  Notifier.swift         User notifications
Resources/Info.plist     LSUIElement (no Dock icon), bundle id
build.sh                 Builds and ad-hoc signs the .app bundle
```
