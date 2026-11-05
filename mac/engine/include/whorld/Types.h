// Copyleft 2005 Chris Korda (original DPoint.h)
// Port to macOS: Copyright 2026 Jeff Matson. Part of Whorld for macOS.
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. The original Whorld source is licensed GPL version 2 or
// any later version. See the LICENSE file at the repository root.

#pragma once

// Engine-native geometry and color types. These replace the Win32 and
// Direct2D types used by the original (POINT, SIZE, POINTFLOAT,
// D2D1_POINT_2F, D2D1_SIZE_F, D2D1_COLOR_F). Field names match Direct2D so
// that ported code reads the same.

#include "whorld/Round.h"

#include <cstdint>

namespace whorld {

// Same value as M_PI, which strict C++17 on glibc doesn't define.
constexpr double kPi = 3.14159265358979323846;

struct PointF {	// replaces D2D1_POINT_2F and POINTFLOAT
	float	x;
	float	y;
};

struct SizeF {	// replaces D2D1_SIZE_F
	float	width;
	float	height;
};

struct ColorF {	// replaces D2D1_COLOR_F
	float	r;
	float	g;
	float	b;
	float	a;
};

struct IntPoint {	// replaces POINT
	int32_t	x;
	int32_t	y;
};

struct IntSize {	// replaces SIZE
	int32_t	cx;
	int32_t	cy;
};

// ported from DPoint.h
struct DPOINT {
	double	x;
	double	y;
};

// ported from DPoint.h
class DPoint : public DPOINT {
public:
	DPoint();
	DPoint(double x, double y);
	DPoint(const DPoint& p);
	DPoint(const DPOINT& p);
	DPoint(const IntPoint& p);
	DPoint(const IntSize& p);
	DPoint(const PointF& p);
	DPoint(const SizeF& p);
	DPoint& operator=(const DPoint& p);
	DPoint& operator=(const DPOINT& p);
	const DPoint operator+(const DPoint& p) const;
	const DPoint operator-(const DPoint& p) const;
	const DPoint operator*(const DPoint& p) const;
	const DPoint operator/(const DPoint& p) const;
	const DPoint operator+(double d) const;
	const DPoint operator-(double d) const;
	const DPoint operator*(double d) const;
	const DPoint operator/(double d) const;
	DPoint& operator+=(const DPoint& p);
	DPoint& operator-=(const DPoint& p);
	DPoint& operator*=(const DPoint& p);
	DPoint& operator/=(const DPoint& p);
	DPoint& operator+=(double d);
	DPoint& operator-=(double d);
	DPoint& operator*=(double d);
	DPoint& operator/=(double d);
	bool operator==(const DPoint& p) const;
	bool operator!=(const DPoint& p) const;
	double operator[](int i) const;
	double& operator[](int i);
	operator IntPoint() const;	// rounds, like the original operator POINT
	operator PointF() const;	// replaces operator POINTFLOAT and D2D1_POINT_2F
	static bool Equal(double a, double b);
	static constexpr double m_fEpsilon = 1e-10;
};

// The original default constructor leaves x and y uninitialized; keep that,
// since DPoint is used inside structs that are bulk-initialized.
inline DPoint::DPoint()
{
}

inline DPoint::DPoint(double x, double y)
{
	this->x = x;
	this->y = y;
}

inline DPoint::DPoint(const DPoint& p)
{
	x = p.x;
	y = p.y;
}

inline DPoint::DPoint(const DPOINT& p)
{
	x = p.x;
	y = p.y;
}

inline DPoint::DPoint(const IntPoint& p)
{
	x = p.x;
	y = p.y;
}

inline DPoint::DPoint(const IntSize& p)
{
	x = p.cx;
	y = p.cy;
}

inline DPoint::DPoint(const PointF& p)
{
	x = p.x;
	y = p.y;
}

inline DPoint::DPoint(const SizeF& p)
{
	x = p.width;
	y = p.height;
}

inline DPoint& DPoint::operator=(const DPoint& p)
{
	if (this == &p)
		return *this;	// self-assignment
	x = p.x;
	y = p.y;
	return *this;
}

inline DPoint& DPoint::operator=(const DPOINT& p)
{
	if (this == &p)
		return *this;	// self-assignment
	x = p.x;
	y = p.y;
	return *this;
}

inline const DPoint DPoint::operator+(const DPoint& p) const
{
	return DPoint(x + p.x, y + p.y);
}

inline const DPoint DPoint::operator-(const DPoint& p) const
{
	return DPoint(x - p.x, y - p.y);
}

inline const DPoint DPoint::operator*(const DPoint& p) const
{
	return DPoint(x * p.x, y * p.y);
}

inline const DPoint DPoint::operator/(const DPoint& p) const
{
	return DPoint(x / p.x, y / p.y);
}

inline const DPoint DPoint::operator+(double d) const
{
	return *this + DPoint(d, d);
}

inline const DPoint DPoint::operator-(double d) const
{
	return *this - DPoint(d, d);
}

inline const DPoint DPoint::operator*(double d) const
{
	return *this * DPoint(d, d);
}

inline const DPoint DPoint::operator/(double d) const
{
	return *this / DPoint(d, d);
}

inline DPoint& DPoint::operator+=(const DPoint& p)
{
	return *this = *this + p;
}

inline DPoint& DPoint::operator-=(const DPoint& p)
{
	return *this = *this - p;
}

inline DPoint& DPoint::operator*=(const DPoint& p)
{
	return *this = *this * p;
}

inline DPoint& DPoint::operator/=(const DPoint& p)
{
	return *this = *this / p;
}

inline DPoint& DPoint::operator+=(double d)
{
	return *this = *this + d;
}

inline DPoint& DPoint::operator-=(double d)
{
	return *this = *this - d;
}

inline DPoint& DPoint::operator*=(double d)
{
	return *this = *this * d;
}

inline DPoint& DPoint::operator/=(double d)
{
	return *this = *this / d;
}

inline bool DPoint::operator==(const DPoint& p) const
{
	return Equal(p.x, x) && Equal(p.y, y);
}

inline bool DPoint::operator!=(const DPoint& p) const
{
	return !Equal(p.x, x) || !Equal(p.y, y);
}

inline double DPoint::operator[](int i) const
{
	return i ? y : x;	// original indexes the struct as a double array
}

inline double& DPoint::operator[](int i)
{
	return i ? y : x;
}

inline DPoint::operator IntPoint() const
{
	IntPoint	p;
	p.x = Round(x);
	p.y = Round(y);
	return p;
}

inline DPoint::operator PointF() const
{
	PointF	pt;
	pt.x = static_cast<float>(x);
	pt.y = static_cast<float>(y);
	return pt;
}

} // namespace whorld
