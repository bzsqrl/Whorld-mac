// Copyleft 2005 Chris Korda (original RandList.h)
// Port to macOS: Copyright 2026 Jeff Matson. Part of Whorld for macOS.
// Written with Claude (Anthropic).
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. The original Whorld source is licensed GPL version 2 or
// any later version. See the LICENSE file at the repository root.

#pragma once

// ported from RandList.h: random sequence without duplicates

#include <vector>

namespace whorld {

class RandList {
public:
	RandList();
	RandList(int nSize);
	static	int		Rand(int nVals);
	void	Init(int nSize);
	int		GetNext();
	int		GetSize() const;
	int		GetAvail() const;

protected:
	std::vector<int>	m_List;	// array of randomly generated elements
	int		m_nAvail;	// number of elements that haven't been used
};

inline int RandList::GetSize() const
{
	return static_cast<int>(m_List.size());	// cast to 32-bit
}

inline int RandList::GetAvail() const
{
	return m_nAvail;
}

} // namespace whorld
