// Copyleft 2005 Chris Korda (original RandList.cpp)
// Port to macOS: Copyright 2026 Jeff Matson. Part of Whorld for macOS.
// Written with Claude (Anthropic).
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. The original Whorld source is licensed GPL version 2 or
// any later version. See the LICENSE file at the repository root.

#include "whorld/RandList.h"
#include "whorld/Random.h"
#include "whorld/Round.h"

#include <algorithm>
#include <cassert>

namespace whorld {

// ported from RandList.cpp CRandList::CRandList
RandList::RandList()
{
	m_nAvail = 0;
}

RandList::RandList(int nSize)
{
	Init(nSize);
}

// ported from RandList.cpp CRandList::Init
void RandList::Init(int nSize)
{
	m_List.resize(nSize);
	for (int i = 0; i < nSize; i++)
		m_List[i] = i;
	m_nAvail = 0;
}

// ported from RandList.cpp CRandList::Rand
int RandList::Rand(int nVals)
{
	if (nVals <= 0)
		return -1;
	int	i = Trunc(whorld::rand() / double(kRandMax) * nVals);
	return std::min(i, nVals - 1);
}

// ported from RandList.cpp CRandList::GetNext
int RandList::GetNext()
{
	if (!m_nAvail)
		m_nAvail = GetSize();
	assert(m_nAvail > 0);
	int	idx = Rand(m_nAvail);
	m_nAvail--;
	int	tmp = m_List[idx];
	m_List[idx] = m_List[m_nAvail];
	m_List[m_nAvail] = tmp;
	return tmp;
}

} // namespace whorld
