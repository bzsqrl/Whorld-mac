// Copyleft 2025 Chris Korda (original IniFile.h, RegTemplTypes.h)
// Port to macOS: Copyright 2026 Jeff Matson. Part of Whorld for macOS.
// Written with Claude (Anthropic).
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. The original Whorld source is licensed GPL version 2 or
// any later version. See the LICENSE file at the repository root.

#pragma once

// ported from IniFile.h CIniFile: an INI file held in memory, with sections
// and keys kept in file order. Used by playlists (.whl).
//
// Value encodings, as on Windows:
//   - integers and bools: decimal text (Get/Put for integral types);
//   - anything else (double, structs): raw little-endian bytes, two letters
//     per byte, 'A' + low nibble then 'A' + high nibble (WriteBinary);
//   - strings: as is; "Unicode" strings that aren't printable ASCII are
//     stored as binary UTF-16LE under the key name plus '#'.
// Files are text with CRLF line endings (CStdioFile text mode); reading
// accepts LF too. Strings are UTF-8 here; Windows wrote ANSI, which is the
// same for the ASCII the format otherwise uses.

#include <cstdint>
#include <cstring>
#include <iosfwd>
#include <map>
#include <string>
#include <type_traits>
#include <vector>

namespace whorld {

#define REG_SETTINGS "Settings"	// Globals.h: default section for Get/Put without one

class IniFile {
public:
// Operations
	bool	Read(const std::string& sPath, std::string* pError = nullptr);
	bool	Write(const std::string& sPath, std::string* pError = nullptr) const;
	void	Read(std::istream& in);
	void	Write(std::ostream& out) const;
	std::string	GetString(const std::string& sSection, const std::string& sEntry,
		const std::string& sDefault = std::string()) const;
	bool	GetStringEx(const std::string& sSection, const std::string& sEntry, std::string& sValue) const;
	void	WriteString(const std::string& sSection, const std::string& sEntry, const std::string& sValue);
	int		GetInt(const std::string& sSection, const std::string& sEntry, int nDefault = 0) const;
	void	WriteInt(const std::string& sSection, const std::string& sEntry, int nValue);
	bool	GetBinary(const std::string& sSection, const std::string& sEntry, void *pData, unsigned& nBytes) const;
	void	WriteBinary(const std::string& sSection, const std::string& sEntry, const void *pData, unsigned nBytes);
	void	GetUnicodeString(const std::string& sSection, const std::string& sEntry, std::string& sValue) const;
	void	WriteUnicodeString(const std::string& sSection, const std::string& sEntry, const std::string& sValue);

// Templates (ported from the CIniFile Get/Put templates and RegTemplTypes.h):
// integral types and bool are decimal; double and other types are binary.
	template<class T> void Get(const std::string& sSection, const std::string& sKey, T& value) const;
	template<class T> void Put(const std::string& sSection, const std::string& sKey, const T& value);
	void	Get(const std::string& sSection, const std::string& sKey, std::string& sValue) const
	{
		sValue = GetString(sSection, sKey, sValue);
	}
	void	Put(const std::string& sSection, const std::string& sKey, const std::string& sValue)
	{
		WriteString(sSection, sKey, sValue);
	}
	template<class T> void Get(const std::string& sKey, T& value) const { Get(REG_SETTINGS, sKey, value); }
	template<class T> void Put(const std::string& sKey, const T& value) { Put(REG_SETTINGS, sKey, value); }

protected:
	struct Key {
		std::string	sName;
		std::string	sVal;
	};
	struct Section {
		std::string	sName;
		std::vector<Key>	aKey;
		std::map<std::string, size_t>	mapKey;
	};
	std::vector<Section>	m_aSection;
	std::map<std::string, size_t>	m_mapSection;
};

template<class T>
void IniFile::Get(const std::string& sSection, const std::string& sKey, T& value) const
{
	if constexpr (std::is_same<T, bool>::value) {
		value = 0 != GetInt(sSection, sKey, value);
	} else if constexpr (std::is_integral<T>::value) {
		value = static_cast<T>(GetInt(sSection, sKey, static_cast<int>(value)));
	} else if constexpr (std::is_same<T, double>::value) {
		uint8_t	b[8];
		unsigned	nSize = sizeof(b);
		if (GetBinary(sSection, sKey, b, nSize) && nSize == sizeof(b)) {
			uint64_t	u = 0;
			for (int i = 7; i >= 0; i--)
				u = (u << 8) | b[i];
			static_assert(sizeof(double) == sizeof(uint64_t), "double must be 64 bits");
			std::memcpy(&value, &u, sizeof(value));
		}
	} else {
		static_assert(std::is_integral<T>::value || std::is_same<T, double>::value,
			"IniFile::Get supports integral types, bool, double and std::string");
	}
}

template<class T>
void IniFile::Put(const std::string& sSection, const std::string& sKey, const T& value)
{
	if constexpr (std::is_integral<T>::value) {
		WriteInt(sSection, sKey, static_cast<int>(value));
	} else if constexpr (std::is_same<T, double>::value) {
		uint64_t	u;
		std::memcpy(&u, &value, sizeof(u));
		uint8_t	b[8];
		for (int i = 0; i < 8; i++)
			b[i] = static_cast<uint8_t>(u >> (8 * i));	// little-endian, as on x64
		WriteBinary(sSection, sKey, b, sizeof(b));
	} else {
		static_assert(std::is_integral<T>::value || std::is_same<T, double>::value,
			"IniFile::Put supports integral types, bool, double and std::string");
	}
}

} // namespace whorld
