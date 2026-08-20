# Watch2Print

Watches a folder for new print files and uploads, queues and tags them automatically on
SimplyPrint, Printago, or 3DPrinterOS (Printago and 3DPrinterOS currently still under development). It replaces the manual upload-and-tag step between
slicing and printing.

Built for [Prevolve Footwear](https://prevolvefootwear.com)'s print farm and used in
production there daily.

---

## What it does

Point it at a folder. When a file appears, Watch2Print:

1. Waits for the file to finish writing and syncing before touching it (important step when using cloud based file storage)
2. Reads the filename for job, part, side, colours, brands, materials and machine model (see naming convention's below)
3. Uploads it, splitting into 50 MB chunks when the file is large
4. Adds it to the queue, routed to the right printer model
5. Waits for the platform to analyze the file, then applies material, color, and machine tags
6. Moves it up the queue if the filename asks for it (via priority system in naming convention)
7. Records it so it is never sent twice

The interface runs in your browser at `http://localhost:8787` or adjacent port if 8787 is found to be busy. The application itself
lives in the system tray — there is no console window.

## What it watches

- **One folder, including everything beneath it.** Subdirectories are followed, so a
  customer-per-folder layout works without configuring each one.
- **File types are configurable.** `.gcode`, `.3mf` and `.stl` are one click each, and
  any other extension can be added as a comma-separated list. It is not G-code only.
- **Detection is event-driven**, not polled: a file is normally picked up within seconds
  of the slicer finishing with it. A periodic full re-scan runs as a backstop in case the
  operating system drops a file event.
- **Dropbox conflicted copies are skipped** automatically.

### Note:
If you manually move files to an archive, a subfolder, or any different location still within the watched folder;
the files will still be picked up by the watcher as new items/ events due to the new file location. To mitigate
this preemptively and especially if you are doing this en-masse, create a list of these files and add them to the
.txt ledger file, stop the watcher, move the files, then start the watcher again. On startup, at the start of every
safety scan, and when the user clicks "reload history" at the bottom, the ledger is reloaded to memory. By
stopping, adding new locations to the ledger, moving files, then starting the watcher again, the user utilizes one
of these situations in which the ledger is reloaded to memory to prevent falsely uploading files. Other active methods
like using the "reload history" button are also valid approaches but result in similar outcomes with potentially
higher risk as a result of human error.

---

## Install

### Windows

Download the latest `Watch2Print-Setup-x.y.z.exe` from
[Releases](../../releases) and run it.

- Installs per-user. **No administrator rights and no UAC prompt.**
- Windows SmartScreen will warn that the publisher is unrecognized — the build is not yet
  code-signed. Choose **More info → Run anyway**.
- Optionally starts with Windows; this can be changed later from the interface.
- Uninstall via native "Add/ Remove" tool

### Linux

PowerShell 7 is the only dependency. There is no installer and no tray icon; it runs as a
systemd user service.

```bash
# 1. PowerShell 7 (Ubuntu example)
sudo apt install -y powershell

# 2. Run once to create a settings file
pwsh -NoProfile -File ./Watch2Print_Web.ps1 -NoBrowser

# 3. Configure at http://localhost:8787, then install the service
./install-linux.sh
```

The installer checks the inotify watch limit against the size of your folder tree and
tells you how to raise it if the tree is bigger. Over the limit, new files are missed
with no error at all.

macOS is untested. The engine has no Windows-only dependencies and should run under
PowerShell 7, this is currently under development as well.

---

## Filename format

Filenames are parsed with a strict structure. Files that do not match still upload, but
may not be tagged. We are a shoe company so forgive us if there are superfluous categories for your needs

```
{Job}_{Partname}_{Side}_{Color}_{Brand}_{Material}_{MachineModel}.gcode
```

The parser reads right-to-left: it takes the machine model first, then walks backwards in
three-token chunks of `(Material, Brand, Color)` for as many materials as it recognizes,
stopping at the first token that is not a known filament type.

```
1425_FoamHeelCup_R_Black_SirayaTech_FlexTPUAIR_P1S.gcode
```

| Field | Value |
|---|---|
| Job | `1425` |
| Part | `FoamHeelCup` |
| Side | `R` |
| Colour / Brand / Material | `Black` / `SirayaTech` / `FlexTPUAIR` |
| Machine | `P1S` |

**Multi-material** — up to four `(Color, Brand, Material)` chunks stack between the side
and the machine:

```
1425_FoamShell_L_White_Polymaker_PLA_Black_Polymaker_PLA_P1S.gcode
```

**Rush jobs** — append `-N` to the partname to force a queue position, where 1 is the top:

```
1425_FoamHeelCup-1_R_Black_SirayaTech_FlexTPUAIR_P1S.gcode
```

New rush jobs land below any priority jobs already in the queue and are ordered among
themselves by number, so a rush job never reshuffles work already scheduled.

## IMPORTANT
Rush jobs land in chunked groups (defined by time allotted in settings, 5min default),
if you set a priority of 4 but only have 3 files, errors may occur. This has not been
tested at length. We use priorities 1 and 2 sparingly for our parts.

---

## Platform support

| Capability | SimplyPrint | Printago | 3DPrinterOS |
|---|---|---|---|
| Upload | yes | yes | yes |
| Chunked upload (>100 MB) | yes | n/a (PUT) | no |
| Queue add | yes | yes | yes (per printer) |
| Copies / amount | yes | yes | emulated |
| Group | yes | no | project name |
| Machine-model routing | `for_models` | printer tags | printer id |
| Material / color tags | yes | no | no |
| Analysis polling | yes | no | no |
| U1 slot scoring | yes | no | no |
| Rush queue position | yes | no | no |

**SimplyPrint is production-proven.** Printago and 3DPrinterOS work but are still under
development and are not tailored to either platform as closely. Use **Dry run** first on
both — it prints every request it would send without sending anything.

---

## Credentials

API keys and passwords are encrypted before they are written to disk.

- **Windows** — DPAPI, tied to your Windows account on that machine.
- **Linux / macOS** — AES-256 with a key at `~/.config/watch2print/key.bin`, mode `600`.
  Keep that file off shared storage.

Encryption is bound to the machine and account, so credentials do not survive being copied
elsewhere — that is the point, and it means they must be re-entered after a move.

This protects a settings file from being read by accident: a synced folder, a screenshot,
a pasted file. It does **not** protect against someone who already has the user account.

---

## Where things live

| Path | Purpose |
|---|---|
| `%LOCALAPPDATA%\Programs\Watch2Print\Watch2Print.exe` | The application. The engine is inside it. |
| `%LOCALAPPDATA%\Watch2Print\watch2print_config.json` | Settings and encrypted credentials |
| `%LOCALAPPDATA%\Watch2Print\colormap.json` | Colour name → hex map |
| `%LOCALAPPDATA%\Watch2Print\Watch2Print_Engine_MP.ps1` | Engine, unpacked from the exe. Do not edit. |
| `%LOCALAPPDATA%\Watch2Print\watch2print.log` | Startup and server log |

On Linux, replace `%LOCALAPPDATA%\Watch2Print` with `~/.config/watch2print`.

---

## Download

[Download our most current release for Windows and Linux here.](https://github.com/Prevolve/prevolve-watcher/releases/latest)

--- 

## Updating

Settings → **Version** → **Check now**. If a newer build exists, an **Update** button
appears and downloads the installer.

The update source is a small JSON file at a web address or a file path — a farm with a
shared drive can point every machine at one file with no web host involved. Set
`updateUrl` in the config, or `$script:UpdateUrl` at build time.

```json
{
  "version": "1.1.0",
  "url": "https://example.com/Watch2Print-Setup-1.1.0.exe",
  "notes": "What changed."
}
```

Updates are downloaded, not installed silently. Windows locks a running executable, so the
swap is deliberately a manual step. This system is also under development, we aim for this
to be as seamless as possible moving forward.

---

## Known limitations

- **Unsigned.** SmartScreen warns once on first run.
- **Printago and 3DPrinterOS are under development** and less tailored than SimplyPrint.
- **The interface is localhost-only** by design. Remote monitoring would need
  authentication first, and there is none.
- **inotify limits on Linux.** A large tree can exceed the kernel watch limit, and going
  over it fails silently. `install-linux.sh` checks and warns.
- **macOS is untested.**
- **Updating process limitations and streamlining.

## License

Free to use. As thanks to the open source community with tools like [@OrcaSlicer](https://github.com/OrcaSlicer)
[@OctoPrint](https://github.com/OctoPrint) and many more that continue to make what we do possible; our goal is to
offer this free to use. Hopefully one day soon, we aspire to offer an avenue to donate where 100% of donations will
go towards getting more cleats in more hands. [Prevolve Footwear](https://prevolvefootwear.com/).
