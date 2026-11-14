// This file is part of Whorld for macOS, a port of Whorld by Chris Korda.
// Copyright 2026 Jeff Matson.
// Written with Claude (Anthropic).
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See the LICENSE file at the repository root.

// OSC (Mac port): the message format, the address table, and that incoming
// values do what a MIDI mapping does and come back unchanged.

#include "TestHarness.h"
#include "whorld/MidiManager.h"
#include "whorld/Osc.h"
#include "whorld/OscRemote.h"
#include "whorld/Patch.h"

#include <cstring>
#include <set>
#include <string>
#include <vector>

using namespace whorld;
using MB = MappingBase;

namespace {

struct RecordingSink : MidiManager::Sink {
	std::vector<WhorldBase::RenderCmd>	cmds;
	std::vector<MidiManager::Post>	posts;
	void	PushCommand(const WhorldBase::RenderCmd& cmd) override { cmds.push_back(cmd); }
	void	PostToMain(const MidiManager::Post& post) override { posts.push_back(post); }
	void	Clear() { cmds.clear(); posts.clear(); }
};

// What the app does with a post (WHEngine applyMidiPost), for the round trip.
void Apply(Patch& doc, const MidiManager::Post& post)
{
	using Post = MidiManager::Post;
	switch (post.type) {
	case Post::PARAM_CHANGE:
		{
			WhorldBase::VARIANT_PROP	v;
			v.llVal = 0;
			if (post.iProp == WhorldBase::PARAM_PROP_Wave)
				v.intVal = post.iVal;
			else
				v.dblVal = post.fVal;
			doc.SetParamRC(post.iParam, post.iProp, v);
		}
		break;
	case Post::MASTER_PROP_CHANGE:
		doc.SetMasterProp(post.iProp, post.fVal);
		break;
	case Post::MAIN_PROP_CHANGE:
		{
			WhorldBase::VARIANT_PROP	v;
			v.llVal = post.iVal;
			doc.SetMainProp(post.iProp, v);
		}
		break;
	case Post::SET_DRAW_MODE:
		doc.m_main.nDrawMode = (doc.m_main.nDrawMode & ~post.nMask) | (post.nValue & post.nMask);
		break;
	default:
		break;
	}
}

OscMessage Msg(const std::string& path, std::vector<OscArg> args = {})
{
	OscMessage	m;
	m.path = path;
	m.args = std::move(args);
	return m;
}

}	// namespace

TEST(EncodeMatchesTheSpec) {
	// the OSC 1.0 spec's example: "/oscillator/4/frequency" ,f 440.0
	auto	v = Osc::Encode(Msg("/oscillator/4/frequency", {OscArg::Float(440)}));
	const uint8_t	expect[] = {
		'/', 'o', 's', 'c', 'i', 'l', 'l', 'a', 't', 'o', 'r', '/', '4', '/', 'f', 'r',
		'e', 'q', 'u', 'e', 'n', 'c', 'y', 0, ',', 'f', 0, 0, 0x43, 0xdc, 0x00, 0x00};
	CHECK_EQ(v.size(), sizeof(expect));
	CHECK(v.size() == sizeof(expect) && std::memcmp(v.data(), expect, sizeof(expect)) == 0);
}

TEST(RoundTripAllTypes) {
	OscMessage	m = Msg("/w/test", {OscArg::Int(-7), OscArg::Float(0.25), OscArg::String("hello"),
		OscArg::String("four"), OscArg::Int(123456789)});
	OscArg	b;
	b.type = OscArg::BOOL;
	b.i = 1;
	m.args.push_back(b);
	auto	v = Osc::Encode(m);
	CHECK_EQ(v.size() % 4, size_t(0));
	auto	out = Osc::Decode(v.data(), v.size());
	CHECK_EQ(out.size(), size_t(1));
	if (out.size() != 1)
		return;
	CHECK_EQ(out[0].path, std::string("/w/test"));
	CHECK_EQ(out[0].args.size(), size_t(6));
	if (out[0].args.size() != 6)
		return;
	CHECK_EQ(out[0].args[0].i, int64_t(-7));
	CHECK_EQ(out[0].args[1].f, 0.25);
	CHECK_EQ(out[0].args[2].s, std::string("hello"));
	CHECK_EQ(out[0].args[3].s, std::string("four"));	// exactly 4 characters: a whole word of padding
	CHECK_EQ(out[0].args[4].i, int64_t(123456789));
	CHECK(out[0].args[5].type == OscArg::BOOL && out[0].args[5].i == 1);
}

TEST(DecodeBundlesAndRejectJunk) {
	auto	a = Osc::Encode(Msg("/w/m/sp", {OscArg::Float(0.5)}));
	auto	b = Osc::Encode(Msg("/w/clear"));
	std::vector<uint8_t>	inner = {'#', 'b', 'u', 'n', 'd', 'l', 'e', 0, 0, 0, 0, 0, 0, 0, 0, 1};
	auto	put = [](std::vector<uint8_t>& v, const std::vector<uint8_t>& e) {
		uint32_t	n = static_cast<uint32_t>(e.size());
		v.push_back(uint8_t(n >> 24)); v.push_back(uint8_t(n >> 16));
		v.push_back(uint8_t(n >> 8)); v.push_back(uint8_t(n));
		v.insert(v.end(), e.begin(), e.end());
	};
	put(inner, b);
	std::vector<uint8_t>	outer = {'#', 'b', 'u', 'n', 'd', 'l', 'e', 0, 0, 0, 0, 0, 0, 0, 0, 1};
	put(outer, a);
	put(outer, inner);	// a bundle in a bundle
	auto	msgs = Osc::Decode(outer.data(), outer.size());
	CHECK_EQ(msgs.size(), size_t(2));
	if (msgs.size() == 2) {
		CHECK_EQ(msgs[0].path, std::string("/w/m/sp"));
		CHECK_EQ(msgs[1].path, std::string("/w/clear"));
	}
	// junk: not a multiple of 4, no leading slash, truncated arguments, a bad bundle size
	const uint8_t	odd[] = {'/', 'w', 0};
	CHECK(Osc::Decode(odd, sizeof(odd)).empty());
	const uint8_t	noslash[] = {'w', 0, 0, 0};
	CHECK(Osc::Decode(noslash, sizeof(noslash)).empty());
	auto	t = Osc::Encode(Msg("/w/m/sp", {OscArg::Float(1)}));
	t.resize(t.size() - 4);	// the float is gone: the message keeps its address, no arguments
	auto	tm = Osc::Decode(t.data(), t.size());
	CHECK(tm.size() == 1 && tm[0].args.empty());
	std::vector<uint8_t>	bad = {'#', 'b', 'u', 'n', 'd', 'l', 'e', 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 1, 0};
	CHECK(Osc::Decode(bad.data(), bad.size()).empty());
	CHECK(Osc::Decode(nullptr, 0).empty());
}

TEST(EveryMidiTargetHasAnAddress) {
	std::set<std::pair<int, int>>	covered;
	std::set<std::string>	paths;
	for (const auto& a : OscRemote::Inputs()) {
		covered.insert({a.iTarget, a.iProp});
		CHECK(paths.insert(a.path).second);	// unique
		CHECK(a.path.rfind("/w/", 0) == 0);
		CHECK(a.path.size() <= 15);	// short: "/w/p/rg/v", "/w/rndphase", "/w/mod/downbeat"
		int	iProp;
		CHECK_EQ(OscRemote::Find(a.path, iProp), a.iTarget);
		CHECK_EQ(iProp, a.iProp);
	}
	for (int t = 0; t < MB::TARGETS; t++) {
		if (MB::TargetHasProperty(t)) {
			for (int p = 0; p < WhorldBase::PARAM_PROP_COUNT; p++) {
				bool	bHas = p != WhorldBase::PARAM_PROP_Global || WhorldBase::MapParamToGlobal(t) >= 0;
				CHECK_EQ(covered.count({t, p}) == 1, bHas);
			}
		} else {
			CHECK(covered.count({t, -1}) == 1);
		}
	}
	int	iProp;
	CHECK_EQ(OscRemote::Find("/w/p/rg", iProp), 0);	// shorthand for the value
	CHECK_EQ(iProp, int(WhorldBase::PARAM_PROP_Val));
	CHECK_EQ(OscRemote::Find("/w/m/fd", iProp), WhorldBase::PARAM_COUNT + WhorldBase::MASTER_Fade);
	CHECK_EQ(OscRemote::Find("/w/nope", iProp), -1);
}

TEST(ValuesActAsMidiAndComeBack) {
	RecordingSink	sink;
	MidiManager	midi(sink);
	Patch	doc;
	doc.SetDefaults();
	// every parameter column and master property: send a value, apply what
	// Whorld posts, read it back
	for (const auto& a : OscRemote::Inputs()) {
		if (a.iTarget >= WhorldBase::PARAM_COUNT + WhorldBase::MASTER_COUNT)
			continue;
		bool	bWave = a.iProp == WhorldBase::PARAM_PROP_Wave;
		OscArg	in = bWave ? OscArg::Int(3) : OscArg::Float(0.375);
		sink.Clear();
		auto	req = OscRemote::Handle(Msg(a.path, {in}), midi);
		CHECK(req.type == OscRemote::Request::DISPATCHED);
		CHECK(!sink.cmds.empty());
		for (const auto& post : sink.posts)
			Apply(doc, post);
		OscArg	out;
		CHECK(OscRemote::StateValue(doc, a.iTarget, a.iProp, out));
		if (bWave)
			CHECK(out.type == OscArg::INT && out.i == 3);
		else
			CHECK_NEAR(out.f, 0.375, 1e-9);
	}
	// the same as a MIDI mapping: Ring Growth's value at 0.375 of its range
	const auto&	info = WhorldBase::GetParamInfo(WhorldBase::PARAM_RingGrowth);
	CHECK_NEAR(doc.m_aParam.row[WhorldBase::PARAM_RingGrowth].fVal,
		info.fMinVal + 0.375 * (info.fMaxVal - info.fMinVal), 1e-9);
	// outside 0..1, as a mapping with a wider range: 4 Hz
	sink.Clear();
	OscRemote::Handle(Msg("/w/p/rg/f", {OscArg::Float(4)}), midi);
	for (const auto& post : sink.posts)
		Apply(doc, post);
	CHECK_EQ(doc.m_aParam.row[WhorldBase::PARAM_RingGrowth].fFreq, 4.0);
	// a float waveform is normalized, as MIDI's is: 0.9 of 8 waveforms is the 8th (index 7)
	sink.Clear();
	OscRemote::Handle(Msg("/w/p/lw/w", {OscArg::Float(0.9)}), midi);
	CHECK(!sink.posts.empty() && sink.posts[0].iVal == 7);
}

TEST(SwitchesActionsPauseAndPatch) {
	RecordingSink	sink;
	MidiManager	midi(sink);
	Patch	doc;
	doc.SetDefaults();
	using R = OscRemote::Request;
	auto	req = OscRemote::Handle(Msg("/w/mirror", {OscArg::Float(1)}), midi);
	CHECK(req.type == R::DISPATCHED);
	for (const auto& post : sink.posts)
		Apply(doc, post);
	CHECK(doc.m_main.bMirror);
	OscArg	out;
	CHECK(OscRemote::StateValue(doc, req.iTarget, -1, out) && out.f == 1);
	CHECK(OscRemote::Handle(Msg("/w/mirror"), midi).type == R::TOGGLE);	// no argument: toggle
	sink.Clear();
	CHECK(OscRemote::Handle(Msg("/w/fill", {OscArg::Int(1)}), midi).type == R::DISPATCHED);
	for (const auto& post : sink.posts)
		Apply(doc, post);
	CHECK(doc.m_main.nDrawMode & WhorldBase::DM_FILL);
	// actions on press, not release
	sink.Clear();
	CHECK(OscRemote::Handle(Msg("/w/clear", {OscArg::Float(0)}), midi).type == R::NONE);
	CHECK(sink.cmds.empty());
	CHECK(OscRemote::Handle(Msg("/w/clear"), midi).type == R::DISPATCHED);
	CHECK(OscRemote::Handle(Msg("/w/rndphase", {OscArg::Float(1)}), midi).type == R::DISPATCHED);
	CHECK(!OscRemote::StateValue(doc, req.iTarget + 8, -1, out));	// RandomPhase: nothing to report
	// pause and patch are the app's
	auto	p = OscRemote::Handle(Msg("/w/pause"), midi);
	CHECK(p.type == R::PAUSE && p.iVal == -1);
	p = OscRemote::Handle(Msg("/w/pause", {OscArg::Float(1)}), midi);
	CHECK(p.type == R::PAUSE && p.iVal == 1);
	p = OscRemote::Handle(Msg("/w/patch", {OscArg::Int(12)}), midi);
	CHECK(p.type == R::PATCH && p.iVal == 12);
	p = OscRemote::Handle(Msg("/w/patch", {OscArg::Float(1)}), midi);	// normalized: MIDI's 127
	CHECK(p.type == R::PATCH && p.iVal == 127);
	// the origin, one at a time or as an XY pad
	sink.Clear();
	CHECK(OscRemote::Handle(Msg("/w/org", {OscArg::Float(0.25), OscArg::Float(0.75)}), midi).type == R::DISPATCHED);
	CHECK_EQ(sink.cmds.size(), size_t(2));
	CHECK(OscRemote::Handle(Msg("/w/ping"), midi).type == R::PING);
	CHECK(OscRemote::Handle(Msg("/w/sync"), midi).type == R::SYNC);
	CHECK(OscRemote::Handle(Msg("/other/app"), midi).type == R::NONE);
	CHECK(OscRemote::Handle(Msg("/w/m/sp"), midi).type == R::NONE);	// a range needs a number
}

int main() { return RunAllTests(); }
