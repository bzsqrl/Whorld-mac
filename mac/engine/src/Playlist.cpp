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

#include <filesystem>
#include <iomanip>
#include <locale>
#include <sstream>

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
#define RK_PATCH_REL_PATH	"RelPath"	// Mac addition
#define RK_LAYOUT_SECTION	"Layout"	// Mac addition
#define RK_LAYOUT_DATA		"Data"
#define RK_MAC_SECTION		"MacPlaylist"	// Mac addition
#define RK_MAC_PATCH_MODE	"PatchMode"
#define RK_MAC_ADVANCE_LENGTH	"AdvanceLength"
#define RK_MAC_ADVANCE_UNIT	"AdvanceUnit"

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
	// Mac addition: a damaged count (Windows' CArray::SetSize would run out
	// of memory) is an error, not billions of empty entries
	if (nPatches > kMaxPatches) {
		if (pError)
			*pError = "Invalid patch count.";
		return false;
	}
	m_arrPatch.assign(nPatches > 0 ? nPatches : 0, std::string());
	m_arrRelPath.assign(m_arrPatch.size(), std::string());
	for (int iPatch = 0; iPatch < nPatches; iPatch++) {	// for each patch
		fIn.GetUnicodeString(RK_PATCH_SECTION "\\" + std::to_string(iPatch), RK_PATCH_PATH, m_arrPatch[iPatch]);
		fIn.GetUnicodeString(RK_PATCH_SECTION "\\" + std::to_string(iPatch), RK_PATCH_REL_PATH, m_arrRelPath[iPatch]);	// Mac addition
	}
	m_arrMapping.Read(fIn);	// CMidiManager::ReadMappings
	m_sLayout = fIn.GetString(RK_LAYOUT_SECTION, RK_LAYOUT_DATA, "");	// Mac addition
	m_nPatchMode = fIn.GetInt(RK_MAC_SECTION, RK_MAC_PATCH_MODE, PM_FULL) == PM_GEOMETRY	// Mac addition
		? PM_GEOMETRY : PM_FULL;
	m_nAdvanceUnit = fIn.GetInt(RK_MAC_SECTION, RK_MAC_ADVANCE_UNIT, AutoAdvance::UNIT_Seconds);	// Mac addition
	if (!AutoAdvance::IsValidUnit(m_nAdvanceUnit))
		m_nAdvanceUnit = AutoAdvance::UNIT_Seconds;
	m_fAdvanceLength = AutoAdvance::kDefaultLength;
	std::string	sLength = fIn.GetString(RK_MAC_SECTION, RK_MAC_ADVANCE_LENGTH, "");
	if (!sLength.empty()) {	// a decimal, whatever the locale
		std::istringstream	in(sLength);
		in.imbue(std::locale::classic());
		double	f;
		if (in >> f)
			m_fAdvanceLength = f;
	}
	m_fAdvanceLength = AutoAdvance::ClampLength(m_fAdvanceLength, m_nAdvanceUnit);
	return true;
}

// ported from Playlist.cpp CPlaylist::OnSaveDocument and WritePatches
void Playlist::Write(IniFile& fOut, const std::string& sPlaylistDir) const
{
	fOut.Put(RK_FILE_ID, std::string(FILE_ID));
	fOut.Put(RK_FILE_VERSION, static_cast<int>(FILE_VERSION));
	int	nPatches = static_cast<int>(m_arrPatch.size());
	fOut.WriteInt(RK_PATCH_SECTION, RK_PATCH_COUNT, nPatches);
	for (int iPatch = 0; iPatch < nPatches; iPatch++) {	// for each patch
		fOut.WriteUnicodeString(RK_PATCH_SECTION "\\" + std::to_string(iPatch), RK_PATCH_PATH, m_arrPatch[iPatch]);
		std::string	sRel = RelativePath(m_arrPatch[iPatch], sPlaylistDir);	// Mac addition
		if (!sRel.empty())
			fOut.WriteUnicodeString(RK_PATCH_SECTION "\\" + std::to_string(iPatch), RK_PATCH_REL_PATH, sRel);
	}
	m_arrMapping.Write(fOut);	// CMidiManager::WriteMappings
	if (m_nPatchMode == PM_GEOMETRY)	// Mac addition, only when not the default
		fOut.WriteInt(RK_MAC_SECTION, RK_MAC_PATCH_MODE, m_nPatchMode);
	if (m_fAdvanceLength != AutoAdvance::kDefaultLength || m_nAdvanceUnit != AutoAdvance::UNIT_Seconds) {	// Mac addition
		std::ostringstream	out;
		out.imbue(std::locale::classic());
		out << std::setprecision(15) << m_fAdvanceLength;
		fOut.WriteString(RK_MAC_SECTION, RK_MAC_ADVANCE_LENGTH, out.str());
		fOut.WriteInt(RK_MAC_SECTION, RK_MAC_ADVANCE_UNIT, m_nAdvanceUnit);
	}
	// Mac addition, last and only when there is one, so other playlists are
	// byte for byte the Windows format; one line (line breaks would end it)
	if (!m_sLayout.empty() && m_sLayout.find_first_of("\r\n") == std::string::npos)
		fOut.WriteString(RK_LAYOUT_SECTION, RK_LAYOUT_DATA, m_sLayout);
}

// Mac addition: a Mac (absolute, '/') patch path relative to the playlist's
// folder, with '/' separators; empty for a Windows path or no folder
std::string Playlist::RelativePath(const std::string& sPatch, const std::string& sPlaylistDir)
{
	if (sPlaylistDir.empty() || sPatch.empty() || sPatch[0] != '/' || sPlaylistDir[0] != '/')
		return std::string();
	namespace fs = std::filesystem;
	fs::path	rel = fs::path(sPatch).lexically_normal().lexically_relative(fs::path(sPlaylistDir).lexically_normal());
	return rel.empty() ? std::string() : rel.generic_string();
}

bool Playlist::Read(const std::string& sPath, std::string* pError, bool* pbNewer)
{
	IniFile	fIn;
	if (!fIn.Read(sPath, pError))
		return false;
	if (!Read(fIn, pError, pbNewer))
		return false;
	// Mac addition: a patch that isn't at its Path, but is at its RelPath
	// from this playlist's folder, plays from there (the playlist and its
	// patches were moved together)
	namespace fs = std::filesystem;
	fs::path	dir = fs::path(sPath).parent_path();
	std::error_code	ec;
	for (size_t i = 0; i < m_arrPatch.size() && i < m_arrRelPath.size(); i++) {
		if (m_arrRelPath[i].empty() || (!m_arrPatch[i].empty() && fs::exists(m_arrPatch[i], ec)))
			continue;
		fs::path	cand = (dir / fs::path(m_arrRelPath[i])).lexically_normal();
		if (fs::is_regular_file(cand, ec))
			m_arrPatch[i] = cand.string();
	}
	return true;
}

bool Playlist::Write(const std::string& sPath, std::string* pError) const
{
	IniFile	fOut;
	namespace fs = std::filesystem;
	std::error_code	ec;
	fs::path	dir = fs::absolute(fs::path(sPath), ec).parent_path();	// for RelPath (Mac addition)
	Write(fOut, ec ? std::string() : dir.string());
	return fOut.Write(sPath, pError);
}

} // namespace whorld
