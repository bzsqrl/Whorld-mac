// This file is part of Whorld for macOS, a port of Whorld by Chris Korda.
// Copyright 2026 Jeff Matson.
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See the LICENSE file at the repository root.

// Tests for SnapMovie (.whm) and the engine's movie record and playback.

#include "RecordingRenderer.h"
#include "TestHarness.h"
#include "whorld/Random.h"
#include "whorld/SnapMovie.h"
#include "whorld/WhorldEngine.h"

#include <cstdio>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <string>
#include <vector>

using namespace whorld;
namespace fs = std::filesystem;

namespace {

std::string ReadBytes(const fs::path& path)
{
	std::ifstream	f(path, std::ios::binary);
	return std::string(std::istreambuf_iterator<char>(f), std::istreambuf_iterator<char>());
}

fs::path SampleMovie()
{
	return fs::path(WHORLD_TESTDATA_DIR) / "movies" / "kaleid_cvx.whm";
}

} // namespace

TEST(SampleMovieHeaderAndFrames) {
	if (!fs::exists(SampleMovie())) {
		std::printf("  (no sample movie; skipped)\n");
		return;
	}
	SnapMovie	movie;
	CHECK(movie.Open(SampleMovie().string(), false));
	CHECK(movie.IsReading());
	CHECK_EQ(movie.GetFrameCount(), int64_t(1118));
	CHECK_EQ(movie.GetFrameRate(), 144.0f);
	CHECK_EQ(movie.GetTargetSize().width, 1056.0f);
	CHECK_EQ(movie.GetTargetSize().height, 1234.0f);
	std::vector<std::vector<uint8_t>>	frames;
	while (!movie.IsEndOfFile()) {
		auto	p = movie.Read();
		CHECK(p != nullptr);
		if (!p)
			break;
		frames.push_back(Snapshot::Encode(*p));
	}
	CHECK_EQ(frames.size(), size_t(1118));
	// seeking lands on the same frame as reading sequentially
	CHECK(movie.SeekFrame(500));
	CHECK_EQ(movie.GetReadFrameIdx(), int64_t(500));
	auto	p500 = movie.Read();
	CHECK(p500 != nullptr && Snapshot::Encode(*p500) == frames[500]);
	CHECK(!movie.SeekFrame(1118));	// out of range
	CHECK(!movie.GetLastError().empty());
	CHECK(movie.Close());
}

TEST(SampleMovieRewritesByteForByte) {
	if (!fs::exists(SampleMovie()))
		return;
	SnapMovie	in;
	CHECK(in.Open(SampleMovie().string(), false));
	fs::path	pathOut = fs::temp_directory_path() / "whorld_test_movie.whm";
	SnapMovie	out;
	out.SetFrameRate(in.GetFrameRate());
	out.SetTargetSize(in.GetTargetSize());
	CHECK(out.Open(pathOut.string(), true));
	CHECK(out.IsWriting());
	while (!in.IsEndOfFile()) {
		auto	p = in.Read();
		if (!p)
			break;
		CHECK(out.Write(*p));
	}
	CHECK_EQ(out.GetFramesWritten(), int64_t(1118));
	CHECK(out.Close());
	in.Close();
	bool	bSame = ReadBytes(pathOut) == ReadBytes(SampleMovie());
	CHECK(bSame);
	if (bSame)
		std::printf("  1118 frames rewritten byte for byte (%ju bytes)\n", uintmax_t(fs::file_size(pathOut)));
	fs::remove(pathOut);
}

TEST(OpenErrors) {
	SnapMovie	movie;
	CHECK(!movie.Open((fs::temp_directory_path() / "no_such_movie.whm").string(), false));
	CHECK(!movie.GetLastError().empty());
	CHECK(!movie.Open((fs::temp_directory_path() / "x.whm").string(), true));	// no frame rate or size
	fs::path	junk = fs::temp_directory_path() / "whorld_junk.whm";
	{
		std::ofstream	f(junk, std::ios::binary);
		f << std::string(64, 'x');
	}
	CHECK(!movie.Open(junk.string(), false));
	CHECK_EQ(movie.GetLastError(), std::string("Unexpected file format."));
	fs::remove(junk);
}

TEST(EngineRecordsAndPlaysBack) {
	fs::path	path = fs::temp_directory_path() / "whorld_engine_movie.whm";
	whorld::srand(1);
	WhorldEngine	eng;
	eng.OnResize(SizeF{640, 480});
	RecordingRenderer	rec;
	for (int i = 0; i < 30; i++)
		eng.Draw(rec);
	std::string	sPath = path.string();
	eng.OnMovieRecord(&sPath);
	CHECK_EQ(eng.GetMovieState().nIOState, int(SnapMovie::IO_WRITE));
	std::vector<size_t>	aRings;
	for (int i = 0; i < 40; i++) {
		eng.Draw(rec);	// each unpaused frame is recorded after drawing
		aRings.push_back(eng.GetRingCount());
	}
	CHECK_EQ(eng.GetMovieState().iFrame, int64_t(40));
	eng.OnMovieRecord(nullptr);	// stop
	CHECK_EQ(eng.GetMovieState().nIOState, int(SnapMovie::IO_CLOSED));
	// play it back paused: frames advance only by single-stepping
	size_t	nLive = eng.GetRingCount();
	eng.OnMoviePlay(&sPath, true);
	CHECK(eng.IsSnapshotMode());
	CHECK_EQ(eng.GetMovieState().nFrameCount, int64_t(40));
	eng.Draw(rec);
	CHECK_EQ(eng.GetMovieState().iFrame, int64_t(0));	// paused: nothing read
	eng.OnSingleStep();
	eng.Draw(rec);
	CHECK_EQ(eng.GetMovieState().iFrame, int64_t(1));
	CHECK_EQ(eng.GetRingCount(), aRings[0]);
	// unpause the movie: one frame per draw
	eng.OnMoviePause(false);
	for (int i = 0; i < 10; i++)
		eng.Draw(rec);
	CHECK_EQ(eng.GetMovieState().iFrame, int64_t(11));
	CHECK_EQ(eng.GetRingCount(), aRings[10]);
	// seek while paused reads exactly that frame
	eng.OnMoviePause(true);
	eng.OnMovieSeek(25);
	CHECK_EQ(eng.GetMovieState().iFrame, int64_t(26));
	CHECK_EQ(eng.GetRingCount(), aRings[25]);
	// export steps one frame at a time
	CHECK(eng.MovieExportStart(38));
	CHECK(eng.MovieExportStep());
	CHECK(eng.MovieExportStep());
	CHECK_EQ(eng.GetMovieState().iFrame, int64_t(40));
	CHECK(eng.MovieExportStep());	// end of movie: nothing to read, not an error
	// stop playback, then unpause to return to the live state
	eng.OnMoviePlay(nullptr, false);
	eng.OnSetPause(false);
	CHECK(!eng.IsSnapshotMode());
	CHECK_EQ(eng.GetRingCount(), nLive);
	fs::remove(path);
}

TEST(MovieErrorsAreReported) {
	WhorldEngine	eng;
	eng.OnResize(SizeF{100, 100});
	std::string	sError;
	eng.SetReplyCallback([&](const WhorldEngine::Reply& r) {
		if (r.nCmd == WhorldBase::RC_MOVIE_PLAY)
			sError = r.sError;
	});
	std::string	sPath = (fs::temp_directory_path() / "nope.whm").string();
	WhorldEngine::RenderCmd	cmd(WhorldBase::RC_MOVIE_PLAY);
	cmd.m_prop.byref = new std::string(sPath);	// engine takes ownership
	eng.OnRenderCommand(cmd);
	CHECK(!sError.empty());
	CHECK(!eng.IsSnapshotMode());
}

int main() { return RunAllTests(); }
