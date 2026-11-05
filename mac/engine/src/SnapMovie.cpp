// Copyleft 2025 Chris Korda (original SnapMovie.cpp)
// Port to macOS: Copyright 2026 Jeff Matson. Part of Whorld for macOS.
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. The original Whorld source is licensed GPL version 2 or
// any later version. See the LICENSE file at the repository root.

#include "whorld/SnapMovie.h"
#include "ByteIO.h"

#include <algorithm>
#include <cerrno>
#include <cstring>

namespace whorld {

using namespace bin;

const uint32_t SnapMovie::m_nFileID = Snapshot::MakeFourCC('W', 'H', 'M', '2');
const uint16_t SnapMovie::m_nFileVersion = 1;

// ported from SnapMovie.cpp CSnapMovie::CSnapMovie
SnapMovie::SnapMovie()
{
	m_pFile = nullptr;
	m_nWriteFrames = 0;
	m_nWriteBytes = 0;
	std::memset(&m_hdr, 0, sizeof(m_hdr));
	m_iReadFrame = 0;
	m_nIOState = IO_CLOSED;
	m_nPendingPos = 0;
	m_bPending = false;
	m_bWriteFailed = false;
	m_bQuit = false;
}

SnapMovie::~SnapMovie()
{
	Close();
}

bool SnapMovie::Fail(const std::string& sMsg)	// replaces ABORT and ABORT2
{
	m_sLastError = sMsg;
	return false;
}

// ported from SnapMovie.cpp CSnapMovie::Open
bool SnapMovie::Open(const std::string& sPath, bool bWrite)
{
	if (!Close()) {	// close file if it's open
		return false;
	}
	if (bWrite) {	// if opening for write
		// frame rate and target size must be specified before opening
		if (!PreparedForWrite()) {	// if caller hasn't prepared
			return Fail("Movie frame rate and size aren't set.");	// ERROR_INVALID_STATE
		}
	}
	m_pFile = std::fopen(sPath.c_str(), bWrite ? "wb" : "rb");
	if (!IsOpen()) {	// if file not open
		return Fail("Can't open " + sPath + ": " + std::strerror(errno));
	}
	m_aWriteFrameIndex.clear();
	m_aReadFrameIndex.clear();
	if (bWrite) {	// if opening for write
		m_nWriteFrames = 0;	// reset frames written count
		m_nWriteBytes = HEADER_SIZE;	// set output position past header
		m_bWriteFailed = false;
		m_bQuit = false;
		m_thrWrite = std::thread([this] { WriterThread(); });
		// write dummy header; real header will be written by Close
		if (!WriteHeader()) {	// if we can't write header
			Close();
			return false;	// fail; error already handled
		}
	} else {	// opening for read
		if (!ReadHeader() || !ReadFrameIndex()) {	// if we can't read header or index
			std::fclose(m_pFile);
			m_pFile = nullptr;
			return false;	// fail; error already handled
		}
		m_iReadFrame = 0;	// read starts with first frame
	}
	m_nIOState = bWrite;	// update I/O state
	return true;	// success
}

// ported from SnapMovie.cpp CSnapMovie::Close
bool SnapMovie::Close()
{
	if (!IsOpen()) {	// if file isn't open
		return true;	// nothing to do, but not an error
	}
	bool	bRetVal = true;
	if (IsWriting()) {	// if we're writing
		// write frame index and then rewrite header
		bRetVal = FinalizeWrite();
	}
	if (m_thrWrite.joinable()) {	// stop the writer
		{
			std::lock_guard<std::mutex>	lock(m_mutex);
			m_bQuit = true;
		}
		m_cv.notify_all();
		m_thrWrite.join();
	}
	if (std::fclose(m_pFile) != 0 && bRetVal)	// close file
		bRetVal = Fail(std::string("Error closing movie: ") + std::strerror(errno));
	m_pFile = nullptr;	// mark it closed
	m_nIOState = IO_CLOSED;	// update I/O state
	return bRetVal;
}

// ported from SnapMovie.cpp CSnapMovie::ReadHeader
bool SnapMovie::ReadHeader()
{
	std::memset(&m_hdr, 0, sizeof(m_hdr));
	uint8_t	b[HEADER_SIZE];
	if (!ReadBuf(b, HEADER_SIZE)) {	// if we can't read header
		return false;	// failed to read header
	}
	m_hdr.nFileID = GetU32(b);
	m_hdr.nVersion = GetU16(b + 4);
	m_hdr.nDrawStateSize = GetU16(b + 6);
	m_hdr.nGlobRingSize = GetU16(b + 8);
	m_hdr.nRingSize = GetU16(b + 10);
	m_hdr.fFrameRate = GetF32(b + 12);
	m_hdr.szTarget = SizeF{GetF32(b + 16), GetF32(b + 20)};
	m_hdr.nFrameCount = GetI64(b + 24);
	m_hdr.nIndexOffset = GetU64(b + 32);
	if (m_hdr.nFileID != m_nFileID) {	// if file identifiers don't match
		return Fail("Unexpected file format.");	// ERROR_INVALID_DATA
	}
	return true;	// success
}

// ported from SnapMovie.cpp CSnapMovie::WriteHeader
bool SnapMovie::WriteHeader()
{
	// frame rate and target size must be specified beforehand
	if (!PreparedForWrite()) {	// if caller didn't do so
		return Fail("Movie frame rate and size aren't set.");
	}
	m_hdr.nFileID = m_nFileID;
	m_hdr.nVersion = m_nFileVersion;
	m_hdr.nDrawStateSize = Snapshot::DRAW_STATE_SIZE;
	m_hdr.nGlobRingSize = Snapshot::GLOB_RING_SIZE;
	m_hdr.nRingSize = Snapshot::RING_SIZE;
	m_hdr.nFrameCount = m_nWriteFrames;
	m_hdr.nIndexOffset = m_nWriteBytes;
	uint8_t	b[HEADER_SIZE];
	PutU32(b, m_hdr.nFileID);
	PutU16(b + 4, m_hdr.nVersion);
	PutU16(b + 6, m_hdr.nDrawStateSize);
	PutU16(b + 8, m_hdr.nGlobRingSize);
	PutU16(b + 10, m_hdr.nRingSize);
	PutF32(b + 12, m_hdr.fFrameRate);
	PutF32(b + 16, m_hdr.szTarget.width);
	PutF32(b + 20, m_hdr.szTarget.height);
	PutU64(b + 24, static_cast<uint64_t>(m_hdr.nFrameCount));
	PutU64(b + 32, m_hdr.nIndexOffset);
	return WriteSync(b, HEADER_SIZE, 0);	// rewrite header in place
}

// ported from SnapMovie.cpp CSnapMovie::ReadFrameIndex
bool SnapMovie::ReadFrameIndex()
{
	if (m_hdr.nFrameCount < 0)
		return Fail("Invalid frame count.");
	// seek to frame index
	if (fseeko(m_pFile, static_cast<off_t>(m_hdr.nIndexOffset), SEEK_SET) != 0) {	// if we can't seek
		return Fail(std::string("Can't seek: ") + std::strerror(errno));
	}
	// read frame index
	std::vector<uint8_t>	b(static_cast<size_t>(m_hdr.nFrameCount) * 8);
	if (!ReadBuf(b.data(), b.size())) {	// if we can't read
		return false;	// failed to read frame index
	}
	m_aReadFrameIndex.resize(static_cast<size_t>(m_hdr.nFrameCount));
	for (size_t i = 0; i < m_aReadFrameIndex.size(); i++)
		m_aReadFrameIndex[i] = GetU64(&b[i * 8]);
	// seek to first snapshot
	if (fseeko(m_pFile, HEADER_SIZE, SEEK_SET) != 0) {	// if we can't seek
		return Fail(std::string("Can't seek: ") + std::strerror(errno));
	}
	return true;	// success
}

// ported from SnapMovie.cpp CSnapMovie::WriteFrameIndex
bool SnapMovie::WriteFrameIndex()
{
	std::vector<uint8_t>	b(m_aWriteFrameIndex.size() * 8);
	for (size_t i = 0; i < m_aWriteFrameIndex.size(); i++)
		PutU64(&b[i * 8], m_aWriteFrameIndex[i]);
	// start at end of last snapshot written
	return WriteSync(b.data(), b.size(), m_nWriteBytes);
}

bool SnapMovie::ReadBuf(void* pBuffer, size_t nBytesToRead)
{
	if (std::fread(pBuffer, 1, nBytesToRead, m_pFile) != nBytesToRead)
		return Fail(std::feof(m_pFile) ? "Unexpected end of file." : std::strerror(errno));
	return true;
}

// ported from SnapMovie.cpp CSnapMovie::Read
std::unique_ptr<Snapshot> SnapMovie::Read()
{
	// same as Snapshot::Read except the file header is handled differently
	std::vector<uint8_t>	buf(std::max<size_t>({m_hdr.nDrawStateSize, m_hdr.nGlobRingSize, m_hdr.nRingSize}));
	size_t	nStateSize = std::min<size_t>(m_hdr.nDrawStateSize, Snapshot::DRAW_STATE_SIZE);
	if (!ReadBuf(buf.data(), nStateSize)) {
		return nullptr;	// failed to read draw state
	}
	DRAW_STATE	drawState;
	Snapshot::DecodeDrawState(buf.data(), nStateSize, drawState);
	if (drawState.nRings < 0) {
		Fail("Invalid ring count.");
		return nullptr;
	}
	std::unique_ptr<Snapshot>	pSnapshot(Snapshot::Alloc(drawState.nRings));
	pSnapshot->m_drawState = drawState;
	size_t	nGlobSize = std::min<size_t>(m_hdr.nGlobRingSize, Snapshot::GLOB_RING_SIZE);
	if (!ReadBuf(buf.data(), nGlobSize)) {
		return nullptr;	// failed to read global ring
	}
	Snapshot::DecodeGlobRing(buf.data(), nGlobSize, pSnapshot->m_globRing);
	size_t	nRingSize = std::min<size_t>(m_hdr.nRingSize, Snapshot::RING_SIZE);
	for (int iRing = 0; iRing < drawState.nRings; iRing++) {
		if (!ReadBuf(buf.data(), nRingSize)) {
			return nullptr;	// failed to read ring
		}
		Snapshot::DecodeRing(buf.data(), nRingSize, pSnapshot->m_aRing[iRing]);
	}
	m_iReadFrame++;	// increment read position in frames
	return pSnapshot;	// success
}

// ported from SnapMovie.cpp CSnapMovie::SeekFrame
bool SnapMovie::SeekFrame(int64_t iFrame)
{
	if (!IsReading()) {	// if not reading
		return Fail("Can't seek: the movie isn't being played.");	// ERROR_INVALID_OPERATION
	}
	if (iFrame < 0 || iFrame >= GetFrameCount()) {	// if range error
		return Fail("Frame index is out of range.");	// ERROR_INVALID_INDEX
	}
	// seek to specified frame
	if (fseeko(m_pFile, static_cast<off_t>(m_aReadFrameIndex[iFrame]), SEEK_SET) != 0) {
		return Fail(std::string("Can't seek: ") + std::strerror(errno));
	}
	m_iReadFrame = iFrame;	// set read position
	return true;
}

// ported from SnapMovie.cpp CSnapMovie::FinalizeWrite
bool SnapMovie::FinalizeWrite()
{
	if (!WriteFrameIndex()) {	// if we can't write the frame index
		return false;	// fail; error already handled
	}
	if (!WriteHeader()) {	// if we can't rewrite the header
		return false;	// fail; error already handled
	}
	return true;	// success
}

// ported from SnapMovie.cpp CSnapMovie::Write
bool SnapMovie::Write(const Snapshot& snapshot)
{
	std::vector<uint8_t>	aFrame = Snapshot::Encode(snapshot);
	aFrame.erase(aFrame.begin(), aFrame.begin() + Snapshot::HEADER_SIZE);	// no per-frame header
	size_t	nSnapSize = aFrame.size();
	if (!WriteAsync(std::move(aFrame))) {	// if write failed
		return false;	// failed to write snapshot; error already handled
	}
	m_aWriteFrameIndex.push_back(m_nWriteBytes);	// add file position to frame index
	m_nWriteBytes += nSnapSize;	// add snapshot size to total bytes written
	m_nWriteFrames++;	// bump count of frames written
	return true;	// success
}

// ported from SnapMovie.cpp CSnapMovie::WriteSync: waits for the pending
// frame, then writes at the given position
bool SnapMovie::WriteSync(const void* pBuffer, size_t nBytesToWrite, uint64_t nWritePos)
{
	// wait for pending overlapped snapshot write (if any) to complete
	if (!FinishAsyncWrite()) {
		return false;	// fail; error already handled
	}
	if (fseeko(m_pFile, static_cast<off_t>(nWritePos), SEEK_SET) != 0
	|| std::fwrite(pBuffer, 1, nBytesToWrite, m_pFile) != nBytesToWrite) {
		return Fail(std::string("Error writing movie: ") + std::strerror(errno));
	}
	return true;	// write successfully completed
}

// ported from SnapMovie.cpp CSnapMovie::WriteAsync: hands the frame to the
// writer thread, first waiting for the previous one
bool SnapMovie::WriteAsync(std::vector<uint8_t>&& aFrame)
{
	// wait for pending overlapped snapshot write (if any) to complete
	if (!FinishAsyncWrite()) {
		return false;	// fail; error already handled
	}
	{
		std::lock_guard<std::mutex>	lock(m_mutex);
		m_aPending = std::move(aFrame);
		m_nPendingPos = m_nWriteBytes;
		m_bPending = true;
	}
	m_cv.notify_all();
	return true;	// write is pending
}

// ported from SnapMovie.cpp CSnapMovie::FinishAsyncWrite
bool SnapMovie::FinishAsyncWrite()
{
	std::unique_lock<std::mutex>	lock(m_mutex);
	m_cv.wait(lock, [this] { return !m_bPending; });
	if (m_bWriteFailed) {	// if the background write failed
		m_bWriteFailed = false;
		return false;	// error already recorded
	}
	return true;	// write successfully completed
}

void SnapMovie::WriterThread()
{
	std::unique_lock<std::mutex>	lock(m_mutex);
	for (;;) {
		m_cv.wait(lock, [this] { return m_bPending || m_bQuit; });
		if (m_bPending) {
			std::vector<uint8_t>	aFrame;
			aFrame.swap(m_aPending);
			uint64_t	nPos = m_nPendingPos;
			lock.unlock();	// the main side only touches the file after waiting
			bool	bOk = fseeko(m_pFile, static_cast<off_t>(nPos), SEEK_SET) == 0
				&& std::fwrite(aFrame.data(), 1, aFrame.size(), m_pFile) == aFrame.size();
			std::string	sErr = bOk ? std::string() : std::string("Error writing movie: ") + std::strerror(errno);
			lock.lock();
			if (!bOk) {
				m_sLastError = sErr;
				m_bWriteFailed = true;
			}
			m_bPending = false;
			m_cv.notify_all();
		} else if (m_bQuit) {
			return;
		}
	}
}

} // namespace whorld
