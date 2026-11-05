# Core Graphics renderer

Objective-C++ implementation of the engine's `IRenderer` interface.

- `CGRenderer.{h,mm}`: `CGBitmapRenderer` draws into a BGRA premultiplied bitmap it owns, like the Direct2D swap chain. The y-flip and Retina backing scale are applied in its transform, so the engine always draws in Direct2D DIPs with a top-left origin. It reproduces Direct2D's even-odd fill, clipped miter joins, negative-width strokes and pixel-exact quad mirroring.
- `ImageCompare.{h,mm}`: PNG loading and image comparison for golden tests.
- `VideoWriter.{h,mm}`: video export with AVFoundation, a Mac-only feature (H.264, HEVC, ProRes 422 and 4444, sRGB-tagged), plus `ExportMovieVideo`, which drives the engine through a movie.
- `RenderJobs.{h,mm}`: offscreen jobs shared by `whorld-render` and the tests. They reproduce Windows Export All for snapshots and run a patch for N frames.
- `tests/`: renderer unit tests (`test_cgrenderer`), golden-image tests against `mac/testdata/golden` (`test_golden`), and video round-trip tests (`test_video`).

See `PORT_PLAN.md` "Port notes" for what was verified against Windows.
