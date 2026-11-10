// Copyleft 2005 Chris Korda (original Patch.h)
// Port to macOS: Copyright 2026 Jeff Matson. Part of Whorld for macOS.
// Written with Claude (Anthropic).
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. The original Whorld source is licensed GPL version 2 or
// any later version. See the LICENSE file at the repository root.

#pragma once

// ported from Patch.h CPatch: patch container and .whp file I/O.
//
// Differences from the original:
//   - Read/Write return false (with an optional error message) instead of
//     throwing CFileException or showing a message box;
//   - Read/Write also accept streams, for testing;
//   - the CComVariant GetParam/SetParam overloads are UI-side and not
//     ported; the VARIANT_PROP versions (GetParamRC/SetParamRC) are.
//
// File format: text, one "tag<TAB>values" line per item, as written by
// MFC CStdioFile in text mode, so lines end in CRLF. Write emits CRLF so
// output is byte-identical to Windows; Read accepts CRLF or LF.

#include "whorld/WhorldBase.h"

#include <iosfwd>
#include <ostream>
#include <string>

namespace whorld {

// DPoint to string conversion; needed for Origin in main properties
std::ostream& operator<<(std::ostream& os, const DPoint& pt);
// replaces the D2D_POINT_2F, D2D1_SIZE_F and D2D1_COLOR_F operators
std::ostream& operator<<(std::ostream& os, const PointF& pt);
std::ostream& operator<<(std::ostream& os, const SizeF& sz);
std::ostream& operator<<(std::ostream& os, const ColorF& clr);

class Patch : public WhorldBase {
public:
// Construction
	Patch() {}	// use SetDefaults to initialize this object
	~Patch() {}

// Public data
	PARAM_TABLE		m_aParam;	// table of parameter rows
	MASTER_PROPS	m_master;	// master properties
	MAIN_PROPS		m_main;		// main properties
	// Mac addition: who made the patch (UTF-8, one line), "" if not known.
	// Saved as an "Author" line, which Windows Whorld ignores.
	std::string		m_sAuthor;

// Attributes
	void	SetDefaults();
	const PARAM_ROW&	GetParamRow(int iParam) const;
	PARAM_ROW&	GetParamRow(int iParam);
	void	GetParamRC(int iParam, int iProp, VARIANT_PROP& prop) const;
	void	SetParamRC(int iParam, int iProp, const VARIANT_PROP& prop);
	double	GetMasterProp(int iProp) const;
	void	SetMasterProp(int iProp, double fVal);
	void	GetMainProp(int iProp, VARIANT_PROP& prop) const;
	void	SetMainProp(int iProp, const VARIANT_PROP& prop);
	double	GetGlobalParam(int iParam) const;
	void	SetGlobalParam(int iParam, double fVal);

// Operations
	static std::string	ParamToString(int iProp, const VARIANT_PROP& prop);
	static std::string	MasterToString(int iProp, const VARIANT_PROP& prop);
	static std::string	MainToString(int iProp, const VARIANT_PROP& prop);
	bool	Read(const std::string& sPath, std::string* pError = nullptr);
	bool	Write(const std::string& sPath, std::string* pError = nullptr) const;
	bool	Read(std::istream& in, std::string* pError = nullptr);
	bool	Write(std::ostream& out) const;
	static std::string	AuthorForFile(const std::string& sAuthor);	// as written: one line, trimmed
	static const char* const kAuthorTag;	// "Author"

protected:
// Constants
	enum {
		FILE_VERSION = 4	// file format version number
	};
	static const char* const FILE_ID;		// file format signature

// Helpers
	bool	ParseLine(std::string sLine);
};

inline const Patch::PARAM_ROW& Patch::GetParamRow(int iParam) const
{
	return m_aParam.row[iParam];
}

inline Patch::PARAM_ROW& Patch::GetParamRow(int iParam)
{
	return m_aParam.row[iParam];
}

inline double Patch::GetMasterProp(int iProp) const
{
	return m_master.a[iProp];
}

inline void Patch::SetMasterProp(int iProp, double fVal)
{
	m_master.a[iProp] = fVal;
}

inline double Patch::GetGlobalParam(int iParam) const
{
	return m_aParam.row[iParam].fGlobal;
}

inline void Patch::SetGlobalParam(int iParam, double fVal)
{
	m_aParam.row[iParam].fGlobal = fVal;
}

} // namespace whorld
