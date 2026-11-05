// This file is part of Whorld for macOS, a port of Whorld by Chris Korda.
// Copyright 2026 Jeff Matson.
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See the LICENSE file at the repository root.

// Tests for Snapshot (.whs) and SnapshotV1 decoding.

#include "TestHarness.h"
#include "whorld/HLS.h"
#include "whorld/Snapshot.h"

#include <cmath>
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <string>
#include <vector>

using namespace whorld;
namespace fs = std::filesystem;

namespace {

std::vector<uint8_t> ReadBytes(const fs::path& path)
{
	std::ifstream	f(path, std::ios::binary);
	return std::vector<uint8_t>(std::istreambuf_iterator<char>(f), std::istreambuf_iterator<char>());
}

// little-endian writers for building synthetic files
void PutU32(std::vector<uint8_t>& v, uint32_t x) { for (int i = 0; i < 4; i++) v.push_back(uint8_t(x >> (8 * i))); }
void PutI32(std::vector<uint8_t>& v, int32_t x) { PutU32(v, uint32_t(x)); }
void SetF64(std::vector<uint8_t>& v, size_t off, double d)
{
	uint64_t	u;
	std::memcpy(&u, &d, 8);
	for (int i = 0; i < 8; i++) v[off + i] = uint8_t(u >> (8 * i));
}
void SetF32(std::vector<uint8_t>& v, size_t off, float f)
{
	uint32_t	u;
	std::memcpy(&u, &f, 4);
	for (int i = 0; i < 4; i++) v[off + i] = uint8_t(u >> (8 * i));
}
void SetI16(std::vector<uint8_t>& v, size_t off, int16_t x) { v[off] = uint8_t(x); v[off + 1] = uint8_t(uint16_t(x) >> 8); }
void SetI32(std::vector<uint8_t>& v, size_t off, int32_t x) { for (int i = 0; i < 4; i++) v[off + i] = uint8_t(uint32_t(x) >> (8 * i)); }

std::unique_ptr<Snapshot> MakeSnapshot(int nRings)
{
	auto	p = Snapshot::Alloc(nRings);
	auto&	ds = p->m_drawState;
	ds.szTarget = SizeF{1056, 1234};
	ds.clrBkgnd = ColorF{0.25f, 0.5f, 0.75f, 1};
	ds.fZoom = 1.5;
	ds.nRings = nRings;
	ds.bConvex = true;
	ds.bMirror = true;
	p->m_globRing.fStarRatio = 1;
	p->m_globRing.nPolySides = 2;
	for (int i = 0; i < nRings; i++) {
		auto&	r = p->m_aRing[i];
		r.fRadius = 10.0 + i;
		r.nSides = int16_t(3 + i);
		r.nDrawMode = 3;
		r.clrCur = ColorF{1, 0.5f, 0, 0.5f};
		r.ptOrigin = DPOINT{-2.5, 7.25};
		r.fOddShear = -0.125;
	}
	return p;
}

} // namespace

TEST(FourCC) {
	CHECK_EQ(Snapshot::m_nFileID, 0x32534857u);	// 'W' 'H' 'S' '2' little-endian
	CHECK_EQ(Snapshot::GetSize(100), 40u + 104u + 100u * 192u);
}

TEST(EncodeDecodeRoundTrip) {
	auto	src = MakeSnapshot(3);
	std::vector<uint8_t>	data = Snapshot::Encode(*src);
	CHECK_EQ(data.size(), size_t(12 + Snapshot::GetSize(3)));
	std::string	err;
	auto	dst = Snapshot::Read(data, &err);
	CHECK(dst != nullptr);
	if (!dst)
		return;
	CHECK_EQ(dst->m_drawState.szTarget.width, 1056.0f);
	CHECK_EQ(dst->m_drawState.clrBkgnd.b, 0.75f);
	CHECK_EQ(dst->m_drawState.fZoom, 1.5);
	CHECK_EQ(dst->m_drawState.nRings, 3);
	CHECK(dst->m_drawState.bConvex);
	CHECK(dst->m_drawState.bMirror);
	CHECK_EQ(dst->m_globRing.nPolySides, 2);
	CHECK_EQ(dst->m_aRing.size(), size_t(3));
	CHECK_EQ(dst->m_aRing[2].fRadius, 12.0);
	CHECK_EQ(dst->m_aRing[2].nSides, int16_t(5));
	CHECK_EQ(dst->m_aRing[1].clrCur.a, 0.5f);
	CHECK_EQ(dst->m_aRing[0].ptOrigin.y, 7.25);
	CHECK_EQ(dst->m_aRing[0].fOddShear, -0.125);
	CHECK(Snapshot::Encode(*dst) == data);
}

TEST(KnownByteOffsets) {
	// spot-check the MSVC x64 layout directly in the encoded bytes
	auto	src = MakeSnapshot(1);
	std::vector<uint8_t>	d = Snapshot::Encode(*src);
	const size_t	ds = 12, gr = ds + 40, rg = gr + 104;
	CHECK_EQ(int(d[6]), 40);
	CHECK_EQ(int(d[8]), 104);
	CHECK_EQ(int(d[10]), 192);
	CHECK_EQ(int(d[ds + 32]), 1);	// nRings
	CHECK_EQ(int(d[ds + 36]), 1);	// bConvex
	CHECK_EQ(int(d[ds + 38]), 1);	// bMirror
	CHECK_EQ(int(d[gr + 96]), 2);	// nPolySides
	CHECK_EQ(int(d[rg + 104]), 3);	// nSides
	CHECK_EQ(int(d[rg + 106]), 3);	// nDrawMode
	float	fA;
	std::memcpy(&fA, &d[rg + 112 + 12], 4);	// clrCur.a
	CHECK_EQ(fA, 0.5f);
	double	fOddShear;
	std::memcpy(&fOddShear, &d[rg + 184], 8);
	CHECK_EQ(fOddShear, -0.125);
}

TEST(ShorterLegacyRingSizeZeroFills) {
	// a file written when RING was smaller: trailing members read as zero
	auto	src = MakeSnapshot(2);
	std::vector<uint8_t>	full = Snapshot::Encode(*src);
	const uint16_t	nOldRingSize = 128;	// up to clrCur
	std::vector<uint8_t>	data(full.begin(), full.begin() + 12 + 40 + 104);
	data[10] = uint8_t(nOldRingSize);
	data[11] = 0;
	for (int i = 0; i < 2; i++) {
		auto	ring = full.begin() + 12 + 40 + 104 + i * 192;
		data.insert(data.end(), ring, ring + nOldRingSize);
	}
	auto	dst = Snapshot::Read(data);
	CHECK(dst != nullptr);
	if (!dst)
		return;
	CHECK_EQ(dst->m_aRing[1].fRadius, 11.0);
	CHECK_EQ(dst->m_aRing[1].clrCur.r, 1.0f);
	CHECK_EQ(dst->m_aRing[1].ptOrigin.x, 0.0);	// past the old size
	CHECK_EQ(dst->m_aRing[1].fOddShear, 0.0);
}

TEST(TruncatedFileFails) {
	auto	src = MakeSnapshot(4);
	std::vector<uint8_t>	data = Snapshot::Encode(*src);
	data.resize(data.size() - 1);
	std::string	err;
	CHECK(Snapshot::Read(data, &err) == nullptr);
	CHECK_EQ(err, std::string("Unexpected end of file."));
	CHECK(Snapshot::Read(std::vector<uint8_t>(5), &err) == nullptr);
}

TEST(UnknownFileIdFallsBackToV1AndFails) {
	std::vector<uint8_t>	data(64, 0xAB);
	std::string	err;
	CHECK(Snapshot::Read(data, &err) == nullptr);
	CHECK_EQ(err, std::string("Unexpected file format."));
}

TEST(WriteAndReadFile) {
	fs::path	path = fs::temp_directory_path() / "whorld_test_snapshot.whs";
	auto	src = MakeSnapshot(5);
	std::string	err;
	CHECK(Snapshot::Write(src.get(), path.string(), &err));
	auto	dst = Snapshot::Read(path.string(), &err);
	CHECK(dst != nullptr);
	if (dst)
		CHECK(Snapshot::Encode(*dst) == Snapshot::Encode(*src));
	src->m_drawState.nRings = 6;	// mismatch with ring array
	CHECK(!Snapshot::Write(src.get(), path.string(), &err));
	fs::remove(path);
	CHECK(Snapshot::Read((fs::temp_directory_path() / "no_such.whs").string(), &err) == nullptr);
}

// Build a V1 snapshot the way Whorld V1 wrote it through CArchive.
std::vector<uint8_t> MakeV1(int nVersion, bool bWithVideoString)
{
	std::vector<uint8_t>	v;
	PutI32(v, 0x4e534857);	// WHSN
	PutI32(v, nVersion);
	PutI32(v, 160);	// parms size
	v.resize(v.size() + 160, 0);
	PutI32(v, 152);	// ring size
	PutI32(v, 2);	// rings
	for (int i = 0; i < 2; i++) {
		std::vector<uint8_t>	r(152, 0);
		SetF64(r, 0, 0.01 * (i + 1));	// RotDelta
		SetF64(r, 8, 99);				// ShiftDelta.x (ignored by upstream quirk)
		SetF64(r, 24, 120);				// Hue
		SetF32(r, 32, 0.5f);			// Lightness
		SetF32(r, 36, 1);				// Saturation
		SetF64(r, 48, 20.0 + i);		// Steps (radius)
		SetF64(r, 56, 1); SetF64(r, 64, 1);	// Scale
		SetF64(r, 72, 3); SetF64(r, 80, 4);	// Shift
		SetF64(r, 88, 0.5);				// StarRatio
		SetI16(r, 96, 6);				// Sides
		SetI32(r, 100, 0x00FF8040);		// Color: R=0x40 G=0x80 B=0xFF
		SetI16(r, 112, int16_t(i == 0 ? 0 : 3));	// LineWidth
		SetI16(r, 114, 1);				// DrawMode
		SetF64(r, 120, 11); SetF64(r, 128, 12);	// Origin
		SetF32(r, 148, 0.25f);			// OddShear
		v.insert(v.end(), r.begin(), r.end());
	}
	if (nVersion > 3 && bWithVideoString) {
		v.push_back(3);	// CString length (BYTE prefix)
		v.insert(v.end(), {'a', 'b', 'c'});
		PutU32(v, 42);	// video frame
	}
	PutI32(v, 128);	// state size
	std::vector<uint8_t>	s(128, 0);
	SetI32(s, 28, 0x00102030);	// BkColor
	s[36] = 1;					// Mirror
	s[38] = 1;					// Convex
	SetF64(s, 56, 10); SetF64(s, 64, -20);	// MirrorOrg
	SetF64(s, 96, 2);			// Zoom
	v.insert(v.end(), s.begin(), s.end());
	if (nVersion > 4) {
		PutI32(v, 80);	// glob ring size
		std::vector<uint8_t>	g(80, 0);
		SetF64(g, 8, 1.5);		// StarRatio
		SetF64(g, 24, 1); SetF64(g, 32, 1);	// Scale
		SetI32(g, 72, 4);		// LineWidth
		SetI32(g, 76, -1);		// PolySides
		v.insert(v.end(), g.begin(), g.end());
	}
	return v;
}

TEST(V1Version5) {
	std::string	err;
	auto	p = Snapshot::Read(MakeV1(5, true), &err, IntSize{1024, 768});
	CHECK(p != nullptr);
	if (!p) {
		std::fprintf(stderr, "  %s\n", err.c_str());
		return;
	}
	const auto&	ds = p->m_drawState;
	CHECK_EQ(ds.nFlags, uint8_t(Snapshot::SF_V1));
	CHECK_EQ(ds.szTarget.width, 1024.0f);
	CHECK_EQ(ds.szTarget.height, 768.0f);
	CHECK_EQ(ds.nRings, 2);
	CHECK_EQ(ds.fZoom, 2.0);
	CHECK(ds.bConvex);
	CHECK(ds.bMirror);
	CHECK_EQ(ds.clrBkgnd.r, float(0x30) / 255.0f);
	CHECK_EQ(ds.clrBkgnd.b, float(0x10) / 255.0f);
	CHECK_EQ(ds.clrBkgnd.a, 1.0f);
	const auto&	r0 = p->m_aRing[0];
	CHECK_EQ(r0.fRotDelta, 0.01);
	CHECK_EQ(r0.ptShiftDelta.x, 3.0);	// upstream quirk: copied from Shift
	CHECK_EQ(r0.fRadius, 20.0);
	CHECK_EQ(r0.nSides, int16_t(6));
	CHECK_EQ(r0.clrCur.r, float(0x40) / 255.0f);
	CHECK_EQ(r0.clrCur.g, float(0x80) / 255.0f);
	CHECK_EQ(r0.clrCur.b, 1.0f);
	CHECK_EQ(r0.fLineWidth, 1.0);	// max(0, 1)
	CHECK_EQ(p->m_aRing[1].fLineWidth, 3.0);
	CHECK_EQ(r0.ptOrigin.x, 11.0);	// version > 1: per-ring origins kept
	CHECK_EQ(r0.fOddShear, 0.25);
	CHECK(!r0.bSkipFill);
	CHECK_EQ(p->m_globRing.fStarRatio, 1.5);
	CHECK_EQ(p->m_globRing.fLineWidth, 4.0);
	CHECK_EQ(p->m_globRing.nPolySides, -1);
}

TEST(V1Version1FixesOrigins) {
	auto	p = Snapshot::Read(MakeV1(1, false));
	CHECK(p != nullptr);
	if (!p)
		return;
	CHECK_EQ(p->m_drawState.szTarget.width, 800.0f);	// default legacy size
	// MirrorOrg (10, -20) times -Zoom (2) becomes every ring's origin
	CHECK_EQ(p->m_aRing[0].ptOrigin.x, -20.0);
	CHECK_EQ(p->m_aRing[1].ptOrigin.y, 40.0);
	// no global ring before version 5: defaults
	CHECK_EQ(p->m_globRing.fStarRatio, 1.0);
	CHECK_EQ(p->m_globRing.fEvenShear, 1.0);
}

TEST(V1RejectsNewerVersion) {
	std::string	err;
	CHECK(Snapshot::Read(MakeV1(6, true), &err) == nullptr);
	CHECK_EQ(err, std::string("Unexpected file format."));
}

TEST(SampleSnapshots) {
	// Snapshots taken in Windows Whorld 2.0.20 (mac/testdata/snapshots).
	// Each must decode to sane values and re-encode byte for byte: the
	// MSVC structs have no padding, so this checks every field offset.
	fs::path	dir = fs::path(WHORLD_TESTDATA_DIR) / "snapshots";
	if (!fs::exists(dir)) {
		std::printf("  (no sample snapshots in %s; skipped)\n", dir.string().c_str());
		return;
	}
	int	nFiles = 0, nRingsTotal = 0;
	for (const auto& entry : fs::directory_iterator(dir)) {
		if (entry.path().extension() != ".whs")
			continue;
		nFiles++;
		std::string	name = entry.path().filename().string();
		std::vector<uint8_t>	bytes = ReadBytes(entry.path());
		std::string	err;
		auto	p = Snapshot::Read(bytes, &err);
		if (!p) {
			std::fprintf(stderr, "  can't read %s: %s\n", name.c_str(), err.c_str());
			CHECK(p != nullptr);
			continue;
		}
		const auto&	ds = p->m_drawState;
		CHECK_EQ(ds.nFlags & Snapshot::SF_V1, 0);
		CHECK(ds.nRings > 0);
		CHECK(ds.szTarget.width > 0 && ds.szTarget.height > 0);
		CHECK(ds.fZoom > 0);
		nRingsTotal += ds.nRings;
		for (const auto& r : p->m_aRing) {
			CHECK(r.nSides >= 3 && r.nSides <= 60);
			CHECK(std::isfinite(r.fRadius));
			CHECK(r.clrCur.r >= 0 && r.clrCur.r <= 1);
			CHECK(r.clrCur.a >= 0 && r.clrCur.a <= 1);
			CHECK_EQ(r.nReserved, int16_t(0));
			// the ring's color is its HLS hue/lightness/saturation in RGB
			// (unless color is inverted or changed afterwards)
			double	rr, gg, bb;
			HLS::hls2rgb(r.fHue, r.fLightness, r.fSaturation, rr, gg, bb);
			bool	bMatch = std::fabs(rr - r.clrCur.r) < 1e-5 && std::fabs(gg - r.clrCur.g) < 1e-5
				&& std::fabs(bb - r.clrCur.b) < 1e-5;
			bool	bInverted = std::fabs(1 - rr - r.clrCur.r) < 1e-5 && std::fabs(1 - gg - r.clrCur.g) < 1e-5
				&& std::fabs(1 - bb - r.clrCur.b) < 1e-5;
			CHECK(bMatch || bInverted);
		}
		std::vector<uint8_t>	enc = Snapshot::Encode(*p);
		if (enc != bytes)
			std::fprintf(stderr, "  re-encoding %s isn't byte-identical\n", name.c_str());
		CHECK(enc == bytes);
	}
	std::printf("  %d sample snapshots, %d rings, all re-encoded byte for byte\n", nFiles, nRingsTotal);
	CHECK(nFiles > 0);
}

int main() { return RunAllTests(); }
