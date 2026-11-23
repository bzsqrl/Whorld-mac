# Sample patches and playlists

Files here are bundled with the app and copied into `~/Documents/Whorld` the first time Whorld runs:

- `Patches/`: `.whp` patches, copied into `Documents/Whorld/Patches`
- `Playlists/`: `.whl` playlists, copied into `Documents/Whorld/Playlists`

Each file is copied once. A file with the same name already there is left alone, and a sample the user has deleted isn't copied again. Samples added in a later version are copied the first time that version runs (`WhorldFolders.installSamples` in `Whorld/Preferences.swift`).

The build writes the sample playlist, `Whorld Samples.whl`, from the `.whp` files at the top of `Patches/`, in order of file name, so name the patches to set the order (the first is the one shown at first launch). The first time Whorld runs, it opens that playlist and plays its first patch. To set the playlist by hand instead, put a `Whorld Samples.whl` in `Playlists/`; it's used as it is.

In a playlist, give each patch as its file name alone (`Path=bloom_cvx.whp`), with no folder: Whorld finds it beside the playlist or in `Documents/Whorld/Patches`, so the playlist works on any Mac. Don't commit a playlist saved by Whorld as it is: its paths include your home folder.

The build copies these folders into `Whorld.app/Contents/Resources/Samples` (the Copy Help and Samples phase in `generate_project.py`). Only `Patches` and `Playlists` are copied; this README isn't.
