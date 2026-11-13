# FlySky Noble NB4+ USB protocol, backup format and firmware update

Reconstructed from:

* **FlySky Assistant 4.0.1 for macOS** (`FlySkyAssistant_V4.0.1_20250424.pkg`, x86-64 Qt 5 app with
  symbols) – the host side. Decompiled with Ghidra (scripts in `tools/`).
* **Noble Plus-EN firmware 1.0.22** (extracted from `Flysky_Noble+_EN_UpdateFirmware_1.0.22.exe`) –
  the transmitter side. The USB command handler is the function at `0x08086100`.
* **Noble Plus-EN firmware 1.0.31** – same handler, at `0x0808636C`.
* **FlySky's Windows firmware updater** (`…UpdateFirmware_1.0.31-4FCC.exe`, 8 KB of code, 12
  functions) – the authoritative host side of a firmware update.
* Real backups from a Noble plus EN.

FlySky's binaries and the decompiled output are not part of this repository; the scripts in
`tools/` reproduce the analysis from FlySky's own downloads.

Every statement below is tagged by how it is known:

* **[host]** read from the vendor application
* **[fw]** read from the transmitter firmware
* **[file]** checked against the real backup / firmware files
* **[guess]** inferred; treat with care

Listing, backup and restore have been run successfully against a real Noble plus EN (firmware
1.0.5). The firmware update has not. See "What is still unverified".

---

## 1. USB identity and transport

| | |
|---|---|
| Vendor ID | `0x284E` [host] |
| Product ID | per model, from `Product_ID_List._Sendor.csv`: Noble plus CN/EN/EU = `0x8D08` / `0x8D09` / `0x8D0A`, Noble Pro plus = `0x8D0B…0D`, NB4 = `0x8D00`, NB4 Pro = `0x8D03/05/06/07` … [host] |
| Class | HID, un-numbered reports [host] |
| Report size | 280 bytes each way [host][fw] (the firmware copies `0x118` bytes) |

The vendor tool uses `hidapi`; on Windows it picks the interface whose path contains `mi_00`,
on macOS whichever HID interface enumerates last. NobleLink prefers the interface whose output
report is at least 280 bytes.

### Report layout (little-endian)

```
offset size field
     0    4 seq       host counter: starts at 2, +1 per report, wraps to 2 after 100000  [host]
     4    4 command
     8    4 a
    12    4 b
    16    4 c
    20    4 d
    24  256 payload   zero padded
```

* The firmware only acts on a report whose `seq` differs from the previous one [fw].
* The reply echoes `seq` and `command`; `a…d` and the payload are command specific [fw].
* Commands the firmware does not know are simply not answered [fw].
* The vendor tool sleeps 1 ms before and 10 ms after every write, and reads with a 100 ms timeout [host].

---

## 2. Application commands

`a` is a direction flag for most of them: `0` = read, `1` = write.

| Cmd | Name (ours) | Request | Reply | Source |
|---|---|---|---|---|
| `0x01` | version | – | payload `0x30` bytes: `0x00…0x27` copied from the bootloader's info block at `0x08000208`; `0x28…0x2F` from the application (`+0x28` patch, `+0x2B` minor, `+0x2E` major) | [host][fw] |
| `0x64` | storage info | `a=0` | `b`=field1 (1), `c`, `d`=firmware version (`major<<16 | minor<<8 | patch`), payload: `+0` field3 (1), `+4` total size, `+8` system-block size, `+12` model count (constant 25), `+16` model-block size. **Also resets the data-stream state.** | [host][fw] |
| `0x64` | announce import | `a=1`, `b`=file field1, `c`=file product ID, `d`=firmware version stored in the file, payload `+16`=model size | echo of `a` | [host][fw] |
| `0x69` | data block | `a`=0/1, `b`=area, `c`=offset, `d`=length ≤ 256 (+payload when writing) | echoes `a b c`, `d`=min(d,256), payload when reading | [host][fw] |
| `0x6A` | model name | `a=0`, `b`=slot | `c`=14, payload = 14 name bytes + NUL. `b`=0xFF if slot ≥ 25 | [host][fw] |
| `0x6A` | set model name | `a=1`, `b`=slot, `c`=0x14, payload = name | echo | [host][fw] |
| `0x6B` | commit | – | `b`: 0 = done, 1 = busy (ask again) | [host][fw] |
| `0x6C` | set mode | `b`=mode | `b`=mode. For mode 6: `b`=0xFF,`c`=1 if busy with a receiver | [host][fw] |
| `0x6D` | receiver status | – | `b` bit0 = receiver linked, bit1 = (RF state 3) | [host][fw] |
| `0x6F` | unique ID | – | `b`=0x60, payload = the MCU's unique ID as 24 hex digits (`%08X%08X%08X`) | [host][fw] |
| `0x70…0x75` | receiver info / receiver firmware update | | | [host] not needed here |
| `0x76` | model order table | | Not implemented by firmware 1.0.22 (never answered; the vendor tool carries on after 500 ms). Firmware 1.0.31 does handle `0x75`/`0x76`; NobleLink does not use them. | [host][fw] |

### Modes (`0x6C`, argument `b`)

| b | When the vendor tool sends it |
|---|---|
| 1 | on connect, and whenever it leaves a page or an operation ends ("idle") |
| 2 | start of a transmitter firmware update |
| 3 | before exporting or importing models (waits for the echo `b == 3`) |
| 4 | before listing models; again at the start of the import thread |
| 6 | device-information / receiver pages |

In firmware 1.0.22 the handler just stores the value and sets a small counter; the main loop reads it [fw].

### Areas (`0x69`, argument `b`)

| b | Area |
|---|---|
| 0 | everything (all models + system block) |
| 1 | system ("global") settings block, 493 bytes on the NB4+ |
| 2…26 | model slot `b − 2` (0…24), 0x42DC = 17 116 bytes each |
| ≥ 27 | invalid: reply has `d = 0` |

Firmware 1.0.31 keeps all of this and adds error reporting: when a completed write fails its
final check the reply has `d = 0`, and a write past the end of an area is likewise answered with
`d = 0` [fw]. NobleLink already treats any reply whose `d` differs from the requested length as a
failure.

### The data stream is sequential – the important part [fw]

Reading (`a = 0`):

1. On the **first** `0x69` read after a reset, the firmware snapshots the configuration and serialises
   the requested area into a stream.
2. Every `0x69` read then returns the *next* `d` bytes of that stream. **The `c` (offset) field is
   only echoed back; it does not seek.** Bytes past the end read as `0xFF`.
3. The stream is only restarted when `c + d ≥ total size` (never true for a single area) **or when a
   `0x64` request arrives**.

Consequences:

* Send `0x64` before reading each area. (The vendor tool does – it looks like a harmless status
  poll in its code, but it is what makes per-model export work.)
* **Never repeat a `0x69` request.** A duplicate silently skips 256 bytes and shifts everything
  after it. This is what the vendor tool's "communication timed out – restart the transmitter"
  message is about: its 100 ms read timeout causes exactly this.
* To retry an area, send `0x64` and start again from offset 0.

Writing (`a = 1`):

1. Refused (`b = 0xFF` in the reply) when a receiver is linked **and** the target is area 0 or the
   currently active model.
2. Bytes are fed one by one into a deserialiser, again sequentially; `c` is not a seek.
3. When `c + d` equals the area's size the firmware finalises: it checks a status flag and applies
   the data.
4. `0x6B` afterwards saves; reply `b = 1` means "still busy".

There is no command to abandon a half-written area. If a write is interrupted, power-cycle the
transmitter before trying again (nothing is applied until an area completes).

---

## 3. Sequences

### List models (`GetOutPutListThread`)

```
0x6C b=4            until echoed
0x6D                reply b bit0 set → "please switch the receiver off", stop
0x64                storage info
0x6A b=i            for i in 0 ..< modelCount → names
0x76                (unanswered on the NB4+)
```

### Export (`OutputThread`)

```
0x6D                receiver must be off
0x6C b=3            wait for echo b == 3
0x64
0x6A b=slot         for each selected model (reply c = 14 is stored in the file)
if all models selected:
    0x69 a=0 b=1 c=0,256,…        two chunks → 512 bytes (493 real + 0xFF filler)
for each selected model:
    0x64                          (resets the stream)
    0x69 a=0 b=slot+2 c=off d=len until 17116 bytes read; first 21 bytes all 0xFF → error
write file
```

### Import (`InputWidgetForm::onStartInput` → `InputThread`)

```
0x6D                receiver must be off
0x6C b=3            wait for echo
0x76 a=1 …          (unanswered on the NB4+; 500 ms timeout)
0x6C b=4
0x64 a=1 b=file.field1 c=file.productID d=file.firmwareVersion payload[16..20]=modelSize
[system block – only if ≥ 20 models are imported and the product matches]
    0x69 a=1 b=1 c=off d=len + payload
for each model:
    0x69 a=1 b=slot+2 c=off d=len + payload     (blocking read for each ack)
    0x6A a=1 b=slot c=0x14 payload=name
0x6B                until reply b == 0
```

`d` is the version of the firmware that saved the file (`0x00010016` = 1.0.22, `0x0001001F` =
1.0.31; the same value the transmitter returns in the `0x64` reply) [fw]. On import both 1.0.22 and
1.0.31 test `d < 0x0001000B` and set an "old format" flag, i.e. data saved by firmware older than
1.0.11 is converted [fw]. The sample backups carry `0x00010005`: they were saved by firmware 1.0.5.

#### A vendor bug worth knowing about

When importing, the vendor tool splits the file as `models = file[0 ..< size − systemSize − 0xE24]`
and `system = the next systemSize bytes`. With a 512-byte stored system block and a 3624-byte
(`0xE28`) directory, that is **23 bytes too late**: the system data it sends starts in the middle of
the third record and ends with 0xFF filler and the first directory bytes. NobleLink sends the 493
bytes exactly as they were read. Because this deviates from what FlySky's own tool has ever sent,
restoring system settings is **off by default**.

---

## 4. Settings records

Model blocks and the system block are sequences of records:

```
0D 0A | length (BE16) | 15 | owner | element | id (BE16) | value … | xor
```

* `length` counts everything after itself.
* `xor` is the XOR of all preceding bytes of the record, `0D 0A` included.
* `owner` = model slot (0…24), or `0xA0` for system settings.
* `element` = index for per-channel / per-condition settings.
* Values are little-endian. A model block on the NB4+ is exactly 1430 records with no padding. [file]

**How the transmitter imports a model [fw].** Bytes written with `0x69 a=1` go to a record parser
(`FUN_0808d898` in 1.0.22) that is fed after every chunk. For each complete, checksummed record it
looks the setting ID up in the firmware's own table; unknown IDs are ignored, known ones are copied
into the model using the *table's* length for that setting. Settings absent from the incoming data
keep their current value. The target slot is the area being written for model-type settings, and
otherwise the record's `owner` byte. Consequences:

* A backup from **older** firmware is accepted by the transmitter even though its model size
  differs, but it is **not reliably correct**: firmware updates renumber some settings, and an
  import matched by number then puts those values into the wrong settings. Observed 1.0.22 → 1.0.31:
  the values of `0x0845…0x0851` moved up by one or two numbers (`0x0845`, `0x084F`, `0x0851` no
  longer exist) and `0x108E…0x1095` were re-laid. NobleLink therefore refuses older-firmware
  backups unless asked (`--allow-older-firmware`).
* The firmware update itself converts the models already stored on the transmitter, correctly
  (observed on a real Noble plus EN going 1.0.22 → 1.0.31: all 25 models kept, model size
  20 672 → 21 890 bytes, 1 723 of 1 726 settings kept, 3 dropped, 101 new, the renumbered values
  carried to their new numbers – contrary to FlySky's notes, which say models are reset).
* The "old format" flag set by `0x64 a=1` when `d < 0x0001000B` only makes the parser skip setting
  `0x07D9`.
* Setting `0x0FDB` grew from 8 to 32 bytes in 1.0.22. Imported from older data, the parser copies 32
  bytes from an 8-byte value, i.e. 24 bytes of whatever follows in its buffer – which is why that
  field holds fragments of names in data that went through such an import.

**Names.** A model's name exists twice: in record `0x07D1` (15 bytes: 14 characters + NUL) and
in what `0x6A` reads and writes (14 bytes). Renaming therefore means rewriting that record (same
length, new check byte) as well as sending the new name with `0x6A`; NobleLink does both.

**Moving a model to another slot.** FlySky's tool sends the block unchanged, so its records still
carry the slot they were saved from in `owner`. NobleLink rewrites `owner` (and each check byte)
to the target slot, which makes the block identical to what the transmitter itself would produce
for that slot – correct whether the firmware ignores `owner`, checks it, or acts on it.

Known IDs: `0x07D0` = `A5` marker (first record of every model), `0x07D1` = model name (15 bytes),
`0x0064` = `A5` marker of the system block, `0x0FFA…` = channel names. Everything else is carried
opaquely; `noble dump` and `noble diff` show them by number.

---

## 5. `.fsdll` backup file

```
[ model block 0 ] … [ model block n−1 ] [ system block, optional ] [ directory, 3624 bytes ]
```

Directory = 24-byte header + 100 × 36-byte entries (unused entries zero), all little-endian.

| Header offset | Field |
|---|---|
| 0 | USB product ID (`0x8D09`) |
| 4 | field1 = `0x64` reply `b` |
| 8 | firmware version that saved the file = `0x64` reply `d` (`0x00010005` = 1.0.5) |
| 12 | field3 = first payload word of the `0x64` reply |
| 16 | model count |
| 20 | system block size (493), or 0 when the file holds only some models |

| Entry offset | Field |
|---|---|
| 0 | name, 20 bytes, NUL padded |
| 20 | slot |
| 24 | `0x6A` reply `c` (14) |
| 28 | offset of the block in the file |
| 32 | block size |

The system block is stored rounded up to 512 bytes because it is read in two 256-byte chunks.

Checked [file]: NobleLink re-serialises both sample backups byte for byte, and a backup taken from
its simulated transmitter (loaded with the same data) is byte-identical to the vendor's file.

Model compatibility (`ModelInPut.txt`): the vendor tool imports silently when the product IDs match,
asks first when they are in the same family (all NB4 / Noble variants are one family), refuses otherwise.

---

## 6. Firmware

### Files

FlySky publishes Windows programs named `Flysky_<model>_UpdateFirmware_<version>.exe`. They are
small stubs with the payload in plain RCDATA resources [file]:

| Resource | Content | 1.0.22 size |
|---|---|---|
| 900 | main firmware, for the MCU's internal flash | 891 710 (FCC build: 891 634) |
| 901 | "resource" image for the external flash (fonts, pictures, translations) | 5 695 664 |

Main firmware image [file]:

* ARM Cortex-M image linked at `0x08008000`; a bootloader lives below it and is **not** part of
  the update.
* `+0xF88` u32 = image length without the trailer.
* `+0xF8C`: version – patch at `+0`, minor at `+3`, major at `+6`.
* Last two bytes = CRC-16/CCITT-FALSE (poly `0x1021`, init `0xFFFF`), little-endian, over
  everything before them.

`noble firmware inspect FILE` checks all of this.

### Finding out about new versions

FlySky publishes through two channels that are **not kept in step**:

1. **The downloads page** – for the NB4+ `https://www.flysky-cn.com/noble-nb4plus-downloads`. Each
   entry is labelled like "FCC Firmware v1.0.31(EN version)" followed by a link (text "DOWNLOAD") to
   a Windows updater `.exe`. On 2026-11-12 it listed 1.0.31 (FCC and STD, EN and EU, dated
   2026-09-14) and release notes dated 2026-09-10. The links redirect to Squarespace storage over
   HTTPS and were reachable from here.
2. **FlySky Assistant's device catalogue** (below). On the same day it still stopped at 1.0.22.

`noble firmware check` and the app's *Check for Updates* read both.

**FCC and STD builds.** Every release comes in two builds. Their resource images are identical; the
firmware differs only in code (no marker at a fixed offset). The transmitter's About screen shows
which one it runs (`"Firmware %sstd."` or `" %sFCC"`); nothing in the USB replies reveals it.

### FlySky Assistant's catalogue [host][file]

1. `GET http://enyaokongguanjia.maxhom.cn/index.php?g=App&m=yaokong&a=login&username=&yzm=&nologin=1`
   (alternative host `aaa.flyskytech.com:88`, often unreachable from outside China). Anonymous; the
   JSON reply maps configuration file names to `{md5, url}`.
2. Fetch `OnlineDevice.ini` from that list. Each `[DirectN]` section has `name=` and numbered
   `binK=` (firmware), `falshK=` (resource image), `helpK=` (release notes) entries, newest first,
   FCC and non-FCC builds listed separately.

`noble firmware check` does this. On 2026-11-11 the newest listed for "Noble plus EN" was 1.0.22.

The binaries themselves are on `aaa.flyskytech.com:90`, which timed out from here; the mirror
answers any path with an HTML page, so it is not a substitute. The `.exe` from FlySky's website
contains the same two images.

### How the transmitter gets into update mode [fw]

The flashing commands are not handled by the normal firmware at all. They are answered by a
separate bootloader (below `0x08008000`, never part of an update file):

1. The transmitter's *Firmware Update* screen is opened – from its own menu, or by the PC sending
   `0x6C b=2` (the firmware opens UI page `0x73` once mode 2 has been set for one second).
2. That screen waits until storage is idle, writes the words `0x1AE811C9` and `0x7F5594AC` to RAM
   at `0x20000000`, and resets the processor (`FUN_08021b84` in 1.0.22).
3. The bootloader finds the marker and stays in update mode, answering commands `0x01` and
   `0x03…0x08` over the same 280-byte HID reports.

FlySky's Windows updater never sends `0x6C b=2`: it expects the transmitter to be in update mode
already, and accepts a device with product ID `0x8D09` under vendor ID `0x284E` or `0x9243` [host].

**Observed on a real Noble plus EN (2026-11-12, bootloader 1.1, firmware 1.0.22):** System →
Firmware Update → YES drops the USB connection for a few seconds; the bootloader then enumerates as
`284E:8D09` (same identity; its product string is malformed – "Flysk" plus stray bytes). It answered
`0x01` and `0x06` as described below, and `0x07` restarted it into the normal firmware. All 87
block checksums it reported equal the CRC (as defined below) of the installed 1.0.22 resource image,
which confirms the checksum definition and the `0x80000` base address. Like the normal firmware, the
bootloader leaves stale values in reply fields it does not set.

### Bootloader conversation (Windows updater) [host]

Framing differs slightly from the model protocol: the sequence number starts at 0 and is
incremented *before* each request; each request is sent once; the reply is the first report with
the same sequence number; 2 seconds without one is a failure.

| Cmd | Request | Reply |
|---|---|---|
| `0x01` | – | payload `+0` u32 bootloader version (`hi16.lo16`), `+0x28…0x2F` installed firmware version words, all `0xFF` if no firmware is installed |
| `0x03` | `a` = firmware size | erase the application area |
| `0x04` | `a` = address, `b` = 0 → erase 4 KiB, `b` = 2 → erase 64 KiB | |
| `0x05` | `a` = address, `b` = length, `c` = 1 internal / 2 external flash, payload | pieces never cross a 256-byte address boundary |
| `0x06` | `a` = address, `b` = length ≤ 64 KiB, `c` = seed | `c` = CRC32 of that stretch of external flash. Read-only. |
| `0x07` | – | restart (not answered) |
| `0x08` | `b` = firmware size − 2 | `c` (low 16 bits) = CRC-16/CCITT-FALSE of that many bytes of the application |

The CRC32 is zlib's `crc32(seed, data)` called with seed `0xFFFFFFFF` for a fresh sum, so the
register effectively starts at 0; passing a previous result as the seed continues the sum.

The updater sends `0x01` twice when it finds a device and refuses to continue if the bootloader
version word is greater than `0x00010002` ("1.2"; the 1.0.22 updater allowed up to "1.1"). Then:

```
1. 0x06 for each 64 KiB block of the resource area (0x80000 …)      what is installed now?
2. 0x03 a=firmwareSize                                             erase the application
3. 0x04 for every run of blocks whose CRC differs from the image   64 KiB erases (b=2), with
                                                                   4 KiB erases (b=0) for a short tail
4. 0x05 c=1 firmware, offset 0 …
5. 0x05 c=2 only the blocks that differ
6. 0x08 b=size−2      reply must equal the CRC16 in the image's last two bytes
7. 0x06 over the whole resource image, chaining the seed across 64 KiB requests;
        the result must equal the image's CRC32
8. 0x07               restart
```

The 1.0.22 and 1.0.31 updater programs are byte-identical apart from the version number they
display and that bootloader-version limit, so this procedure is stable across releases [file].
Between 1.0.22 and 1.0.31, 85 of the 87 resource blocks differ.

FlySky Assistant for Mac (`SendorUpdateThread::run`) implements an older variant: `0x6C b=2`,
`0x03` repeated every 5 s for up to 30 s, write firmware, `0x08` with no arguments, erase the whole
resource area in 64 KiB steps, write all of it, one `0x06` over the lot, `0x07`. NobleLink follows
the Windows updater.

### Observed first update (2026-11-12, Noble plus EN, 1.0.22 FCC → 1.0.31 FCC)

Run with `noble firmware flash`, 6 min 48 s in total. `0x03` (erase application) and each `0x04`
answered at once; 99 erase requests (one 64 KiB block alone, then 83 × 64 KiB and 15 × 4 KiB for
the run up to the shorter last block); about 25 300 `0x05` writes, each acknowledged with the same
address. `0x08 b=894556` replied `c = 0x06CD` (the image's CRC16) and the chained `0x06` over the
resource image ended at `0x1883166E` (its CRC). `0x07` restarted the transmitter into 1.0.31.

### If an update is interrupted

The bootloader is not erased by any of these commands. If the application has been erased and the
update does not finish, the transmitter simply stays in (or powers up into) update mode and the
whole procedure can be run again from step 1. The firmware's own text calls this the "mandatory
update mode".

Other things the firmware's text says about updating:

* "Updating the transmitter firmware may cause model data to be restored to factory defaults." –
  back up first.
* "Do not operate the transmitter during firmware update!"

From FlySky's release notes for 1.0.31 (2026-09-10): models are reset by the update (back up first,
import afterwards); calibrate the sticks after updating; re-bind transmitter and receivers; and
**"firmware for hardware 1.2 cannot be downgraded to version 1.0.22 or below"**. The 1.0.31 updater
accepts bootloader versions up to 1.2, the 1.0.22 updater up to 1.1.

---

## 7. What is still unverified

Verified on a real Noble plus EN (firmware 1.0.5): device discovery and HID transport on macOS,
device information, model list, full backup, restore.

Verified against real files: the backup format (byte-exact), record format and checksums, firmware
image format and CRC16, firmware version encoding, the catalogue request, and that the two updater
programs share their code.

Read from both sides (host and transmitter firmware): report layout, storage info, model names,
data-block semantics, receiver check, commit, mode switch – in firmware 1.0.22 and 1.0.31.

Not yet verified on hardware:

1. The bootloader's writing commands (`0x03`, `0x04`, `0x05`, `0x08`): known only from the host side
   (FlySky's Windows updater). Entering update mode, identification, the read-only checksum `0x06`
   and the restart `0x07` have been confirmed on hardware.
2. Whether the model-block size of firmware 1.0.31 equals that of 1.0.5 (17 116 bytes). The record
   stream is self-describing and the firmware has an "old format" import path, but if the size
   differs NobleLink will refuse to restore an old backup rather than guess.
3. Restoring system settings with correct alignment (see the vendor bug above).

`noble firmware probe FILE` exercises items 1's communication read-only: it identifies the
bootloader and runs step 1 of the update (the CRC comparison), then restarts the transmitter.
