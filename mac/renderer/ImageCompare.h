// This file is part of Whorld for macOS, a port of Whorld by Chris Korda.
// Copyright 2026 Jeff Matson.
// Written with Claude (Anthropic).
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See the LICENSE file at the repository root.

#pragma once

// Loading images as raw 8-bit RGBA and comparing them, for golden tests.

#include <cstdint>
#include <string>
#include <vector>

namespace whorld {

struct ImageRGBA {
	int		nWidth = 0;
	int		nHeight = 0;
	std::vector<uint8_t>	aPixel;	// RGBA, straight alpha as stored, row 0 at top
};

// Decode a PNG without color management: the stored sample values.
bool LoadImageRGBA(const std::string& sPath, ImageRGBA& img, std::string* pError = nullptr);

// Convert a renderer's BGRA bitmap to RGBA with the same byte values that
// CGBitmapRenderer::WritePNG would store.
ImageRGBA FromBGRA(const uint8_t* pPixels, int nWidth, int nHeight, size_t nStride);

bool SaveImageRGBA(const std::string& sPath, const ImageRGBA& img, std::string* pError = nullptr);

struct ImageDiff {
	bool	bSameSize = false;
	double	fMeanAbs = 0;		// mean absolute difference over RGB channels, 0..255
	double	fFracOver = 0;		// fraction of pixels whose max RGB difference exceeds the threshold
	int		nMaxDiff = 0;		// largest channel difference
	int		nThreshold = 0;
};

// Copy a rectangle, clipped to the image.
ImageRGBA CropImage(const ImageRGBA& img, int x, int y, int w, int h);

// Compare RGB channels. Optionally writes a diff image (white = different).
ImageDiff CompareImages(const ImageRGBA& a, const ImageRGBA& b, int nThreshold,
	ImageRGBA* pDiff = nullptr);

} // namespace whorld
