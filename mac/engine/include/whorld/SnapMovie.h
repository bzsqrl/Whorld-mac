// Copyleft 2025 Chris Korda (original SnapMovie.h)
// Port to macOS: Copyright 2026 Jeff Matson. Part of Whorld for macOS.
// Written with Claude (Anthropic).
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. The original Whorld source is licensed GPL version 2 or
// any later version. See the LICENSE file at the repository root.

#pragma once

// ported from SnapMovie.h CSnapMovie: a movie of snapshots (.whm).
//
// File layout (little-endian, MSVC x64 struct layout):
//   HEADER, 40 bytes:
//     u32 file ID 'WHM2', u16 version (1), u16 sizeof(DRAW_STATE),
//     u16 sizeof(GLOB_RING), u16 sizeof(RING), f32 frame rate,
//     f32 x 2 target size (DIPs), i64 frame count, u64 frame index offset
//   frames: snapshot bodies back to back (DRAW_STATE, GLOB_RING, RINGs),
//     with no per-frame header
//   frame index: one u64 file offset per frame
// The header is written as a placeholder on open and rewritten on close,
// after the frame index.
//
// Windows writes frames with overlapped I/O, at most one write in flight.
// Here a background thread does the writing, with the same limit, so the
// render thread never waits on the disk unless the previous frame is still
// being written.

#include "whorld/Snapshot.h"

#include <condition_variable>
#include <cstdint>
#include <cstdio>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

namespace whorld {

class SnapMovie : public WhorldBase {
public:
// Construction
	SnapMovie();
	~SnapMovie();
	SnapMovie(const SnapMovie&) = delete;
	SnapMovie& operator=(const SnapMovie&) = delete;

// Constants
	enum {	// input/output states
		IO_CLOSED = -1,	// file is closed
		IO_READ,		// file is being read
		IO_WRITE,		// file is being written
	};
	enum {
		HEADER_SIZE = 40,
	};
	static const uint32_t m_nFileID;
	static const uint16_t m_nFileVersion;

// Attributes
	std::string	GetLastError() const { return m_sLastError; }	// replaces ERROR_STATE
	bool	IsOpen() const { return m_pFile != nullptr; }
	bool	IsReading() const { return m_nIOState == IO_READ; }
	bool	IsWriting() const { return m_nIOState > IO_READ; }
	int		GetIOState() const { return m_nIOState; }
	bool	IsEndOfFile() const { return m_iReadFrame >= m_hdr.nFrameCount; }
	int64_t	GetFramesWritten() const { return m_nWriteFrames; }
	int64_t	GetFrameCount() const { return m_hdr.nFrameCount; }
	int64_t	GetReadFrameIdx() const { return m_iReadFrame; }
	float	GetFrameRate() const { return m_hdr.fFrameRate; }
	void	SetFrameRate(float fFrameRate) { m_hdr.fFrameRate = fFrameRate; }
	SizeF	GetTargetSize() const { return m_hdr.szTarget; }
	void	SetTargetSize(const SizeF& szTarget) { m_hdr.szTarget = szTarget; }

// Operations
	bool	Open(const std::string& sPath, bool bWrite);
	bool	Close();
	bool	Write(const Snapshot& snapshot);
	std::unique_ptr<Snapshot>	Read();
	bool	SeekFrame(int64_t iFrame);

protected:
// Types
	struct HEADER {
		uint32_t	nFileID;		// file identifier
		uint16_t	nVersion;		// version number
		uint16_t	nDrawStateSize;	// size of DRAW_STATE in bytes
		uint16_t	nGlobRingSize;	// size of GLOB_RING in bytes
		uint16_t	nRingSize;		// size of RING in bytes
		float	fFrameRate;		// frame rate in frames per second
		SizeF	szTarget;		// target size in device-independent pixels
		int64_t	nFrameCount;	// number of frames in movie
		uint64_t	nIndexOffset;	// file offset of frame index in bytes
	};

// Data members
	FILE*	m_pFile;			// the movie file
	int64_t	m_nWriteFrames;		// during writing, number of frames written so far
	uint64_t	m_nWriteBytes;	// during writing, byte offset of current frame
	std::vector<uint64_t>	m_aWriteFrameIndex;	// during writing, each frame's byte offset
	std::vector<uint64_t>	m_aReadFrameIndex;	// during reading, each frame's byte offset
	HEADER	m_hdr;				// file header; used during both reading and writing
	int64_t	m_iReadFrame;		// during reading, current position as a frame index
	int		m_nIOState;			// movie input/output state; see enum above
	std::string	m_sLastError;	// replaces GetLastError and m_nLastErrorLine
	// background writer (replaces OVERLAPPED)
	std::thread	m_thrWrite;
	std::mutex	m_mutex;
	std::condition_variable	m_cv;
	std::vector<uint8_t>	m_aPending;	// frame waiting to be written
	uint64_t	m_nPendingPos;		// its file position
	bool	m_bPending;			// true if a write is queued or in progress
	bool	m_bWriteFailed;		// true if a background write failed
	bool	m_bQuit;

// Helpers
	bool	PreparedForWrite() const;
	bool	ReadHeader();
	bool	WriteHeader();
	bool	ReadFrameIndex();
	bool	WriteFrameIndex();
	bool	FinalizeWrite();
	bool	ReadBuf(void* pBuffer, size_t nBytesToRead);
	bool	WriteSync(const void* pBuffer, size_t nBytesToWrite, uint64_t nWritePos);
	bool	WriteAsync(std::vector<uint8_t>&& aFrame);
	bool	FinishAsyncWrite();
	void	WriterThread();
	bool	Fail(const std::string& sMsg);
};

inline bool SnapMovie::PreparedForWrite() const
{
	// true if frame rate and target size are specified
	return m_hdr.fFrameRate > 0 && m_hdr.szTarget.width > 0 && m_hdr.szTarget.height > 0;
}

} // namespace whorld
