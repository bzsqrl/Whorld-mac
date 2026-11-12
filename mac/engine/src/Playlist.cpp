// Copyleft 2025 Chris Korda (original Playlist.cpp)
// Port to macOS: Copyright 2026 Jeff Matson. Part of Whorld for macOS.
// Written with Claude (Anthropic).
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. The original Whorld source is licensed GPL version 2 or
// any later version. See the LICENSE file at the repository root.

#include "whorld/Playlist.h"

namespace whorld {

const char* const Playlist::m_pszPlaylistExt = "whl";

// file versioning
#define FILE_ID				"WhorldPlay"
// file format keys
#define RK_FILE_ID			"FileID"
#define RK_FILE_VERSION		"FileVersion"
// patch list keys
#define RK_PATCH_COUNT		"Count"
#define RK_PATCH_SECTION	"Patch"
#define RK_PATCH_PATH		"Path"
#define RK_LAYOUT_SECTION	"Layout"	// Mac addition
#define RK_LAYOUT_DATA		"Data"

// ported from Playlist.cpp CPlaylist::OnOpenDocument, ValidateFileType, ReadPatches
bool Playlist::Read(const IniFile& fIn, std::string* pError, bool* pbNewer)
{
	std::string	sFileID;
	fIn.Get(RK_FILE_ID, sFileID);
	if (sFileID != FILE_ID) {	// if unexpected file ID
		if (pError)
			*pError = "Unexpected file format.";	// IDS_DOC_BAD_FORMAT
		return false;
	}
	m_nFileVersion = 0;
	fIn.Get(RK_FILE_VERSION, m_nFileVersion);
	if (pbNewer)	// IDS_DOC_NEWER_VERSION: a warning only
		*pbNewer = m_nFileVersion > FILE_VERSION;
	int	nPatches = fIn.GetInt(RK_PATCH_SECTION, RK_PATCH_COUNT, 0);
	m_arrPatch.assign(nPatches > 0 ? nPatches : 0, std::string());
	for (int iPatch = 0; iPatch < nPatches; iPatch++) {	// for each patch
		fIn.GetUnicodeString(RK_PATCH_SECTION "\\" + std::to_string(iPatch), RK_PATCH_PATH, m_arrPatch[iPatch]);
	}
	m_arrMapping.Read(fIn);	// CMidiManager::ReadMappings
	m_sLayout = fIn.GetString(RK_LAYOUT_SECTION, RK_LAYOUT_DATA, "");	// Mac addition
	return true;
}

// ported from Playlist.cpp CPlaylist::OnSaveDocument and WritePatches
void Playlist::Write(IniFile& fOut) const
{
	fOut.Put(RK_FILE_ID, std::string(FILE_ID));
	fOut.Put(RK_FILE_VERSION, static_cast<int>(FILE_VERSION));
	int	nPatches = static_cast<int>(m_arrPatch.size());
	fOut.WriteInt(RK_PATCH_SECTION, RK_PATCH_COUNT, nPatches);
	for (int iPatch = 0; iPatch < nPatches; iPatch++) {	// for each patch
		fOut.WriteUnicodeString(RK_PATCH_SECTION "\\" + std::to_string(iPatch), RK_PATCH_PATH, m_arrPatch[iPatch]);
	}
	m_arrMapping.Write(fOut);	// CMidiManager::WriteMappings
	// Mac addition, last and only when there is one, so other playlists are
	// byte for byte the Windows format; one line (line breaks would end it)
	if (!m_sLayout.empty() && m_sLayout.find_first_of("\r\n") == std::string::npos)
		fOut.WriteString(RK_LAYOUT_SECTION, RK_LAYOUT_DATA, m_sLayout);
}

bool Playlist::Read(const std::string& sPath, std::string* pError, bool* pbNewer)
{
	IniFile	fIn;
	if (!fIn.Read(sPath, pError))
		return false;
	return Read(fIn, pError, pbNewer);
}

bool Playlist::Write(const std::string& sPath, std::string* pError) const
{
	IniFile	fOut;
	Write(fOut);
	return fOut.Write(sPath, pError);
}

} // namespace whorld
