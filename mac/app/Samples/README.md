# Sample patches and playlists

Files here are bundled with the app and copied into `~/Documents/Whorld` the first time Whorld runs:

- `Patches/`: `.whp` patches, copied into `Documents/Whorld/Patches`
- `Playlists/`: `.whl` playlists, copied into `Documents/Whorld/Playlists`

Each file is copied once. A file with the same name already there is left alone, and a sample the user has deleted isn't copied again. Samples added in a later version are copied the first time that version runs (`WhorldFolders.installSamples` in `Whorld/Preferences.swift`).

In a playlist, give each patch as its file name alone (`Path=bloom_cvx.whp`), with no folder: Whorld finds it beside the playlist or in `Documents/Whorld/Patches`, so the playlist works on any Mac.

The build copies these folders into `Whorld.app/Contents/Resources/Samples` (the Copy Help and Samples phase in `generate_project.py`). Only `Patches` and `Playlists` are copied; this README isn't.
