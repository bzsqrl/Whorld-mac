// Copyleft 2005 Chris Korda (original Patch.cpp)
// Port to macOS: Copyright 2026 Jeff Matson. Part of Whorld for macOS.
// Written with Claude (Anthropic).
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. The original Whorld source is licensed GPL version 2 or
// any later version. See the LICENSE file at the repository root.

#include "whorld/Patch.h"
#include "whorld/FormatIO.h"
#include "MsvcFormat.h"

#include <cassert>
#include <cstdint>
#include <cstdio>
#include <fstream>
#include <sstream>

namespace whorld {

namespace {

// ported from StringTpl.h ValToString: convert value via ostream
template <typename T>
std::string ValToString(const T& inVal)
{
	std::ostringstream oss;
	oss << inVal;	// convert value to string
	return oss.str();
}

// CString::TrimLeft() with no arguments: trims _istspace characters
void TrimLeft(std::string& s)
{
	size_t	i = s.find_first_not_of(" \t\n\v\f\r");
	s.erase(0, i == std::string::npos ? s.size() : i);
}

// CStdioFile::ReadString in text mode: strips the line terminator. Text
// mode turns CRLF into LF before ReadString sees it.
bool ReadLine(std::istream& in, std::string& sLine)
{
	if (!std::getline(in, sLine))
		return false;
	if (!sLine.empty() && sLine.back() == '\r')
		sLine.pop_back();
	return true;
}

const char* const kNewline = "\r\n";	// CStdioFile text mode writes CRLF

} // namespace

std::ostream& operator<<(std::ostream& os, const DPoint& pt)
{
	os << "(" << pt.x << "," << pt.y << ")";
	return os;
}

std::ostream& operator<<(std::ostream& os, const PointF& pt)
{
	os << "(" << pt.x << "," << pt.y << ")";
	return os;
}

std::ostream& operator<<(std::ostream& os, const SizeF& sz)
{
	os << "(" << sz.width << "," << sz.height << ")";
	return os;
}

std::ostream& operator<<(std::ostream& os, const ColorF& clr)
{
	os << "(" << clr.r << "," << clr.g << "," << clr.b << "," << clr.a << ")";
	return os;
}

const char* const Patch::FILE_ID = "WHORLD%d";	// placeholder for version number

// ported from Patch.cpp CPatch::SetDefaults
void Patch::SetDefaults()
{
	SetParamDefaults(m_aParam);
	m_master = m_masterDefault;
	m_main = m_mainDefault;
}

// ported from Patch.cpp CPatch::GetParamRC
void Patch::GetParamRC(int iParam, int iProp, VARIANT_PROP& prop) const
{
	// assign parameter row property to caller's variant
	assert(IsValidParamIdx(iParam));	// check parameter index range
	assert(IsValidParamProp(iProp));	// check parameter property index range
	const PARAM_ROW&	row = m_aParam.row[iParam];	// reference specified parameter row
	switch (iProp) {
	#define PARAMPROPDEF(name, type, prefix, variant) \
	case PARAM_PROP_##name: prop.variant = row.prefix##name; break;
	#include "whorld/WhorldDef.h"	// generate cases for each property type
	}
}

// ported from Patch.cpp CPatch::SetParamRC
void Patch::SetParamRC(int iParam, int iProp, const VARIANT_PROP& prop)
{
	// assign caller's variant to parameter row property
	assert(IsValidParamIdx(iParam));	// check parameter index range
	assert(IsValidParamProp(iProp));	// check parameter property index range
	PARAM_ROW&	row = m_aParam.row[iParam];	// reference specified parameter row
	switch (iProp) {
	#define PARAMPROPDEF(name, type, prefix, variant) \
	case PARAM_PROP_##name: row.prefix##name = prop.variant; break;
	#include "whorld/WhorldDef.h"	// generate cases for each property type
	}
}

// ported from Patch.cpp CPatch::GetMainProp
void Patch::GetMainProp(int iProp, VARIANT_PROP& prop) const
{
	assert(IsValidMainProp(iProp));
	switch (iProp) {
	#define MAINDEF(name, type, prefix, initval, variant) \
	case MAIN_##name: prop.variant = m_main.prefix##name; break;
	#include "whorld/WhorldDef.h"	// generate cases for each property type
	}
}

// ported from Patch.cpp CPatch::SetMainProp
void Patch::SetMainProp(int iProp, const VARIANT_PROP& prop)
{
	assert(IsValidMainProp(iProp));
	switch (iProp) {
	#define MAINDEF(name, type, prefix, initval, variant) \
	case MAIN_##name: m_main.prefix##name = prop.variant; break;
	#include "whorld/WhorldDef.h"	// generate cases for each property type
	}
}

// ported from Patch.cpp CPatch::ParamToString
std::string Patch::ParamToString(int iProp, const VARIANT_PROP& prop)
{
	assert(IsValidParamProp(iProp));	// check parameter property index range
	std::string	sOut;
	switch (iProp) {
	#define PARAMPROPDEF(name, type, prefix, variant) \
	case PARAM_PROP_##name: sOut = ValToString(prop.variant); break;
	#include "whorld/WhorldDef.h"	// generate cases for each property type
	}
	return sOut;
}

// ported from Patch.cpp CPatch::MasterToString
std::string Patch::MasterToString(int iProp, const VARIANT_PROP& prop)
{
	(void)iProp;
	return ValToString(prop.dblVal);
}

// ported from Patch.cpp CPatch::MainToString
std::string Patch::MainToString(int iProp, const VARIANT_PROP& prop)
{
	assert(IsValidMainProp(iProp));	// check parameter property index range
	std::string	sOut;
	switch (iProp) {
	#define MAINDEF(name, type, prefix, initval, variant) \
	case MAIN_##name: sOut = ValToString(prop.variant); break;
	#include "whorld/WhorldDef.h"	// generate cases for each property type
	}
	return sOut;
}

// ported from Patch.cpp CPatch::ParseLine
bool Patch::ParseLine(std::string sLine)
{
	TrimLeft(sLine);
	std::string	sName = sLine.substr(0, sLine.find_first_of(" \t"));	// SpanExcluding
	std::string	sArg = sLine.substr(sName.size());
	int	iParam = FindParamByTag(sName.c_str());
	if (iParam >= 0) {	// if parameter found
		PARAM_ROW&	row = m_aParam.row[iParam];
		std::sscanf(sArg.c_str(), "%lf %d %lf %lf %lf %lf",
			&row.fVal, &row.iWave, &row.fAmp, &row.fFreq, &row.fPW, &row.fGlobal);
		return true;
	}
	int	iMaster = FindMasterByTag(sName.c_str());
	if (iMaster >= 0) {	// if master property found
		std::sscanf(sArg.c_str(), "%lf", &m_master.a[iMaster]);
		return true;
	}
	int	iMain = FindMainByTag(sName.c_str());
	if (iMain >= 0) {	// if main property found
		const MAIN_INFO& info = GetMainInfo(iMain);
		FormatIO::StrToVal(info.nFIOType, sArg.c_str(),
			reinterpret_cast<uint8_t *>(&m_main) + info.nOffset);
		return true;
	}
	return false;	// unknown symbol; parse failed
}

// ported from Patch.cpp CPatch::Read
bool Patch::Read(std::istream& in, std::string* pError)
{
	std::string	sLine;
	int	nVersion;
	if (!ReadLine(in, sLine) || std::sscanf(sLine.c_str(), FILE_ID, &nVersion) != 1) {
		if (pError)
			*pError = "Unexpected file format.";	// IDS_DOC_BAD_FORMAT
		return false;
	}
	SetDefaults();	// in case some lines are missing
	while (ReadLine(in, sLine)) {
		ParseLine(sLine);
	}
	return true;
}

bool Patch::Read(const std::string& sPath, std::string* pError)
{
	std::ifstream	fIn(sPath, std::ios::binary);
	if (!fIn) {	// original throws CFileException here
		if (pError)
			*pError = "Can't open file: " + sPath;
		return false;
	}
	return Read(fIn, pError);
}

// ported from Patch.cpp CPatch::Write
bool Patch::Write(std::ostream& out) const
{
	std::string	sLine;
	sLine = detail::FormatMsvc(FILE_ID, FILE_VERSION);
	out << sLine << kNewline;
	for (int iParam = 0; iParam < PARAM_COUNT; iParam++) {	// for each parameter
		const PARAM_ROW& row = m_aParam.row[iParam];
		const PARAM_INFO& info = GetParamInfo(iParam);
		sLine = detail::FormatMsvc("%s\t%g\t%d\t%g\t%g\t%g\t%g", info.pszTag,
			row.fVal, row.iWave, row.fAmp, row.fFreq, row.fPW, row.fGlobal);
		out << sLine << kNewline;
	}
	for (int iMaster = 0; iMaster < MASTER_COUNT; iMaster++) {	// for each master property
		// Fade is a Mac addition: written only when on, so a patch without it
		// is byte for byte what Windows Whorld writes (which ignores the line)
		if (iMaster == MASTER_Fade && m_master.fFade == 0)
			continue;
		const MASTER_INFO& info = GetMasterInfo(iMaster);
		sLine = detail::FormatMsvc("%s\t%g", info.pszTag, m_master.a[iMaster]);
		out << sLine << kNewline;
	}
	for (int iMain = 0; iMain < MAIN_COUNT; iMain++) {	// for each main property
		const MAIN_INFO& info = GetMainInfo(iMain);
		FormatIO::ValToStr(info.nFIOType,
			reinterpret_cast<const uint8_t *>(&m_main) + info.nOffset, sLine);
		out << info.pszTag << '\t' << sLine << kNewline;
	}
	return static_cast<bool>(out);
}

bool Patch::Write(const std::string& sPath, std::string* pError) const
{
	std::ofstream	fOut(sPath, std::ios::binary | std::ios::trunc);
	if (!fOut) {	// original throws CFileException here
		if (pError)
			*pError = "Can't create file: " + sPath;
		return false;
	}
	if (!Write(fOut) || !fOut.flush()) {
		if (pError)
			*pError = "Error writing file: " + sPath;
		return false;
	}
	return true;
}

} // namespace whorld
