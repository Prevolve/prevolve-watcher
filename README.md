# prevolve-watcher

David's gcode watcher: watches the Dropbox customer folders, queues new
gcode to SimplyPrint, and tags/routes production files to printers.

**David (@david-at-prevolve) owns this repo** — push the watcher program
here, any structure you like. This README just seeds the integration
contract so the watcher and the slicing pipeline stop guessing at each
other's rules; correct it wherever it's wrong.

## Gcode filename convention (as the slicer emits it)

```
<order>_<Part>[_<side/rev>][_<tags>]__<Color>_<Vendor>_<Material>_<PrinterModel>.gcode
```

Examples:

- `1518_CleatPlate_L_Transparent_Creality_HP-TPU_P1S.gcode`
- `1474_Upper3D_R_Transparent_Siraya Tech_85A TPU_White_Overture_TPU_White_Kingroon_PLA_White_SIraya Tech_RoamR_U1.gcode`
  (multi-material: color+vendor+material repeats per filament)
- `2RnD_CleatPlate_NPopt_ST35__Transparent_Creality_HPTPU_P1S.gcode`
  (R&D pseudo-order `2RnD`; `NPopt`/`ST35` are non-planar experiment tags)

Naming logic lives in the slicer pipeline (`Prevolve/prevolve-slicer`,
see `gcode-naming-fix-2026-07-18.md` for the multi-material grouping
rules).

## Watched locations (as understood on 2026-08-14 — David, please verify)

- `P:\Prevolve Dropbox\Customers\<order>_<name>\...` — production orders
- `P:\Prevolve Dropbox\Customers\2_RnD\nonplanar-tests\` — R&D non-planar
  test prints (drop = print within minutes, so files land here only when
  immediate printing is intended)

Measured behavior on first R&D use: file queued in SimplyPrint ~3 min
after the Dropbox copy, auto-dispatched to a matching idle printer ~3 min
after that.

## Open integration questions

- What exactly does the watcher parse from the filename (which tokens
  drive tagging/routing)?
- How are printers matched (SimplyPrint queue matcher vs watcher-side
  rules)?
- Where should slicer-side changes (new parts, new tags like `NPopt`) be
  declared so the watcher picks them up without code edits?
