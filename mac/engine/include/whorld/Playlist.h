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

namespace whorld {

class Playlist {
public:
// Constants
	static const char* const m_pszPlaylistExt;	// "whl"
	enum {
		FILE_VERSION = 1,
	};

// Public data
	std::vector<std::string>	m_arrPatch;	// patch paths, as stored (Windows paths from Windows)
	MappingArray	m_arrMapping;			// MIDI mappings
	int		m_nFileVersion = FILE_VERSION;	// file version number obtained from document
	// Mac addition: the panel layout saved with the playlist, as the app's
	// one-line JSON (opaque here), or empty. A [Layout] section, which
	// Windows Whorld ignores (and drops if it saves the playlist).
	std::string	m_sLayout;

// Operations
	bool	Read(const std::string& sPath, std::string* pError = nullptr, bool* pbNewer = nullptr);
	bool	Write(const std::string& sPath, std::string* pError = nullptr) const;
	bool	Read(const IniFile& fIn, std::string* pError = nullptr, bool* pbNewer = nullptr);
	void	Write(IniFile& fOut) const;
};

} // namespace whorld
