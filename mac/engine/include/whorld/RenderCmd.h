// Copyleft 2025 Chris Korda (original RenderThread.h)
// Port to macOS: Copyright 2026 Jeff Matson. Part of Whorld for macOS.
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. The original Whorld source is licensed GPL version 2 or
// any later version. See the LICENSE file at the repository root.

#pragma once

// ported from RenderThread.h CRenderThreadBase: the base render command
// enum, the variant payload and the command struct. The thread and
// device parts of CRenderThread are replaced in later phases.

#include "whorld/Types.h"

#include <cstdint>

namespace whorld {

class RenderThreadBase {
public:
	enum {	// base render commands
		RC_RESIZE,				// Param: none; Data: none
		RC_SET_FULLSCREEN,		// Param: bool; Data: none
		BASE_RENDER_COMMANDS	// start of derived class commands
	};
	union VARIANT_PROP {	// subset of VARIANT types that fit in 8 bytes
		int64_t		llVal;	// first so initializer list sets all bytes
		uint64_t	ullVal;
		bool	boolVal;
		char	cVal;
		uint8_t	bVal;
		int16_t	iVal;
		uint16_t	uiVal;
		int32_t	intVal;
		uint32_t	uintVal;
		float	fltVal;
		double	dblVal;
		void*	byref;
		IntPoint	ptVal;
		IntSize	szVal;
		PointF	fltPt;	// pair of float; non-standard
		float	floatVal;	// alias, useful in macros
		double	doubleVal;	// alias, useful in macros
	};
	static_assert(sizeof(VARIANT_PROP) == 8, "variant must fit in 8 bytes");
	class RenderCmd {
	public:
		RenderCmd() {}
		RenderCmd(uint32_t nCmd, uint32_t nParam = 0);
		RenderCmd(uint32_t nCmd, uint32_t nParam, int& iProp);
		RenderCmd(uint32_t nCmd, uint32_t nParam, uint32_t& uProp);
		RenderCmd(uint32_t nCmd, uint32_t nParam, double& fProp);
		RenderCmd(uint32_t nCmd, uint32_t nParam, bool& bProp);
		RenderCmd(uint32_t nCmd, uint32_t nParam, int64_t& iProp);
		uint32_t	m_nCmd;		// render command; see enum
		uint32_t	m_nParam;	// optional parameter
		VARIANT_PROP	m_prop;	// variant property
	};
};

inline RenderThreadBase::RenderCmd::RenderCmd(uint32_t nCmd, uint32_t nParam)
	: m_nCmd(nCmd), m_nParam(nParam)
{
	m_prop.llVal = 0;
}

inline RenderThreadBase::RenderCmd::RenderCmd(uint32_t nCmd, uint32_t nParam, int& iProp)
	: m_nCmd(nCmd), m_nParam(nParam)
{
	m_prop.intVal = iProp;
}

inline RenderThreadBase::RenderCmd::RenderCmd(uint32_t nCmd, uint32_t nParam, uint32_t& uProp)
	: m_nCmd(nCmd), m_nParam(nParam)
{
	m_prop.uintVal = uProp;
}

inline RenderThreadBase::RenderCmd::RenderCmd(uint32_t nCmd, uint32_t nParam, double& fProp)
	: m_nCmd(nCmd), m_nParam(nParam)
{
	m_prop.dblVal = fProp;
}

inline RenderThreadBase::RenderCmd::RenderCmd(uint32_t nCmd, uint32_t nParam, bool& bProp)
	: m_nCmd(nCmd), m_nParam(nParam)
{
	m_prop.boolVal = bProp;
}

inline RenderThreadBase::RenderCmd::RenderCmd(uint32_t nCmd, uint32_t nParam, int64_t& iProp)
	: m_nCmd(nCmd), m_nParam(nParam)
{
	m_prop.llVal = iProp;
}

} // namespace whorld
