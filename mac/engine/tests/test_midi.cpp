// This file is part of Whorld for macOS, a port of Whorld by Chris Korda.
// Copyright 2026 Jeff Matson.
// Written with Claude (Anthropic).
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See the LICENSE file at the repository root.

// Tests for IniFile, Mapping, MidiManager and Playlist.

#include "TestHarness.h"
#include "whorld/Controls.h"
#include "whorld/IniFile.h"
#include "whorld/MidiManager.h"
#include "whorld/Playlist.h"

#include <cstdio>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <sstream>
#include <string>
#include <vector>

using namespace whorld;
namespace fs = std::filesystem;
using MB = MappingBase;

namespace {

std::string ReadBytes(const fs::path& path)
{
	std::ifstream	f(path, std::ios::binary);
	return std::string(std::istreambuf_iterator<char>(f), std::istreambuf_iterator<char>());
}

std::string WriteIni(const IniFile& ini)
{
	std::ostringstream	os;
	ini.Write(os);
	return os.str();
}

struct RecordingSink : MidiManager::Sink {
	std::vector<WhorldBase::RenderCmd>	cmds;
	std::vector<MidiManager::Post>	posts;
	void	PushCommand(const WhorldBase::RenderCmd& cmd) override { cmds.push_back(cmd); }
	void	PostToMain(const MidiManager::Post& post) override { posts.push_back(post); }
	void	Clear() { cmds.clear(); posts.clear(); }
};

Mapping MakeMapping(int iEvent, int iChan, int iCtrl, int iTarget, int iProp = 0,
	double fStart = 0, double fEnd = 100)
{
	Mapping	m;
	m.m_iEvent = iEvent;
	m.m_iChannel = iChan;
	m.m_iControl = iCtrl;
	m.m_iTarget = iTarget;
	m.m_iProp = iProp;
	m.m_fStart = fStart;
	m.m_fEnd = fEnd;
	return m;
}

} // namespace

TEST(IniBinaryEncoding) {
	IniFile	ini;
	double	d = 50;
	ini.Put("S", "Start", d);
	CHECK_EQ(ini.GetString("S", "Start"), std::string("AAAAAAAAAAAAJEAE"));	// as in Windows files
	double	back = 0;
	ini.Get("S", "Start", back);
	CHECK_EQ(back, 50.0);
	ini.Put("S", "N", -12);
	CHECK_EQ(ini.GetString("S", "N"), std::string("-12"));
	bool	b = true;
	ini.Put("S", "B", b);
	CHECK_EQ(ini.GetString("S", "B"), std::string("1"));
	int	n = 7;
	ini.Get("S", "Missing", n);
	CHECK_EQ(n, 7);	// missing keys keep the value
	double	d2 = 3;
	ini.Get("S", "Missing", d2);
	CHECK_EQ(d2, 3.0);
}

TEST(IniUnicodeStrings) {
	IniFile	ini;
	ini.WriteUnicodeString("P", "Path", "C:\\plain.whp");
	CHECK_EQ(ini.GetString("P", "Path"), std::string("C:\\plain.whp"));
	std::string	sNonAscii = "C:\\Musik\\Fl\xC3\xBCgel \xE2\x80\x94 \xF0\x9F\x8E\xB5.whp";	// ü, em dash, emoji
	ini.WriteUnicodeString("P", "Path2", sNonAscii);
	CHECK(ini.GetString("P", "Path2").empty());	// stored under "Path2#" instead
	std::string	sHex = ini.GetString("P", "Path2#");
	CHECK_EQ(sHex.substr(0, 4), std::string("DEAA"));	// 'C' = 0x43 as UTF-16LE: 43 00
	std::string	back;
	ini.GetUnicodeString("P", "Path2", back);
	CHECK_EQ(back, sNonAscii);
}

TEST(IniOrderAndCrlf) {
	std::istringstream	in("[B]\nx=1\n[A]\ny=2\r\nx=3\n[B]\nz=4\n");
	IniFile	ini;
	ini.Read(in);
	CHECK_EQ(WriteIni(ini), std::string("[B]\r\nx=1\r\nz=4\r\n[A]\r\ny=2\r\nx=3\r\n"));
	CHECK_EQ(ini.GetInt("A", "x"), 3);
}

TEST(SamplePlaylistsRoundTrip) {
	fs::path	dir = fs::path(WHORLD_TESTDATA_DIR) / "playlists";
	if (!fs::exists(dir)) {
		std::printf("  (no sample playlists; skipped)\n");
		return;
	}
	int	nFiles = 0;
	for (const auto& entry : fs::directory_iterator(dir)) {
		if (entry.path().extension() != ".whl")
			continue;
		nFiles++;
		std::string	bytes = ReadBytes(entry.path());
		Playlist	pl;
		std::string	err;
		bool	bNewer = true;
		CHECK(pl.Read(entry.path().string(), &err, &bNewer));
		CHECK(!bNewer);
		IniFile	out;
		pl.Write(out);
		std::string	written = WriteIni(out);
		if (written != bytes)
			std::fprintf(stderr, "  not byte-identical: %s\n", entry.path().filename().string().c_str());
		CHECK(written == bytes);
		std::printf("  %s: %zu patches, %zu mappings, byte-identical\n",
			entry.path().filename().string().c_str(), pl.m_arrPatch.size(), pl.m_arrMapping.size());
	}
	CHECK(nFiles > 0);
}

TEST(PlaylistLayoutSection) {
	// Mac addition: a [Layout] section, last, only when there's a layout
	Playlist	pl;
	pl.m_arrPatch = {"a.whp", "b.whp"};
	IniFile	plain;
	pl.Write(plain);
	CHECK(WriteIni(plain).find("Layout") == std::string::npos);
	pl.m_sLayout = R"({"version":1,"layout":{"left":{"panel":{"_0":"params"}}},"note":"a=b [c]"})";
	IniFile	with;
	pl.Write(with);
	std::string	text = WriteIni(with);
	CHECK(text.size() > WriteIni(plain).size());
	std::string	tail = "[Layout]\r\nData=" + pl.m_sLayout + "\r\n";
	CHECK(text.size() >= tail.size() && text.compare(text.size() - tail.size(), tail.size(), tail) == 0);	// last
	std::istringstream	in(text);
	IniFile	back;
	back.Read(in);
	Playlist	q;
	CHECK(q.Read(back));
	CHECK_EQ(q.m_sLayout, pl.m_sLayout);	// '=' and brackets in the value survive
	CHECK_EQ(q.m_arrPatch.size(), size_t(2));
	pl.m_sLayout = "two\nlines";	// can't be one INI line: not written
	IniFile	bad;
	pl.Write(bad);
	CHECK(WriteIni(bad).find("Layout") == std::string::npos);
}

TEST(SamplePlaylistValues) {
	fs::path	path = fs::path(WHORLD_TESTDATA_DIR) / "playlists" / "SMC-Mixer_Logitech_8BitDo.whl";
	if (!fs::exists(path))
		return;
	Playlist	pl;
	CHECK(pl.Read(path.string()));
	CHECK_EQ(pl.m_arrPatch.size(), size_t(82));
	CHECK_EQ(pl.m_arrPatch[3], std::string("C:\\Users\\user\\Documents\\Whorld\\bloom_cvx.whp"));
	CHECK_EQ(pl.m_arrMapping.size(), size_t(105));
	const Mapping&	m0 = pl.m_arrMapping[0];
	CHECK_EQ(m0.m_iEvent, int(MIDI_CVM_CONTROL));
	CHECK_EQ(m0.m_iTarget, int(MB::TARGET_StarFactor));
	CHECK_EQ(m0.m_iProp, int(WhorldBase::PARAM_PROP_Val));
	CHECK_EQ(m0.m_iChannel, 0);
	CHECK_EQ(m0.m_iControl, 16);
	CHECK_EQ(m0.m_fStart, 0.0);
	CHECK_EQ(m0.m_fEnd, 100.0);
	const Mapping&	m4 = pl.m_arrMapping[4];	// Start=AAAAAAAAAAAMAFAE, End=AAAAAAAAAAAILEAE
	CHECK_EQ(m4.m_iProp, int(WhorldBase::PARAM_PROP_Amp));
	CHECK_EQ(m4.m_fStart, 67.0);
	CHECK_EQ(m4.m_fEnd, 55.0);
}

TEST(MappingDefaultsAndNames) {
	Mapping	m;
	CHECK_EQ(m.m_iEvent, int(MIDI_CVM_CONTROL));
	CHECK_EQ(m.m_iControl, 1);
	CHECK_EQ(m.m_fEnd, 100.0);
	// 17 miscellaneous targets on Windows, plus the Mac's Hue, Rotate Hue, Invert Color,
	// Mark Downbeat, Modulation On and Modulation Depth
	CHECK_EQ(int(MB::TARGETS), WhorldBase::PARAM_COUNT + WhorldBase::MASTER_COUNT + 23);
	CHECK_EQ(MB::GetTargetName(MB::TARGET_ModDepth), std::string("Modulation Depth"));
	CHECK_EQ(MB::GetTargetType(MB::TARGET_ModOn), int(MB::TT_BOOL));
	CHECK(MB::IsMacOnlyTarget(MB::TARGET_ModDepth));
	CHECK_EQ(MB::GetTargetName(MB::TARGET_MarkDownbeat), std::string("Mark Downbeat"));
	CHECK_EQ(MB::GetTargetType(MB::TARGET_MarkDownbeat), int(MB::TT_ACTION));
	CHECK(!MB::IsMacOnlyTarget(MB::TARGET_Patch));
	CHECK(MB::IsMacOnlyTarget(MB::TARGET_Hue));
	CHECK(MB::IsMacOnlyTarget(MB::TARGET_MarkDownbeat));
	CHECK(!MB::IsMacOnlyTarget(MB::TARGETS));
	CHECK_EQ(std::string(MB::GetTargetTag(MB::TARGET_RotateHue)), std::string("RotateHue"));
	CHECK_EQ(MB::GetTargetName(MB::TARGET_InvertColor), std::string("Invert Color"));
	CHECK_EQ(MB::GetTargetType(MB::TARGET_Hue), int(MB::TT_RANGE));
	CHECK_EQ(MB::GetTargetType(MB::TARGET_RotateHue), int(MB::TT_ACTION));
	CHECK_EQ(MB::GetTargetType(MB::TARGET_InvertColor), int(MB::TT_BOOL));
	CHECK_EQ(std::string(MB::GetTargetTag(MB::TARGET_Patch)), std::string("Patch"));
	CHECK_EQ(MB::GetTargetName(MB::TARGET_OriginX), std::string("Origin X"));
	CHECK_EQ(MB::GetTargetName(MB::TARGET_CanvasScale), std::string("Canvas"));
	CHECK_EQ(MB::GetTargetType(MB::TARGET_Clear), int(MB::TT_ACTION));
	CHECK_EQ(MB::GetTargetType(MB::TARGET_Mirror), int(MB::TT_BOOL));
	CHECK_EQ(MB::GetTargetType(MB::TARGET_Zoom), int(MB::TT_RANGE));
	CHECK_EQ(MB::GetEventName(MIDI_CVM_CHAN_AFT), std::string("Channel Aftertouch"));
	CHECK_EQ(MB::FindTargetTag("NoSuch"), -1);
}

TEST(MappingInputMatch) {
	Mapping	cc = MakeMapping(MIDI_CVM_CONTROL, 2, 7, 0);
	CHECK_EQ(cc.IsInputMatch(MakeMidiMsg(CONTROL, 2, 7, 99)), 99);
	CHECK_EQ(cc.IsInputMatch(MakeMidiMsg(CONTROL, 3, 7, 99)), -1);	// channel
	CHECK_EQ(cc.IsInputMatch(MakeMidiMsg(CONTROL, 2, 8, 99)), -1);	// controller
	CHECK_EQ(cc.IsInputMatch(MakeMidiMsg(NOTE_ON, 2, 7, 99)), -1);	// event
	Mapping	wheel = MakeMapping(MIDI_CVM_WHEEL, 0, 0, 0);
	CHECK_EQ(wheel.IsInputMatch(MakeMidiMsg(WHEEL, 0, 0x7f, 0x40)), 0x7f | (0x40 << 7));
	Mapping	prog = MakeMapping(MIDI_CVM_PATCH, 0, 0, 0);
	CHECK_EQ(prog.IsInputMatch(MakeMidiMsg(PATCH, 0, 42, 0)), 42);	// data is P1
	Mapping	learned;
	learned.SetInputMidiMsg(MakeMidiMsg(NOTE_ON, 9, 36, 0));
	CHECK_EQ(learned.m_iEvent, int(MIDI_CVM_NOTE_ON));
	CHECK_EQ(learned.m_iChannel, 9);
	CHECK_EQ(learned.m_iControl, 36);
	CHECK_EQ(learned.GetInputMidiMsg(), MakeMidiMsg(NOTE_ON, 9, 36, 0));
}

TEST(Normalization) {
	CHECK_EQ(MidiManager::NormalizeMidiValue(MIDI_CVM_CONTROL, 0), 0.0);
	CHECK_EQ(MidiManager::NormalizeMidiValue(MIDI_CVM_CONTROL, 64), 0.5);	// exact center
	CHECK_EQ(MidiManager::NormalizeMidiValue(MIDI_CVM_CONTROL, 127), 1.0);
	CHECK_NEAR(MidiManager::NormalizeMidiValue(MIDI_CVM_CONTROL, 65), 64.0 / 126, 1e-15);
	CHECK_EQ(MidiManager::NormalizeMidiValue(MIDI_CVM_WHEEL, 8192), 0.5);
	CHECK_EQ(MidiManager::NormalizeMidiValue(MIDI_CVM_WHEEL, 16383), 1.0);
}

TEST(DispatchParameter) {
	RecordingSink	sink;
	MidiManager	mgr(sink);
	MappingArray	maps;
	maps.push_back(MakeMapping(MIDI_CVM_CONTROL, 0, 16, MB::TARGET_StarFactor, WhorldBase::PARAM_PROP_Val));
	maps.push_back(MakeMapping(MIDI_CVM_CONTROL, 0, 17, MB::TARGET_StarFactor, WhorldBase::PARAM_PROP_Wave));
	maps.push_back(MakeMapping(MIDI_CVM_CONTROL, 0, 18, MB::TARGET_LineWidth, WhorldBase::PARAM_PROP_Global));
	maps.push_back(MakeMapping(MIDI_CVM_CONTROL, 0, 19, MB::TARGET_RingGrowth, WhorldBase::PARAM_PROP_Global));
	maps.push_back(MakeMapping(MIDI_CVM_CONTROL, 0, 20, MB::TARGET_Alpha, WhorldBase::PARAM_PROP_Freq, 100, 0));
	mgr.m_midiMaps.SetArray(maps);
	// Star Factor value: -3..3, CC 64 is the exact center
	mgr.OnMidiEvent(MakeMidiMsg(CONTROL, 0, 16, 64));
	CHECK_EQ(sink.cmds.size(), size_t(1));
	CHECK_EQ(sink.cmds[0].m_nCmd, uint32_t(WhorldBase::RC_SET_PARAM_Val));
	CHECK_EQ(sink.cmds[0].m_nParam, uint32_t(WhorldBase::PARAM_StarFactor));
	CHECK_EQ(sink.cmds[0].m_prop.dblVal, 0.0);
	CHECK_EQ(sink.posts.size(), size_t(1));
	CHECK_EQ(sink.posts[0].type, MidiManager::Post::PARAM_CHANGE);
	CHECK_EQ(sink.posts[0].fVal, 0.0);
	// waveform: Trunc(norm * 8), clamped
	sink.Clear();
	mgr.OnMidiEvent(MakeMidiMsg(CONTROL, 0, 17, 127));
	CHECK_EQ(sink.cmds[0].m_nCmd, uint32_t(WhorldBase::RC_SET_PARAM_Wave));
	CHECK_EQ(sink.cmds[0].m_prop.intVal, int(WhorldBase::WAVEFORM_COUNT - 1));
	CHECK_EQ(sink.posts[0].iVal, int(WhorldBase::WAVEFORM_COUNT - 1));
	// global: (norm - 0.5) * max * 2, damped
	sink.Clear();
	mgr.OnMidiEvent(MakeMidiMsg(CONTROL, 0, 18, 127));
	CHECK_EQ(sink.cmds[0].m_nCmd, uint32_t(WhorldBase::RC_SET_DAMPED_GLOBAL));
	CHECK_EQ(sink.cmds[0].m_prop.dblVal, 50.0);
	// a parameter without a global does nothing
	sink.Clear();
	mgr.OnMidiEvent(MakeMidiMsg(CONTROL, 0, 19, 127));
	CHECK(sink.cmds.empty() && sink.posts.empty());
	// reversed range: start 100, end 0
	mgr.OnMidiEvent(MakeMidiMsg(CONTROL, 0, 20, 0));
	CHECK_EQ(sink.cmds[0].m_prop.dblVal, 1.0);
}

TEST(DispatchMasterAndMisc) {
	RecordingSink	sink;
	MidiManager	mgr(sink);
	MappingArray	maps;
	maps.push_back(MakeMapping(MIDI_CVM_CONTROL, 0, 1, MB::TARGET_Zoom));
	maps.push_back(MakeMapping(MIDI_CVM_CONTROL, 0, 2, MB::TARGET_Tempo));
	maps.push_back(MakeMapping(MIDI_CVM_NOTE_ON, 0, 36, MB::TARGET_Fill));
	maps.push_back(MakeMapping(MIDI_CVM_NOTE_ON, 0, 37, MB::TARGET_Pause));
	maps.push_back(MakeMapping(MIDI_CVM_PATCH, 0, 0, MB::TARGET_Patch));
	maps.push_back(MakeMapping(MIDI_CVM_CONTROL, 0, 3, MB::TARGET_OriginRandom));
	mgr.m_midiMaps.SetArray(maps);
	mgr.OnMidiEvent(MakeMidiMsg(CONTROL, 0, 1, 64));	// zoom at the slider center: 1
	CHECK_EQ(sink.cmds[0].m_nCmd, uint32_t(WhorldBase::RC_SET_ZOOM));
	CHECK_EQ(sink.cmds[0].m_nParam, 1u);	// damped
	CHECK_NEAR(sink.cmds[0].m_prop.dblVal, 1, 1e-12);
	CHECK_EQ(sink.posts[0].type, MidiManager::Post::MASTER_PROP_CHANGE);
	sink.Clear();
	mgr.OnMidiEvent(MakeMidiMsg(CONTROL, 0, 2, 127));	// tempo 0..250, linear
	CHECK_EQ(sink.cmds[0].m_nCmd, uint32_t(WhorldBase::RC_SET_MASTER));
	CHECK_NEAR(sink.cmds[0].m_prop.dblVal, Controls::MasterDenorm01(WhorldBase::MASTER_Tempo, 1), 1e-12);
	sink.Clear();
	mgr.OnMidiEvent(MakeMidiMsg(NOTE_ON, 0, 36, 0));	// velocity 0: fill off
	CHECK_EQ(sink.cmds[0].m_nCmd, uint32_t(WhorldBase::RC_SET_DRAW_MODE));
	CHECK_EQ(sink.cmds[0].m_nParam, uint32_t(WhorldBase::DM_FILL));
	CHECK_EQ(sink.cmds[0].m_prop.uintVal, 0u);
	sink.Clear();
	mgr.OnMidiEvent(MakeMidiMsg(NOTE_ON, 0, 37, 100));
	CHECK(sink.cmds.empty());
	CHECK_EQ(sink.posts[0].type, MidiManager::Post::PAUSE);
	sink.Clear();
	mgr.OnMidiEvent(MakeMidiMsg(PATCH, 0, 5, 0));	// program change 5: Round(5/128 * 127) = 5
	CHECK_EQ(sink.posts[0].type, MidiManager::Post::PLAY_PATCH);
	CHECK_EQ(sink.posts[0].iVal, 5);
	sink.Clear();
	mgr.OnMidiEvent(MakeMidiMsg(CONTROL, 0, 3, 127));
	CHECK_EQ(sink.cmds[0].m_nCmd, uint32_t(WhorldBase::RC_SET_MAIN));
	CHECK_EQ(sink.cmds[0].m_nParam, uint32_t(WhorldBase::MAIN_OrgMotion));
	CHECK_EQ(sink.cmds[0].m_prop.intVal, int(WhorldBase::OM_RANDOM));
}

TEST(ModulationTargets) {
	// Mac additions, carried out by the app (as OSC's /w/mod/...)
	RecordingSink	sink;
	MidiManager	mgr(sink);
	MappingArray	maps;
	maps.push_back(MakeMapping(MIDI_CVM_NOTE_ON, 0, 40, MB::TARGET_MarkDownbeat));
	maps.push_back(MakeMapping(MIDI_CVM_NOTE_ON, 0, 41, MB::TARGET_ModOn));
	maps.push_back(MakeMapping(MIDI_CVM_CONTROL, 0, 7, MB::TARGET_ModDepth));
	mgr.m_midiMaps.SetArray(maps);
	using Post = MidiManager::Post;
	mgr.OnMidiEvent(MakeMidiMsg(NOTE_ON, 0, 40, 100));
	CHECK(sink.cmds.empty());
	CHECK_EQ(sink.posts.size(), size_t(1));
	CHECK_EQ(sink.posts[0].type, Post::MODULATION);
	CHECK_EQ(sink.posts[0].iVal, 2);
	sink.Clear();
	mgr.OnMidiEvent(MakeMidiMsg(NOTE_ON, 0, 40, 0));	// the release: nothing
	CHECK(sink.cmds.empty());
	CHECK(sink.posts.empty());
	mgr.OnMidiEvent(MakeMidiMsg(NOTE_ON, 0, 41, 0));	// off
	CHECK_EQ(sink.posts[0].type, Post::MODULATION);
	CHECK_EQ(sink.posts[0].iVal, 0);
	CHECK_EQ(sink.posts[0].fVal, 0.0);
	sink.Clear();
	mgr.OnMidiEvent(MakeMidiMsg(NOTE_ON, 0, 41, 100));	// on
	CHECK_EQ(sink.posts[0].fVal, 1.0);
	sink.Clear();
	mgr.OnMidiEvent(MakeMidiMsg(CONTROL, 0, 7, 127));	// depth, 0 to 1
	CHECK_EQ(sink.posts[0].iVal, 1);
	CHECK_NEAR(sink.posts[0].fVal, 1.0, 1e-12);
	CHECK(sink.cmds.empty());
}

TEST(MacOnlyMappingsHaveTheirOwnSection) {
	// Windows reads an unknown target as Ring Growth, so mappings to Mac-only
	// targets go in [MacMapping], with their place in the list
	Playlist	pl;
	pl.m_arrPatch = {"a.whp"};
	pl.m_arrMapping.push_back(MakeMapping(MIDI_CVM_CONTROL, 0, 1, MB::TARGET_Zoom));
	pl.m_arrMapping.push_back(MakeMapping(MIDI_CVM_NOTE_ON, 0, 40, MB::TARGET_MarkDownbeat));
	pl.m_arrMapping.push_back(MakeMapping(MIDI_CVM_CONTROL, 0, 2, MB::TARGET_Tempo));
	pl.m_arrMapping.push_back(MakeMapping(MIDI_CVM_CONTROL, 0, 3, MB::TARGET_Hue));
	IniFile	out;
	pl.Write(out);
	std::string	text = WriteIni(out);
	CHECK(text.find("[Mapping]\r\nCount=2\r\n") != std::string::npos);	// what Windows reads
	CHECK(text.find("[MacMapping]\r\nCount=2\r\n") != std::string::npos);
	CHECK(text.find("[Mapping\\1]\r\nEvent=CONTROL\r\nTarget=Tempo") != std::string::npos);
	CHECK(text.find("Target=MarkDownbeat") != std::string::npos);
	CHECK(text.find("Position=1") != std::string::npos);
	CHECK(text.find("Position=3") != std::string::npos);
	std::istringstream	in(text);
	IniFile	back;
	back.Read(in);
	Playlist	q;
	CHECK(q.Read(back));
	CHECK_EQ(q.m_arrMapping.size(), size_t(4));
	if (q.m_arrMapping.size() == 4) {	// back in their places
		CHECK_EQ(q.m_arrMapping[0].m_iTarget, int(MB::TARGET_Zoom));
		CHECK_EQ(q.m_arrMapping[1].m_iTarget, int(MB::TARGET_MarkDownbeat));
		CHECK_EQ(q.m_arrMapping[1].m_iControl, 40);
		CHECK_EQ(q.m_arrMapping[2].m_iTarget, int(MB::TARGET_Tempo));
		CHECK_EQ(q.m_arrMapping[3].m_iTarget, int(MB::TARGET_Hue));
	}
	// an older Mac playlist, with them in [Mapping]: read there, moved on writing
	std::string	old = "[Mapping]\r\nCount=1\r\n[Mapping\\0]\r\nEvent=CONTROL\r\nTarget=Hue\r\nChannel=0\r\nControl=3\r\n";
	std::istringstream	in2(old);
	IniFile	ini2;
	ini2.Read(in2);
	MappingArray	arr;
	arr.Read(ini2);
	CHECK_EQ(arr.size(), size_t(1));
	CHECK_EQ(arr[0].m_iTarget, int(MB::TARGET_Hue));
	// a target a later version added: skipped, not read as Ring Growth
	std::string	later = "[Mapping]\r\nCount=0\r\n[MacMapping]\r\nCount=1\r\n[MacMapping\\0]\r\nEvent=CONTROL\r\nTarget=NoSuch\r\nPosition=0\r\n";
	std::istringstream	in3(later);
	IniFile	ini3;
	ini3.Read(in3);
	MappingArray	arr3;
	arr3.Read(ini3);
	CHECK(arr3.empty());
	// none: no section, as before
	pl.m_arrMapping.resize(1);
	IniFile	plain;
	pl.Write(plain);
	CHECK(WriteIni(plain).find("MacMapping") == std::string::npos);
}

TEST(LearnModeAndFiltering) {
	RecordingSink	sink;
	MidiManager	mgr(sink);
	mgr.OnMidiEvent(0xF8);	// clock: system message, ignored
	mgr.OnMidiEvent(0x01000090);	// not a short message
	CHECK(sink.posts.empty());
	mgr.SetLearnMode(true);
	mgr.OnMidiEvent(MakeMidiMsg(CONTROL, 4, 21, 9));
	CHECK_EQ(sink.posts.size(), size_t(1));
	CHECK_EQ(sink.posts[0].type, MidiManager::Post::MIDI_EVENT);
	CHECK_EQ(sink.posts[0].nMsg, MakeMidiMsg(CONTROL, 4, 21, 9));
}

int main() { return RunAllTests(); }
