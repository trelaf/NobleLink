# CLAUDE.md – working on NobleLink

Guidance for AI agents (and humans) extending this repository. Read `docs/PROTOCOL.md` before
changing anything that talks to a transmitter.

## Layout

```
NobleLink/                      Swift package (macOS 13+, no third-party dependencies)
  Sources/NobleKit/             library: everything that matters
    Packet.swift                280-byte HID report, command numbers
    HIDTransport.swift          IOKit HID transport (the only USB code)
    RadioLink.swift             request/reply, timing, sequence numbers
    RadioSession.swift          list / backup / restore / verify (normal firmware)
    BackupFile.swift            .fsdll format, validation, rename, retarget
    ParameterRecord.swift       settings records (0D 0A | len | 15 | owner | elem | id | value | xor)
    FactoryDefaults.swift       "reset model" = write a default model learned from untouched slots
    Firmware.swift              firmware image checks, updater .exe resource extraction
    Bootloader.swift            update-mode conversation and FirmwareUpdater
    UpdateMode.swift            waiting for the bootloader; product check
    Catalogue.swift             FlySky downloads page + FlySky Assistant catalogue
    MockRadio.swift             simulated transmitter (normal firmware)
    MockBootloader.swift        simulated bootloader (NOR-flash semantics)
  Sources/noble/                command-line tool
  Sources/NobleLinkApp/         SwiftUI app (AppModel.swift = state + flows, NobleLinkApp.swift = views)
  Sources/NobleSelfTest/        test runner (plain executable, see below)
  Fixtures/                     stand-ins for FlySky's catalogue files, used by the tests
  Resources/AppIcon.icns
  scripts/build_app.sh          release build + .app bundle
  scripts/check_app_logic.sh    headless checks of the app's restore plan and install flow
docs/PROTOCOL.md                protocol, formats, firmware update – with sources
tools/                          reverse-engineering helpers (Ghidra scripts, decompiler-output cleaners)
```

## Build and test

```sh
cd NobleLink
swift build
.build/debug/NobleSelfTest ../samples        # ~60 checks with no samples, ~200 with them
./scripts/check_app_logic.sh BACKUP.fsdll     # app logic incl. a full simulated firmware install
./scripts/build_app.sh                        # dist/NobleLink.app, dist/noble
```

- The toolchain may be the Command Line Tools only: **no XCTest / swift-testing** (hence
  `NobleSelfTest` is an executable) and **no SwiftUI `@State`** (macro plugin missing) – keep view
  state as `@Published` properties on `AppModel`.
- `samples/` is git-ignored and holds real files: `samples/models/*.fsdll` (backups),
  `samples/models_1.0.22/`, `samples/firmware/*.exe` (FlySky's Windows updaters, downloadable from
  flysky-cn.com). Tests that need them are skipped when absent. Never commit FlySky's binaries or
  personal backups.
- Everything is testable without hardware: `MockRadio` and `MockBootloader` model the firmware's
  behaviour, including its awkward parts. Extend them when you learn something new about the real
  device, and add a check.

## Rules that keep a transmitter safe

1. **Model data is a sequential stream.** The transmitter ignores the offset in a `0x69` request and
   just returns the next bytes. Never re-send a data request; send `0x64` to restart the stream and
   re-read the whole area instead.
2. **Validate before writing.** `BackupFile.validate()` must have no errors; `RadioSession.preflight`
   runs before any packet is sent.
3. **Safety copy first.** Every write flow (restore, reset, firmware) saves a full backup first.
4. **Retag records when moving a model** (`Model.retargeted(toSlot:)`): the firmware may use each
   record's `owner` byte to choose the slot.
5. **Don't mix firmware versions.** Imports match settings by number and updates renumber them;
   backups from other firmware are refused unless explicitly forced.
6. **Firmware install:** product check, integrity checks, compare (read-only), explicit
   confirmation, then erase/write, then CRC16 + CRC32 verification. Restart only after success.
   Never touch addresses below the application (the bootloader).
7. Anything new about the hardware goes into `docs/PROTOCOL.md` with how it is known
   ([host] vendor app, [fw] transmitter firmware, [file] real files, observed on hardware).

## What is verified on real hardware

Noble plus EN (VID 0x284E, PID 0x8D09): device info, listing, backup, restore (moved + renamed
models), firmware probe and install 1.0.22 → 1.0.31 (2026-11-12). Not yet on hardware: factory
reset, system-settings restore, the app's install screen (simulated end to end only), other models.

## Ideas

- Support for other Noble/NB4 variants and the PL18 family (same protocol family; needs testing).
- A settings-ID dictionary so `noble dump`/`diff` can show names instead of numbers.
- A migration map between firmware versions so old backups can be converted instead of refused.
