// Copyleft 2025 Chris Korda (original IniFile.cpp)
// Port to macOS: Copyright 2026 Jeff Matson. Part of Whorld for macOS.
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. The original Whorld source is licensed GPL version 2 or
// any later version. See the LICENSE file at the repository root.

#include "whorld/IniFile.h"

#include <cstdio>
#include <fstream>
#include <sstream>

namespace whorld {

// ported from IniFile.cpp CIniFile::Read (and CFastStdioFile::ReadString)
void IniFile::Read(std::istream& in)
{
	m_aSection.clear();
	m_mapSection.clear();
	std::string	sLine, sSection;
	while (std::getline(in, sLine)) {
		if (!sLine.empty() && sLine.back() == '\r')	// text mode turns CRLF into LF
			sLine.pop_back();
		if (!sLine.empty() && sLine[0] == '[') {	// if start of section
			size_t	iEnd = sLine.find(']', 1);
			if (iEnd != std::string::npos) {	// if section name terminator found
				sSection = sLine.substr(1, iEnd - 1);
			}
		} else {	// not section
			size_t	iSep = sLine.find('=');
			if (iSep != std::string::npos) {	// if key separator found
				WriteString(sSection, sLine.substr(0, iSep), sLine.substr(iSep + 1));
			}
		}
	}
}

// ported from IniFile.cpp CIniFile::Write; text mode writes CRLF
void IniFile::Write(std::ostream& out) const
{
	for (const Section& section : m_aSection) {	// for each section
		out << '[' << section.sName << "]\r\n";
		for (const Key& key : section.aKey) {	// for each of section's keys
			out << key.sName << '=' << key.sVal << "\r\n";
		}
	}
}

bool IniFile::Read(const std::string& sPath, std::string* pError)
{
	std::ifstream	fIn(sPath, std::ios::binary);
	if (!fIn) {	// original throws CFileException
		if (pError)
			*pError = "Can't open file: " + sPath;
		return false;
	}
	Read(fIn);
	return true;
}

bool IniFile::Write(const std::string& sPath, std::string* pError) const
{
	std::ofstream	fOut(sPath, std::ios::binary | std::ios::trunc);
	if (!fOut) {
		if (pError)
			*pError = "Can't create file: " + sPath;
		return false;
	}
	Write(fOut);
	if (!fOut.flush()) {
		if (pError)
			*pError = "Error writing file: " + sPath;
		return false;
	}
	return true;
}

// ported from IniFile.cpp CIniFile::GetString
std::string IniFile::GetString(const std::string& sSection, const std::string& sEntry,
	const std::string& sDefault) const
{
	std::string	sValue;
	return GetStringEx(sSection, sEntry, sValue) ? sValue : sDefault;
}

// ported from IniFile.cpp CIniFile::GetStringEx
bool IniFile::GetStringEx(const std::string& sSection, const std::string& sEntry, std::string& sValue) const
{
	auto	itSection = m_mapSection.find(sSection);
	if (itSection != m_mapSection.end()) {	// if section mapped
		const Section&	section = m_aSection[itSection->second];
		auto	itKey = section.mapKey.find(sEntry);
		if (itKey != section.mapKey.end()) {	// if key mapped
			sValue = section.aKey[itKey->second].sVal;
			return true;	// value found
		}
	}
	return false;	// value not found
}

// ported from IniFile.cpp CIniFile::WriteString
void IniFile::WriteString(const std::string& sSection, const std::string& sEntry, const std::string& sValue)
{
	size_t	iSection;
	auto	itSection = m_mapSection.find(sSection);
	if (itSection == m_mapSection.end()) {	// if section not mapped
		iSection = m_aSection.size();	// append new section
		m_aSection.push_back(Section());
		m_aSection[iSection].sName = sSection;	// set section name
		m_mapSection[sSection] = iSection;	// map section
	} else {
		iSection = itSection->second;
	}
	Section&	section = m_aSection[iSection];	// got section
	size_t	iKey;
	auto	itKey = section.mapKey.find(sEntry);
	if (itKey == section.mapKey.end()) {	// if key not mapped
		iKey = section.aKey.size();	// append new key
		section.aKey.push_back(Key());
	} else {
		iKey = itKey->second;
	}
	Key&	key = section.aKey[iKey];	// got key
	key.sName = sEntry;	// set key entry
	key.sVal = sValue;	// set key value
	section.mapKey[sEntry] = iKey;	// map key
}

// ported from IniFile.cpp CIniFile::GetInt
int IniFile::GetInt(const std::string& sSection, const std::string& sEntry, int nDefault) const
{
	int	nValue = nDefault;
	std::string	sValue(GetString(sSection, sEntry));
	std::sscanf(sValue.c_str(), "%d", &nValue);	// convert string to integer
	return nValue;
}

// ported from IniFile.cpp CIniFile::WriteInt
void IniFile::WriteInt(const std::string& sSection, const std::string& sEntry, int nValue)
{
	char	szVal[16];
	std::snprintf(szVal, sizeof(szVal), "%d", nValue);	// convert integer to string
	WriteString(sSection, sEntry, szVal);
}

// ported from IniFile.cpp CIniFile::GetBinary
bool IniFile::GetBinary(const std::string& sSection, const std::string& sEntry, void *pData, unsigned& nBytes) const
{
	std::string	str;
	if (!GetStringEx(sSection, sEntry, str)) {	// if value not found
		nBytes = 0;
		return false;	// failure
	}
	unsigned	nLen = static_cast<unsigned>(str.size());	// two characters per data byte
	nLen = std::min(nLen / 2, nBytes);	// conversion length in bytes
	nBytes = nLen;	// return number of bytes converted to caller
	uint8_t	*pOut = static_cast<uint8_t *>(pData);
	for (unsigned i = 0; i < nLen; i++) {	// for each output data byte
		pOut[i] = static_cast<uint8_t>(((str[i * 2 + 1] - 'A') << 4) + (str[i * 2] - 'A'));
	}
	return true;	// success
}

// ported from IniFile.cpp CIniFile::WriteBinary
void IniFile::WriteBinary(const std::string& sSection, const std::string& sEntry, const void *pData, unsigned nBytes)
{
	std::string	str(nBytes * 2, '\0');	// two characters per data byte
	const uint8_t	*pBuf = static_cast<const uint8_t *>(pData);
	for (unsigned i = 0; i < nBytes; i++) {	// for each input data byte
		str[i * 2] = static_cast<char>((pBuf[i] & 0x0F) + 'A');	// low nibble
		str[i * 2 + 1] = static_cast<char>(((pBuf[i] >> 4) & 0x0F) + 'A');	// high nibble
	}
	WriteString(sSection, sEntry, str);
}

namespace {

// UTF-16LE bytes to UTF-8, and back (Windows CString is UTF-16)
std::string Utf16ToUtf8(const std::vector<uint8_t>& b)
{
	std::string	s;
	for (size_t i = 0; i + 1 < b.size(); i += 2) {
		uint32_t	c = b[i] | (b[i + 1] << 8);
		if (c >= 0xD800 && c < 0xDC00 && i + 3 < b.size()) {	// surrogate pair
			uint32_t	c2 = b[i + 2] | (b[i + 3] << 8);
			if (c2 >= 0xDC00 && c2 < 0xE000) {
				c = 0x10000 + ((c - 0xD800) << 10) + (c2 - 0xDC00);
				i += 2;
			}
		}
		if (c < 0x80) {
			s += static_cast<char>(c);
		} else if (c < 0x800) {
			s += static_cast<char>(0xC0 | (c >> 6));
			s += static_cast<char>(0x80 | (c & 0x3F));
		} else if (c < 0x10000) {
			s += static_cast<char>(0xE0 | (c >> 12));
			s += static_cast<char>(0x80 | ((c >> 6) & 0x3F));
			s += static_cast<char>(0x80 | (c & 0x3F));
		} else {
			s += static_cast<char>(0xF0 | (c >> 18));
			s += static_cast<char>(0x80 | ((c >> 12) & 0x3F));
			s += static_cast<char>(0x80 | ((c >> 6) & 0x3F));
			s += static_cast<char>(0x80 | (c & 0x3F));
		}
	}
	return s;
}

std::vector<uint8_t> Utf8ToUtf16(const std::string& s)
{
	std::vector<uint8_t>	b;
	auto	Put16 = [&b](uint32_t u) {
		b.push_back(static_cast<uint8_t>(u));
		b.push_back(static_cast<uint8_t>(u >> 8));
	};
	for (size_t i = 0; i < s.size(); ) {
		uint8_t	c = static_cast<uint8_t>(s[i]);
		uint32_t	u;
		int	n;
		if (c < 0x80) { u = c; n = 1; }
		else if ((c >> 5) == 6) { u = c & 0x1F; n = 2; }
		else if ((c >> 4) == 14) { u = c & 0x0F; n = 3; }
		else { u = c & 0x07; n = 4; }
		for (int k = 1; k < n && i + k < s.size(); k++)
			u = (u << 6) | (static_cast<uint8_t>(s[i + k]) & 0x3F);
		i += n;
		if (u >= 0x10000) {
			u -= 0x10000;
			Put16(0xD800 + (u >> 10));
			Put16(0xDC00 + (u & 0x3FF));
		} else {
			Put16(u);
		}
	}
	return b;
}

// ported from IniFile.cpp IsPrintableASCII (used by WriteUnicodeString)
bool IsPrintableASCII(const std::string& s)
{
	for (char c : s) {
		if (c < 0x20 || c > 0x7e)
			return false;
	}
	return true;
}

} // namespace

// ported from IniFile.cpp CIniFile::GetUnicodeString (UNICODE build)
void IniFile::GetUnicodeString(const std::string& sSection, const std::string& sEntry, std::string& sValue) const
{
	if (!GetStringEx(sSection, sEntry, sValue)) {	// if regular string read fails
		std::string	str;
		if (GetStringEx(sSection, sEntry + '#', str)) {	// try Unicode string read
			std::vector<uint8_t>	b(str.size() / 2);
			unsigned	nBytes = static_cast<unsigned>(b.size());
			GetBinary(sSection, sEntry + '#', b.data(), nBytes);
			sValue = Utf16ToUtf8(b);
		}
	}
}

// ported from IniFile.cpp CIniFile::WriteUnicodeString (UNICODE build)
void IniFile::WriteUnicodeString(const std::string& sSection, const std::string& sEntry, const std::string& sValue)
{
	if (IsPrintableASCII(sValue)) {	// if string is printable ASCII
		WriteString(sSection, sEntry, sValue);	// do regular string write
	} else {	// string isn't printable ASCII
		std::vector<uint8_t>	b = Utf8ToUtf16(sValue);	// tag entry name and write as binary
		WriteBinary(sSection, sEntry + '#', b.data(), static_cast<unsigned>(b.size()));
	}
}

} // namespace whorld
