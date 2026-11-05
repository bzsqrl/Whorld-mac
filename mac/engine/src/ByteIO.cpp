// This file is part of Whorld for macOS, a port of Whorld by Chris Korda.
// Copyright 2026 Jeff Matson.
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See the LICENSE file at the repository root.

#include "ByteIO.h"

#include <fstream>
#include <iterator>

namespace whorld {
namespace bin {

bool ReadFile(const std::string& sPath, std::vector<uint8_t>& data)
{
	std::ifstream	f(sPath, std::ios::binary);
	if (!f)
		return false;
	data.assign(std::istreambuf_iterator<char>(f), std::istreambuf_iterator<char>());
	return !f.bad();
}

bool WriteFile(const std::string& sPath, const std::vector<uint8_t>& data)
{
	std::ofstream	f(sPath, std::ios::binary | std::ios::trunc);
	if (!f)
		return false;
	f.write(reinterpret_cast<const char*>(data.data()), static_cast<std::streamsize>(data.size()));
	return static_cast<bool>(f.flush());
}

} // namespace bin
} // namespace whorld
