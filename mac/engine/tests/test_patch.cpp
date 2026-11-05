// This file is part of Whorld for macOS, a port of Whorld by Chris Korda.
// Copyright 2026 Jeff Matson.
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See the LICENSE file at the repository root.

// Tests for Patch (.whp) read/write.

#include "TestHarness.h"
#include "whorld/Patch.h"

#include <cstdio>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <sstream>
#include <cstdlib>
#include <string>
#include <vector>

using namespace whorld;
namespace fs = std::filesystem;

namespace {

// What Windows Whorld 2.0.20 writes for a default patch, written out by
// hand from the format strings in Patch.cpp (CRLF line endings).
const char* const kDefaultPatchLines[] = {
	"WHORLD4",
	"RingGrowth\t1\t0\t0\t0\t0.5\t0",
	"RingSpacing\t5\t0\t0\t0\t0.5\t0",
	"LineWidth\t1\t0\t0\t0\t0.5\t0",
	"PolySides\t5\t0\t0\t0\t0.5\t0",
	"RotateSpeed\t0\t0\t0\t0\t0.5\t0",
	"AspectRatio\t0\t0\t0\t0\t0.5\t0",
	"SkewRadius\t0\t0\t0\t0\t0.5\t0",
	"SkewAngle\t0\t0\t0\t0\t0.5\t0",
	"StarFactor\t0\t0\t0\t0\t0.5\t0",
	"Pinwheel\t0\t0\t0\t0\t0.5\t0",
	"ColorSpeed\t0.5\t0\t0\t0\t0.5\t0",
	"Lightness\t0.5\t0\t0\t0\t0.5\t0",
	"Saturation\t1\t0\t0\t0\t0.5\t0",
	"Alpha\t1\t0\t0\t0\t0.5\t0",
	"BkHue\t0\t0\t0\t0\t0.5\t0",
	"BkLightness\t0\t0\t0\t0\t0.5\t0",
	"BkSaturation\t1\t0\t0\t0\t0.5\t0",
	"BkAlpha\t1\t0\t0\t0\t0.5\t0",
	"EvenCurve\t0\t0\t0\t0\t0.5\t0",
	"OddCurve\t0\t0\t0\t0\t0.5\t0",
	"EvenShear\t0\t0\t0\t0\t0.5\t0",
	"OddShear\t0\t0\t0\t0\t0.5\t0",
	"Speed\t1",
	"Zoom\t1",
	"Damping\t0.186261",
	"Trail\t0",
	"Rings\t1000",
	"Tempo\t100",
	"HueSpan\t30",
	"CanvasScale\t1.4",
	"Copies\t1",
	"Spread\t100",
	"Origin\t0.5 0.5",
	"DrawMode\t0",
	"OrgMotion\t0",
	"Hue\t0",
	"Mirror\t0",
	"Reverse\t0",
	"Convex\t0",
	"InvertColor\t0",
	"LoopHue\t0",
	"ZoomCenter\t0",
	"Antialiasing\t1",
};

std::string Join(const char* const* lines, size_t n, const char* eol)
{
	std::string	s;
	for (size_t i = 0; i < n; i++)
		s += std::string(lines[i]) + eol;
	return s;
}

std::string WriteToString(const Patch& patch)
{
	std::ostringstream	os;
	patch.Write(os);
	return os.str();
}

bool ReadFromString(Patch& patch, const std::string& text, std::string* pError = nullptr)
{
	std::istringstream	is(text);
	return patch.Read(is, pError);
}

std::string ReadFileBytes(const fs::path& path)
{
	std::ifstream	f(path, std::ios::binary);
	return std::string(std::istreambuf_iterator<char>(f), std::istreambuf_iterator<char>());
}

void CheckPatchesEqual(const Patch& a, const Patch& b)
{
	for (int i = 0; i < Patch::PARAM_COUNT; i++) {
		const auto&	ra = a.m_aParam.row[i];
		const auto&	rb = b.m_aParam.row[i];
		CHECK_EQ(ra.fVal, rb.fVal);
		CHECK_EQ(ra.iWave, rb.iWave);
		CHECK_EQ(ra.fAmp, rb.fAmp);
		CHECK_EQ(ra.fFreq, rb.fFreq);
		CHECK_EQ(ra.fPW, rb.fPW);
		CHECK_EQ(ra.fGlobal, rb.fGlobal);
	}
	for (int i = 0; i < Patch::MASTER_COUNT; i++)
		CHECK_EQ(a.m_master.a[i], b.m_master.a[i]);
	CHECK_EQ(a.m_main.dptOrigin.x, b.m_main.dptOrigin.x);
	CHECK_EQ(a.m_main.dptOrigin.y, b.m_main.dptOrigin.y);
	CHECK_EQ(a.m_main.nDrawMode, b.m_main.nDrawMode);
	CHECK_EQ(a.m_main.nOrgMotion, b.m_main.nOrgMotion);
	CHECK_EQ(a.m_main.fHue, b.m_main.fHue);
	CHECK_EQ(a.m_main.bMirror, b.m_main.bMirror);
	CHECK_EQ(a.m_main.bReverse, b.m_main.bReverse);
	CHECK_EQ(a.m_main.bConvex, b.m_main.bConvex);
	CHECK_EQ(a.m_main.bInvertColor, b.m_main.bInvertColor);
	CHECK_EQ(a.m_main.bLoopHue, b.m_main.bLoopHue);
	CHECK_EQ(a.m_main.bZoomCenter, b.m_main.bZoomCenter);
	CHECK_EQ(a.m_main.bAntialiasing, b.m_main.bAntialiasing);
}

Patch MakeCustomPatch()
{
	Patch	p;
	p.SetDefaults();
	auto&	row = p.GetParamRow(Patch::PARAM_StarFactor);
	row.fVal = -1.25;
	row.iWave = Patch::WAVEFORM_PULSE;
	row.fAmp = 0.75;
	row.fFreq = 0.0625;
	row.fPW = 0.3;
	row.fGlobal = -0.5;
	p.GetParamRow(Patch::PARAM_RotateSpeed).fVal = 0.0174533;
	p.SetMasterProp(Patch::MASTER_Rings, 250);
	p.SetMasterProp(Patch::MASTER_Tempo, 128.5);
	p.m_main.dptOrigin = DPoint(0.25, 0.875);
	p.m_main.nDrawMode = Patch::DM_FILL | Patch::DM_OUTLINE;
	p.m_main.nOrgMotion = Patch::OM_RANDOM;
	p.m_main.fHue = 271.5;
	p.m_main.bMirror = true;
	p.m_main.bConvex = true;
	p.m_main.bAntialiasing = false;
	return p;
}

} // namespace

TEST(WriteDefaultsMatchesWindowsFormat) {
	Patch	p;
	p.SetDefaults();
	std::string	expected = Join(kDefaultPatchLines, std::size(kDefaultPatchLines), "\r\n");
	CHECK_EQ(WriteToString(p), expected);
}

TEST(ReadDefaultsCrlfAndLf) {
	for (const char* eol : {"\r\n", "\n"}) {
		Patch	p;
		CHECK(ReadFromString(p, Join(kDefaultPatchLines, std::size(kDefaultPatchLines), eol)));
		Patch	d;
		d.SetDefaults();
		CheckPatchesEqual(p, d);
	}
}

TEST(RoundTripCustomPatch) {
	Patch	src = MakeCustomPatch();
	std::string	text = WriteToString(src);
	CHECK(text.find("StarFactor\t-1.25\t5\t0.75\t0.0625\t0.3\t-0.5\r\n") != std::string::npos);
	CHECK(text.find("Origin\t0.25 0.875\r\n") != std::string::npos);
	CHECK(text.find("DrawMode\t3\r\n") != std::string::npos);
	CHECK(text.find("Mirror\t1\r\n") != std::string::npos);
	Patch	dst;
	CHECK(ReadFromString(dst, text));
	CheckPatchesEqual(src, dst);
	CHECK_EQ(WriteToString(dst), text);
}

TEST(WriteRoundsToSixSignificantDigits) {
	// %g is lossy, as on Windows; a second round trip is then stable
	Patch	p;
	p.SetDefaults();
	p.GetParamRow(Patch::PARAM_SkewAngle).fVal = 1.0 / 3;
	std::string	text = WriteToString(p);
	CHECK(text.find("SkewAngle\t0.333333\t") != std::string::npos);
	Patch	q;
	CHECK(ReadFromString(q, text));
	CHECK_EQ(q.GetParamRow(Patch::PARAM_SkewAngle).fVal, 0.333333);
	CHECK_EQ(WriteToString(q), text);
}

TEST(BadHeaderFails) {
	Patch	p;
	std::string	err;
	CHECK(!ReadFromString(p, "NOT A PATCH\r\nRings\t5\r\n", &err));
	CHECK_EQ(err, std::string("Unexpected file format."));
	CHECK(!ReadFromString(p, ""));
	CHECK(ReadFromString(p, "WHORLD1\n"));	// any version number is accepted
}

TEST(MissingLinesAndFieldsKeepDefaults) {
	// older files may lack lines and trailing fields; unknown tags are ignored
	const char*	text =
		"WHORLD3\n"
		"  RingGrowth 2.5 1 0.5\n"		// leading spaces, space separators, 3 fields
		"NoSuchTag\t42\n"
		"Rings\t300\n"
		"Reverse\t1\n";
	Patch	p;
	CHECK(ReadFromString(p, text));
	const auto&	row = p.GetParamRow(Patch::PARAM_RingGrowth);
	CHECK_EQ(row.fVal, 2.5);
	CHECK_EQ(row.iWave, 1);
	CHECK_EQ(row.fAmp, 0.5);
	CHECK_EQ(row.fFreq, 0.0);	// default
	CHECK_EQ(row.fPW, 0.5);	// default
	CHECK_EQ(p.GetMasterProp(Patch::MASTER_Rings), 300.0);
	CHECK_EQ(p.GetMasterProp(Patch::MASTER_Tempo), 100.0);	// default
	CHECK_EQ(p.m_main.bReverse, true);
	CHECK_EQ(p.m_main.bAntialiasing, true);	// default
	CHECK_EQ(p.GetParamRow(Patch::PARAM_OddShear).fVal, 0.0);
}

TEST(ReadResetsPreviousContents) {
	Patch	p = MakeCustomPatch();
	CHECK(ReadFromString(p, "WHORLD4\n"));
	Patch	d;
	d.SetDefaults();
	CheckPatchesEqual(p, d);
}

TEST(VariantAccessors) {
	Patch	p = MakeCustomPatch();
	Patch::VARIANT_PROP	prop;
	p.GetParamRC(Patch::PARAM_StarFactor, Patch::PARAM_PROP_Wave, prop);
	CHECK_EQ(prop.intVal, int(Patch::WAVEFORM_PULSE));
	p.GetParamRC(Patch::PARAM_StarFactor, Patch::PARAM_PROP_Global, prop);
	CHECK_EQ(prop.dblVal, -0.5);
	prop.dblVal = 9;
	p.SetParamRC(Patch::PARAM_LineWidth, Patch::PARAM_PROP_Val, prop);
	CHECK_EQ(p.GetParamRow(Patch::PARAM_LineWidth).fVal, 9.0);
	// origin goes through a float pair, losing precision, as in the original
	p.m_main.dptOrigin = DPoint(0.1, 0.2);
	p.GetMainProp(Patch::MAIN_Origin, prop);
	CHECK_EQ(prop.fltPt.x, 0.1f);
	p.SetMainProp(Patch::MAIN_Origin, prop);
	CHECK_EQ(p.m_main.dptOrigin.x, double(0.1f));
	p.GetMainProp(Patch::MAIN_Mirror, prop);
	CHECK_EQ(prop.boolVal, true);
	CHECK_EQ(Patch::MainToString(Patch::MAIN_Mirror, prop), std::string("1"));
	prop.intVal = 7;
	p.SetMainProp(Patch::MAIN_DrawMode, prop);
	CHECK_EQ(p.m_main.nDrawMode, 7u);
	prop.dblVal = 0.125;
	CHECK_EQ(Patch::MasterToString(Patch::MASTER_Zoom, prop), std::string("0.125"));
	prop.fltPt = PointF{0.5f, 0.25f};
	CHECK_EQ(Patch::MainToString(Patch::MAIN_Origin, prop), std::string("(0.5,0.25)"));
}

TEST(FileReadWrite) {
	fs::path	dir = fs::temp_directory_path() / "whorld_test_patch";
	fs::create_directories(dir);
	fs::path	path = dir / "custom.whp";
	Patch	src = MakeCustomPatch();
	std::string	err;
	CHECK(src.Write(path.string(), &err));
	CHECK_EQ(ReadFileBytes(path), WriteToString(src));
	Patch	dst;
	CHECK(dst.Read(path.string(), &err));
	CheckPatchesEqual(src, dst);
	CHECK(!dst.Read((dir / "missing.whp").string(), &err));
	CHECK(!err.empty());
	fs::remove_all(dir);
}

// True if a line looks like Whorld wrote it: tag, then tab-separated
// fields, each field one or more space-separated numbers that parse fully.
// Hand-edited lines (empty fields, typos like "0.92.85") are not canonical.
bool IsCanonicalLine(const std::string& line)
{
	std::vector<std::string>	fields;
	size_t	pos = 0;
	for (;;) {
		size_t	tab = line.find('\t', pos);
		fields.push_back(line.substr(pos, tab == std::string::npos ? std::string::npos : tab - pos));
		if (tab == std::string::npos)
			break;
		pos = tab + 1;
	}
	if (fields.size() < 2)
		return false;
	for (size_t i = 1; i < fields.size(); i++) {
		std::istringstream	ss(fields[i]);
		std::string	tok;
		int	nTok = 0;
		while (ss >> tok) {
			char*	end = nullptr;
			std::strtod(tok.c_str(), &end);
			if (end != tok.c_str() + tok.size())
				return false;
			nTok++;
		}
		if (!nTok || fields[i].front() == ' ' || fields[i].back() == ' ')
			return false;
	}
	return true;
}

std::vector<std::string> SplitCrlf(const std::string& s)
{
	std::vector<std::string>	lines;
	size_t	pos = 0;
	while (pos < s.size()) {
		size_t	eol = s.find("\r\n", pos);
		if (eol == std::string::npos) {
			lines.push_back(s.substr(pos));
			break;
		}
		lines.push_back(s.substr(pos, eol - pos));
		pos = eol + 2;
	}
	return lines;
}

TEST(SamplePatchesRoundTrip) {
	// Patches exported from Windows Whorld (mac/testdata/patches). Every
	// file must parse. For version 4 files, every line Whorld wrote must be
	// reproduced byte for byte; hand-edited lines only need to parse.
	fs::path	dir = fs::path(WHORLD_TESTDATA_DIR) / "patches";
	if (!fs::exists(dir)) {
		std::printf("  (no sample patches in %s; skipped)\n", dir.string().c_str());
		return;
	}
	int	nFiles = 0, nV4 = 0, nLines = 0, nHandEdited = 0;
	for (const auto& entry : fs::recursive_directory_iterator(dir)) {
		if (entry.path().extension() != ".whp")
			continue;
		nFiles++;
		std::string	name = entry.path().filename().string();
		std::string	bytes = ReadFileBytes(entry.path());
		Patch	p;
		std::string	err;
		bool	bOk = p.Read(entry.path().string(), &err);
		if (!bOk)
			std::fprintf(stderr, "  can't read %s: %s\n", name.c_str(), err.c_str());
		CHECK(bOk);
		std::string	out = WriteToString(p);
		if (bytes.compare(0, 9, "WHORLD4\r\n") == 0) {
			nV4++;
			std::vector<std::string>	inLines = SplitCrlf(bytes);
			std::vector<std::string>	outLines = SplitCrlf(out);
			CHECK_EQ(inLines.size(), outLines.size());
			CHECK(bytes.size() >= 2 && bytes.compare(bytes.size() - 2, 2, "\r\n") == 0);
			for (size_t i = 0; i < inLines.size() && i < outLines.size(); i++) {
				nLines++;
				if (inLines[i] == outLines[i])
					continue;
				if (i > 0 && !IsCanonicalLine(inLines[i])) {
					nHandEdited++;
					continue;
				}
				std::fprintf(stderr, "  %s line %zu:\n    windows: %s\n    port:    %s\n",
					name.c_str(), i + 1, inLines[i].c_str(), outLines[i].c_str());
				CHECK(inLines[i] == outLines[i]);
			}
		}
		Patch	q;	// whatever the version, a rewrite is stable
		CHECK(ReadFromString(q, out));
		CHECK_EQ(WriteToString(q), out);
	}
	std::printf("  %d sample patches; %d version 4 files, %d lines compared, %d hand-edited lines skipped\n",
		nFiles, nV4, nLines, nHandEdited);
}

int main() { return RunAllTests(); }
