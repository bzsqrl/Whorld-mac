// This file is part of Whorld for macOS, a port of Whorld by Chris Korda.
// Copyright 2026 Jeff Matson.
// Written with Claude (Anthropic).
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See the LICENSE file at the repository root.

#pragma once

// An IRenderer that records every call, for engine tests.

#include "whorld/IRenderer.h"

#include <string>
#include <vector>

struct RecordedFigure {
	std::vector<whorld::PointF>	pts;	// start point plus segment points
	int		nSegments;
	bool	bCurved;
	bool	bFilled;
};

struct RecordedCall {
	enum Type { ANTIALIAS, CLEAR, BEGIN_PATH, ADD_FIGURE, END_PATH, FILL_PATH, STROKE_PATH,
		FILL_RECT, BEGIN_MIRROR, END_MIRROR };
	Type	type;
	whorld::ColorF	clr{0, 0, 0, 0};
	float	fWidth = 0;
	bool	bFlag = false;
	whorld::RectF	rect{0, 0, 0, 0};
	RecordedFigure	fig{{}, 0, false, false};
};

class RecordingRenderer : public whorld::IRenderer {
public:
	std::vector<RecordedCall>	calls;
	bool	bMirrorOk = true;

	void	Reset() { calls.clear(); }
	int		Count(RecordedCall::Type t) const
	{
		int	n = 0;
		for (const auto& c : calls)
			n += c.type == t;
		return n;
	}
	const RecordedCall*	First(RecordedCall::Type t) const
	{
		for (const auto& c : calls)
			if (c.type == t)
				return &c;
		return nullptr;
	}

	void	SetAntialiasing(bool bEnable) override { Push(RecordedCall::ANTIALIAS).bFlag = bEnable; }
	void	Clear(const whorld::ColorF& clr) override { Push(RecordedCall::CLEAR).clr = clr; }
	void	BeginPath() override { Push(RecordedCall::BEGIN_PATH); }
	void	AddFigure(const whorld::PointF* pStart, int nSegments, bool bCurved, bool bFilled) override
	{
		auto&	c = Push(RecordedCall::ADD_FIGURE);
		int	nPts = 1 + (bCurved ? nSegments * 3 : nSegments);
		c.fig.pts.assign(pStart, pStart + nPts);
		c.fig.nSegments = nSegments;
		c.fig.bCurved = bCurved;
		c.fig.bFilled = bFilled;
	}
	void	EndPath() override { Push(RecordedCall::END_PATH); }
	void	FillPath(const whorld::ColorF& clr) override { Push(RecordedCall::FILL_PATH).clr = clr; }
	void	StrokePath(const whorld::ColorF& clr, float fWidth) override
	{
		auto&	c = Push(RecordedCall::STROKE_PATH);
		c.clr = clr;
		c.fWidth = fWidth;
	}
	void	FillRect(const whorld::RectF& rect, const whorld::ColorF& clr) override
	{
		auto&	c = Push(RecordedCall::FILL_RECT);
		c.rect = rect;
		c.clr = clr;
	}
	bool	BeginQuadMirror() override { Push(RecordedCall::BEGIN_MIRROR); return bMirrorOk; }
	bool	EndQuadMirror() override { Push(RecordedCall::END_MIRROR); return bMirrorOk; }

private:
	RecordedCall&	Push(RecordedCall::Type t)
	{
		calls.push_back(RecordedCall());
		calls.back().type = t;
		return calls.back();
	}
};
