# This file is part of Whorld for macOS, a port of Whorld by Chris Korda.
# Copyleft 2025 Chris Korda (original Whorld); port Copyright 2026 Jeff Matson.
# Written with Claude (Anthropic).
#
# This program is free software: you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by the Free
# Software Foundation, either version 3 of the License, or (at your option)
# any later version. See the LICENSE file at the repository root.

# Portable engine: plain C++17, no Windows, MFC or Apple headers.
add_library(whorld_engine STATIC
  src/AudioAnalyzer.cpp
  src/ByteIO.cpp
  src/Controls.cpp
  src/DPoint.cpp
  src/FormatIO.cpp
  src/HLS.cpp
  src/IniFile.cpp
  src/Mapping.cpp
  src/MidiManager.cpp
  src/Modulation.cpp
  src/Osc.cpp
  src/OscRemote.cpp
  src/Oscillator.cpp
  src/Patch.cpp
  src/Playlist.cpp
  src/WhorldEngine.cpp
  src/RandList.cpp
  src/SnapMovie.cpp
  src/Snapshot.cpp
  src/SnapshotV1.cpp
  src/Version.cpp
  src/WhorldBase.cpp
)
target_include_directories(whorld_engine PUBLIC include)
target_compile_options(whorld_engine PRIVATE -Wall -Wextra -Wpedantic)

add_subdirectory(tests)
