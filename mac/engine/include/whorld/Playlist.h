// Copyleft 2025 Chris Korda (original Playlist.h)
// Port to macOS: Copyright 2026 Jeff Matson. Part of Whorld for macOS.
// Written with Claude (Anthropic).
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. The original Whorld source is licensed GPL version 2 or
// any later version. See the LICENSE file at the repository root.

#pragma once

// ported from Playlist.h/.cpp CPlaylist: the playlist file (.whl), an INI
// file holding the patch paths and the MIDI mappings. Playback and missing
// file handling (CMissingFilesDlg) are the app's job.

#include "whorld/Mapping.h"

#include <string>
#include <vector>

#include "whorld/AutoAdvance.h"

namespace whorld {

class Playlist {
public:
// Constants
	static const char* const m_pszPlaylistExt;	// "whl"
	enum {
		FILE_VERSION = 1,
	};
	// Mac addition: more patches than this is a damaged file (Read fails)
	static constexpr int	kMaxPatches = 1000000;

// Public data
	std::vector<std::string>	m_arrPatch;	// patch paths, as stored (Windows paths from Windows)
	// Mac addition (the user's choice, 2026-11-22): each patch's path relative
	// to the playlist's folder, as read (empty for none). A "RelPath" key in
	// the patch's section beside "Path", which Windows Whorld ignores; written
	// for Mac paths when the playlist is saved to a file, so a playlist and
	// its patches moved together (another Mac, user or folder) still play.
	// Read(sPath) uses it for a Path that doesn't exist.
	std::vector<std::string>	m_arrRelPath;
	MappingArray	m_arrMapping;			// MIDI mappings
	int		m_nFileVersion = FILE_VERSION;	// file version number obtained from document
	// Mac addition: the panel layout saved with the playlist, as the app's
	// one-line JSON (opaque here), or empty. A [Layout] section, which
	// Windows Whorld ignores (and drops if it saves the playlist).
	std::string	m_sLayout;
	// Mac addition, V1's patch mode (Playlist.cpp "MFPatchMode"): what
	// playing a patch changes. PM_FULL: everything (Windows V2's only
	// behavior); PM_GEOMETRY: only the shape and motion parameters
	// (Patch::MergeGeometry). A [MacPlaylist] section, written only for
	// Geometry, which Windows Whorld ignores (and drops if it saves).
	enum { PM_FULL, PM_GEOMETRY };
	int		m_nPatchMode = PM_FULL;
	// Mac addition, auto-advance (AutoAdvance.h): how long each patch plays
	// before the next, in AutoAdvance::UNIT_Seconds, _Beats or _Bars. In
	// [MacPlaylist] too, written only when not the default (30 seconds).
	// Whether it's running isn't saved: a playlist opens stopped.
	double	m_fAdvanceLength = AutoAdvance::kDefaultLength;
	int		m_nAdvanceUnit = AutoAdvance::UNIT_Seconds;

// Operations
	bool	Read(const std::string& sPath, std::string* pError = nullptr, bool* pbNewer = nullptr);
	bool	Write(const std::string& sPath, std::string* pError = nullptr) const;
	bool	Read(const IniFile& fIn, std::string* pError = nullptr, bool* pbNewer = nullptr);
	// sPlaylistDir: the folder the playlist is saved in, for RelPath (none if empty)
	void	Write(IniFile& fOut, const std::string& sPlaylistDir = std::string()) const;
	static std::string	RelativePath(const std::string& sPatch, const std::string& sPlaylistDir);
};

} // namespace whorld
