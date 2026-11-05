# Test data

Reference files exported from **Windows Whorld V2 2.0.20** (the upstream baseline in `PORT_PLAN.md`). The patch round-trip, snapshot parsing and golden-image tests read from this folder.

## Layout

```
testdata/
  patches/     demo .whp patches from the Windows release
  playlists/   one or two .whl playlists (optional, for Phase 6)
  snapshots/   .whs snapshots
  golden/      PNG exports of the snapshots in snapshots/, same base name
  movies/      one short .whm movie (optional, for Phase 6)
```

## Checklist for exporting from Windows

1. **Patches.** Copy every demo `.whp` from the Windows release download into `patches/`. Keep the file names unchanged.
2. **Snapshots.** Take 6–10 snapshots (File > Take Snapshot, Ctrl+T) covering a variety of patches:
   - antialiasing on and off;
   - filled rings, outlines, and both together;
   - a patch that uses global parameters;
   - quad mirroring on;
   - transparency (alpha / background alpha below 100%);
   - at least one with a high ring count.

   If you have any V1 (legacy) snapshots, include one; the V1 format is decoded separately.
3. **Golden PNGs.** For each snapshot, load it and use Snapshot > Export All (or File > Export) to PNG. Use a **fixed size of 1024×768** with **Use view size** unchecked, and note the **Scale to fit** setting you used. Save each PNG under `golden/` with the same base name as its `.whs` file.
4. **Notes.** Add a `golden/EXPORT_SETTINGS.txt` listing the Whorld version, the export width, height and scale-to-fit setting, and the Windows display scaling (for example 100% or 150%).
