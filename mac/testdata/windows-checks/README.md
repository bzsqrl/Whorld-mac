# Windows checks

Two snapshots for questions only Windows Whorld can answer (PORT_PLAN.md status line; Phase 8 task 1 and "zero-width strokes"). Each is a grid of white line rings on black, made for a 1920×1080 screen.

- **`tight loops.whs`**: three-sided rings (radius 90) whose curves make small loops at each vertex, under lines wider than the loops. Rows: line widths 20, 40 and 60. Columns: curve 1.1, 1.15, 1.2, 1.25 and 1.3 (even and odd alike, shear 0). Where a loop is tighter than half the line width, the Mac's stroke geometry and Apple's stroker draw the outside of the blob about a pixel apart (0.15% of pixels antialiased); Windows shows which one Direct2D matches.
- **`zero width.whs`**: the same rings with curves 0 (straight), 0.5, 1.0, 1.3 and 1.6. Rows: line widths 0, 0.5 and 1. The Mac skips a zero-width stroke, so its top row is empty; Windows shows whether Direct2D draws a hairline instead. The rows below are there for comparison.

## Taking the screenshots

As for `../screenshots` (see `../README.md`):

1. Windows display scaling at the value used before; Whorld full screen (F11) at 1920×1080.
2. File > Load Snapshot, then a screenshot with Image > Antialiasing off, and another with it on. Change nothing in between (no zooming).
3. Save them as PNG, named after the snapshot: `tight loops.png` and `tight loops-aa.png`, `zero width.png` and `zero width-aa.png`.

## Afterward

Move each `.whs` into `../snapshots` and its screenshots into `../screenshots`. The screenshot tests (`test_metal` `MetalMatchesWindowsScreenshots`, `test_golden` `ScreenshotsImmediate` and `ScreenshotsDeferred`) then check both renderers against them.
