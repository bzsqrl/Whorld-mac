// This file is part of Whorld for macOS, a port of Whorld by Chris Korda.
// Copyright 2026 Jeff Matson.
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See the LICENSE file at the repository root.

#include "ImageCompare.h"

#include <CoreGraphics/CoreGraphics.h>
#include <ImageIO/ImageIO.h>

#include <algorithm>
#include <cmath>
#include <cstdlib>

namespace whorld {

namespace {
CFURLRef MakeURL(const std::string& sPath)
{
	CFStringRef	path = CFStringCreateWithCString(nullptr, sPath.c_str(), kCFStringEncodingUTF8);
	CFURLRef	url = CFURLCreateWithFileSystemPath(nullptr, path, kCFURLPOSIXPathStyle, false);
	CFRelease(path);
	return url;
}
bool Fail(std::string* pError, const std::string& sMsg)
{
	if (pError)
		*pError = sMsg;
	return false;
}
} // namespace

bool LoadImageRGBA(const std::string& sPath, ImageRGBA& img, std::string* pError)
{
	CFURLRef	url = MakeURL(sPath);
	CGImageSourceRef	src = CGImageSourceCreateWithURL(url, nullptr);
	CFRelease(url);
	if (!src)
		return Fail(pError, "Can't open image: " + sPath);
	CGImageRef	image = CGImageSourceCreateImageAtIndex(src, 0, nullptr);
	CFRelease(src);
	if (!image)
		return Fail(pError, "Can't decode image: " + sPath);
	size_t	bpc = CGImageGetBitsPerComponent(image);
	size_t	bpp = CGImageGetBitsPerPixel(image);
	CGBitmapInfo	info = CGImageGetBitmapInfo(image);
	CGImageAlphaInfo	alpha = CGImageGetAlphaInfo(image);
	if (bpc != 8 || (bpp != 32 && bpp != 24)) {
		CGImageRelease(image);
		return Fail(pError, "Unsupported pixel format: " + sPath);
	}
	CFDataRef	data = CGDataProviderCopyData(CGImageGetDataProvider(image));
	const uint8_t*	p = CFDataGetBytePtr(data);
	size_t	stride = CGImageGetBytesPerRow(image);
	img.nWidth = static_cast<int>(CGImageGetWidth(image));
	img.nHeight = static_cast<int>(CGImageGetHeight(image));
	img.aPixel.assign(static_cast<size_t>(img.nWidth) * img.nHeight * 4, 255);
	bool	bLittle = (info & kCGBitmapByteOrderMask) == kCGBitmapByteOrder32Little;
	bool	bAlphaFirst = alpha == kCGImageAlphaFirst || alpha == kCGImageAlphaPremultipliedFirst
		|| alpha == kCGImageAlphaNoneSkipFirst;
	bool	bHasAlpha = alpha != kCGImageAlphaNone && alpha != kCGImageAlphaNoneSkipFirst
		&& alpha != kCGImageAlphaNoneSkipLast;
	for (int y = 0; y < img.nHeight; y++) {
		for (int x = 0; x < img.nWidth; x++) {
			const uint8_t*	s = p + y * stride + x * (bpp / 8);
			uint8_t	c[4];
			if (bpp == 24) {
				c[0] = s[0]; c[1] = s[1]; c[2] = s[2]; c[3] = 255;
			} else {
				uint8_t	b[4] = {s[0], s[1], s[2], s[3]};
				if (bLittle)
					std::reverse(b, b + 4);	// to big-endian component order
				if (bAlphaFirst) {
					c[3] = b[0]; c[0] = b[1]; c[1] = b[2]; c[2] = b[3];
				} else {
					c[0] = b[0]; c[1] = b[1]; c[2] = b[2]; c[3] = b[3];
				}
				if (!bHasAlpha)
					c[3] = 255;
			}
			uint8_t*	d = &img.aPixel[(static_cast<size_t>(y) * img.nWidth + x) * 4];
			d[0] = c[0]; d[1] = c[1]; d[2] = c[2]; d[3] = c[3];
		}
	}
	CFRelease(data);
	CGImageRelease(image);
	return true;
}

ImageRGBA FromBGRA(const uint8_t* pPixels, int nWidth, int nHeight, size_t nStride)
{
	ImageRGBA	img;
	img.nWidth = nWidth;
	img.nHeight = nHeight;
	img.aPixel.resize(static_cast<size_t>(nWidth) * nHeight * 4);
	for (int y = 0; y < nHeight; y++) {
		for (int x = 0; x < nWidth; x++) {
			const uint8_t*	s = pPixels + y * nStride + x * 4;	// B G R A
			uint8_t*	d = &img.aPixel[(static_cast<size_t>(y) * nWidth + x) * 4];
			d[0] = s[2]; d[1] = s[1]; d[2] = s[0]; d[3] = s[3];
		}
	}
	return img;
}

bool SaveImageRGBA(const std::string& sPath, const ImageRGBA& img, std::string* pError)
{
	CGColorSpaceRef	space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
	CFDataRef	data = CFDataCreate(nullptr, img.aPixel.data(), img.aPixel.size());
	CGDataProviderRef	provider = CGDataProviderCreateWithCFData(data);
	CGImageRef	image = CGImageCreate(img.nWidth, img.nHeight, 8, 32, img.nWidth * 4, space,
		kCGImageAlphaLast | kCGBitmapByteOrderDefault, provider, nullptr, false, kCGRenderingIntentDefault);
	CGDataProviderRelease(provider);
	CFRelease(data);
	CGColorSpaceRelease(space);
	if (!image)
		return Fail(pError, "Can't create image.");
	CFURLRef	url = MakeURL(sPath);
	CGImageDestinationRef	dest = CGImageDestinationCreateWithURL(url, CFSTR("public.png"), 1, nullptr);
	CFRelease(url);
	bool	bOk = false;
	if (dest) {
		CGImageDestinationAddImage(dest, image, nullptr);
		bOk = CGImageDestinationFinalize(dest);
		CFRelease(dest);
	}
	CGImageRelease(image);
	return bOk ? true : Fail(pError, "Can't write image: " + sPath);
}

ImageRGBA CropImage(const ImageRGBA& img, int x, int y, int w, int h)
{
	ImageRGBA	out;
	int	x0 = std::max(0, x), y0 = std::max(0, y);
	int	x1 = std::min(img.nWidth, x + w), y1 = std::min(img.nHeight, y + h);
	out.nWidth = std::max(0, x1 - x0);
	out.nHeight = std::max(0, y1 - y0);
	out.aPixel.resize(static_cast<size_t>(out.nWidth) * out.nHeight * 4);
	for (int yy = 0; yy < out.nHeight; yy++) {
		const uint8_t*	s = &img.aPixel[(static_cast<size_t>(y0 + yy) * img.nWidth + x0) * 4];
		std::copy(s, s + out.nWidth * 4, &out.aPixel[static_cast<size_t>(yy) * out.nWidth * 4]);
	}
	return out;
}

ImageDiff CompareImages(const ImageRGBA& a, const ImageRGBA& b, int nThreshold, ImageRGBA* pDiff)
{
	ImageDiff	d;
	d.nThreshold = nThreshold;
	d.bSameSize = a.nWidth == b.nWidth && a.nHeight == b.nHeight;
	if (!d.bSameSize)
		return d;
	size_t	nPixels = static_cast<size_t>(a.nWidth) * a.nHeight;
	if (pDiff) {
		pDiff->nWidth = a.nWidth;
		pDiff->nHeight = a.nHeight;
		pDiff->aPixel.assign(nPixels * 4, 255);
	}
	double	fSum = 0;
	size_t	nOver = 0;
	for (size_t i = 0; i < nPixels; i++) {
		int	nMax = 0;
		for (int c = 0; c < 3; c++) {
			int	nDiff = std::abs(int(a.aPixel[i * 4 + c]) - int(b.aPixel[i * 4 + c]));
			fSum += nDiff;
			nMax = std::max(nMax, nDiff);
		}
		d.nMaxDiff = std::max(d.nMaxDiff, nMax);
		if (nMax > nThreshold)
			nOver++;
		if (pDiff) {
			uint8_t	v = static_cast<uint8_t>(std::min(255, nMax * 4));
			uint8_t*	p = &pDiff->aPixel[i * 4];
			p[0] = v; p[1] = v; p[2] = v; p[3] = 255;
		}
	}
	d.fMeanAbs = fSum / (nPixels * 3.0);
	d.fFracOver = double(nOver) / nPixels;
	return d;
}

} // namespace whorld
