# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

moduleBox App is a portable desktop Flutter application (Windows + Linux) for discovering, configuring, and managing **moduleBox** IoT devices. It connects to devices over **Serial/USB** and over the network via **mDNS + FTP**.

## Commands

| Task | Windows | Linux |
|---|---|---|
| Install deps | `flutter pub get` | `flutter pub get` |
| Run (debug) | `0_run.cmd` or `flutter run -d windows` | `./0_debug.sh` or `flutter run -d linux` |
| Build release | `0_release.cmd` or `flutter build windows --release` | `./0_make_release.sh` or `flutter build linux --release` |
| Run prebuilt binary | — | `./1_run_prebuilt.sh` (runs `build/linux/x64/debug/bundle/moduleboxapp`) |
| Lint / analyze | `flutter analyze` | `flutter analyze` |
| Tests | `flutter test` | `flutter test` |
| Single test | `flutter test test/widget_test.dart` | same |

Release artifacts: `build/windows/x64/runner/Release/` and `build/linux/x64/release/bundle/`.

Building from source requires the Flutter SDK (≥ 3.9.2). Windows additionally needs Visual Studio with the "Desktop development with C++" workload and Developer Mode enabled; Linux needs `libserialport` plus the standard GTK build dependencies.

## Architecture

Effectively all application logic lives in a single file: **`lib/main.dart`** (~8600 lines). There is no module split — when working here, locate code by searching for the relevant class/method rather than expecting separate files.

Key types in `lib/main.dart`:
- `ModuleBoxApp` — root `MaterialApp`.
- `HomePage` / `_HomePageState` — the entire UI and all logic. `_HomePageState` holds device lists, sockets, controllers, and the scanning loops.
- `DeviceItem` — a discovered device (serial or mDNS), with `DeviceListFilter` distinguishing the two kinds.
- `ConfigEditorController` — a `TextEditingController` subclass providing syntax highlighting + autocompletion for `config.ini`.
- `ConfigValidationIssue` — a config validation finding surfaced in the editor.
- `CrossLinkStepType` — drives the step-by-step cross-link rule builder.

### Device discovery (two independent paths)

`_startBackgroundScanning()` runs a periodic loop calling `_scanSerialPorts()` and `_scanMdnsBroadcasts()`.

1. **Serial** — `_scanSingleSerialPort()` probes COM ports (Windows) / `/dev/ttyUSB*` (Linux). Config files for serial devices are read from **removable drives** (see `_removableRoots`: `D:`–`K:` on Windows; `/media`, `/mnt`, `/Volumes` on Linux/macOS), not over the wire.
2. **mDNS** — `_initializeMdnsSocket()` keeps a long-lived UDP socket on port 5353 joined to multicast group `224.0.0.251`, and discovers `_ftp._tcp.local` services. mDNS devices are accessed by **anonymous FTP** (`ftpconnect`) to download/upload `config.ini` and `manifest-*.json`.

**Windows multicast quirk:** Dart's socket API cannot reliably join the multicast group on Windows, so `_initializeMdnsSocket()` uses `dart:ffi` to call WinSock `setsockopt(IP_ADD_MEMBERSHIP)` directly. This FFI path is Windows-only — guard any changes with the existing platform checks.

### Config model

A device's firmware version is parsed from the manifest filename (`manifest-3.35.json` → `"3.35"`). The `manifest-*.json` describes config sections ("chapters"), keys, modes, and option lists; the app uses it to power both autocompletion and the visual Config Designer.

The config UI has three tabs: **Config Edit** (raw text editor with highlighting + autocomplete), **Config Design** (per-chapter form editor), and **Console** (interactive serial console, USB devices only — commands use `deviceName/command` format).

### Cross-link rules

`crosslink=` is a special config key. Rules are built step-by-step (source slot → report → value → target slot → command → value), validated by `_validateSingleCrossLinkRule()`, and offered as contextual autocomplete suggestions both in the text editor and the console. There are parallel suggestion code paths for editor vs console input — keep both in sync when changing cross-link logic.

## Notes

- `modulebox.log` and `logs0411.txt` in the repo root are runtime logs / debug captures, not source.
- The README is in Russian and is the authoritative end-user documentation.
