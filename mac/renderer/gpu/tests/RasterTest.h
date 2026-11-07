// This file is part of Whorld for macOS, a port of Whorld by Chris Korda.
// Copyright 2026 Jeff Matson.
// Written with Claude (Anthropic).
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See the LICENSE file at the repository root.

#pragma once

// Test helpers for the tessellator: a brute-force supersampling rasterizer
// for its output, and reference geometry (even-odd point in polygon). Slow
// and simple on purpose, so it can serve as the reference.

#include "gpu/Tessellator.h"

#include <algorithm>
#include <cmath>
#include <vector>

namespace raster_test {

using whorld::gpu::Contour;
using whorld::gpu::Vec2;

// Coverage per pixel, 0..1, from k x k samples per pixel (sample centers).
struct Coverage {
	int		w = 0, h = 0, k = 4;
	std::vector<uint8_t>	samples;	// w * k by h * k, 1 where covered

	Coverage(int nW, int nH, int nK = 4) : w(nW), h(nH), k(nK), samples(size_t(nW) * nK * nH * nK, 0) {}

	int		SW() const { return w * k; }
	int		SH() const { return h * k; }
	uint8_t&	At(int sx, int sy) { return samples[size_t(sy) * SW() + sx]; }
	uint8_t	At(int sx, int sy) const { return samples[size_t(sy) * SW() + sx]; }
	// Sample centers, nudged off the lattice by a tiny irrational offset so
	// that no sample lies exactly on an edge of round-numbered test geometry
	// (this rasterizer has no tie rule; a sample on an edge shared by two
	// triangles would count for neither).
	Vec2	SamplePos(int sx, int sy) const
	{
		return Vec2{(sx + 0.5f) / k + 0.000137f, (sy + 0.5f) / k + 0.000291f};
	}

	// Marks the samples inside a convex polygon (either orientation): union.
	void	AddConvex(const Vec2* p, int n)
	{
		double	area = 0;
		for (int i = 0; i < n; i++)
			area += double(p[i].x) * p[(i + 1) % n].y - double(p[(i + 1) % n].x) * p[i].y;
		if (area == 0)
			return;
		double	s = area > 0 ? 1 : -1;
		float	x0 = p[0].x, x1 = p[0].x, y0 = p[0].y, y1 = p[0].y;
		for (int i = 1; i < n; i++) {
			x0 = std::min(x0, p[i].x); x1 = std::max(x1, p[i].x);
			y0 = std::min(y0, p[i].y); y1 = std::max(y1, p[i].y);
		}
		int	sx0 = std::max(0, int(std::floor(x0 * k))), sx1 = std::min(SW() - 1, int(std::ceil(x1 * k)));
		int	sy0 = std::max(0, int(std::floor(y0 * k))), sy1 = std::min(SH() - 1, int(std::ceil(y1 * k)));
		for (int sy = sy0; sy <= sy1; sy++) {
			for (int sx = sx0; sx <= sx1; sx++) {
				Vec2	q = SamplePos(sx, sy);
				bool	bIn = true;
				for (int i = 0; i < n && bIn; i++) {
					Vec2	a = p[i], b = p[(i + 1) % n];
					double	e = (double(b.x) - a.x) * (double(q.y) - a.y) - (double(b.y) - a.y) * (double(q.x) - a.x);
					bIn = e * s > 0;
				}
				if (bIn)
					At(sx, sy) = 1;
			}
		}
	}
	void	AddTriangles(const std::vector<Vec2>& tris)
	{
		for (size_t i = 0; i + 2 < tris.size(); i += 3)
			AddConvex(&tris[i], 3);
	}
	void	AddQuads(const std::vector<Vec2>& quads)
	{
		for (size_t i = 0; i + 3 < quads.size(); i += 4)
			AddConvex(&quads[i], 4);
	}
	double	Area() const	// covered area in pixels
	{
		size_t	n = 0;
		for (uint8_t v : samples)
			n += v;
		return double(n) / (k * k);
	}
	float	PixelCoverage(int x, int y) const
	{
		int	n = 0;
		for (int j = 0; j < k; j++)
			for (int i = 0; i < k; i++)
				n += At(x * k + i, y * k + j);
		return float(n) / (k * k);
	}
	// samples covered in one and not the other
	size_t	CountDiff(const Coverage& o) const
	{
		size_t	n = 0;
		for (size_t i = 0; i < samples.size(); i++)
			n += samples[i] != o.samples[i];
		return n;
	}
};

// Even-odd point in polygon over all contours (crossing number).
inline bool InsideEvenOdd(const Contour* pc, size_t nc, Vec2 q)
{
	bool	bIn = false;
	for (size_t c = 0; c < nc; c++) {
		const std::vector<Vec2>&	p = pc[c].pts;
		size_t	n = p.size();
		for (size_t i = 0, j = n - 1; i < n; j = i++) {
			if ((p[i].y > q.y) != (p[j].y > q.y)) {
				double	x = p[j].x + (double(q.y) - p[j].y) * (double(p[i].x) - p[j].x) / (double(p[i].y) - p[j].y);
				if (q.x < x)
					bIn = !bIn;
			}
		}
	}
	return bIn;
}

// A contour from points, all corners.
inline Contour MakeContour(const std::vector<Vec2>& pts)
{
	Contour	c;
	c.pts = pts;
	c.corner.assign(pts.size(), 1);
	return c;
}

// A star polygon: n points around (cx, cy), every step-th, radius r.
inline std::vector<Vec2> Star(float cx, float cy, float r, int n, int step, float rot = 0.1f)
{
	std::vector<Vec2>	p;
	for (int i = 0; i < n; i++) {
		double	a = 2 * M_PI * double(i * step % n) / n + rot;
		p.push_back(Vec2{float(cx + r * std::cos(a)), float(cy + r * std::sin(a))});
	}
	return p;
}

} // namespace raster_test
