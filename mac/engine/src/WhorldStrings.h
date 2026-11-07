// Copyleft 2025 Chris Korda (original Whorld.rc string table)
// Port to macOS: Copyright 2026 Jeff Matson. Part of Whorld for macOS.
// Written with Claude (Anthropic).
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. The original Whorld source is licensed GPL version 2 or
// any later version. See the LICENSE file at the repository root.

#pragma once

// English display names from the string table in Whorld.rc, for the
// string resource IDs referenced by WhorldBase. The Windows build loads
// these with CString::LoadString; here they are compile-time strings.
// No include guard needed beyond pragma once; macros only.

#define IDS_PARAM_RingGrowth	"Ring Growth"
#define IDS_PARAM_RingSpacing	"Ring Spacing"
#define IDS_PARAM_LineWidth		"Line Width"
#define IDS_PARAM_PolySides		"Ring Sides"
#define IDS_PARAM_RotateSpeed	"Rotate Speed"
#define IDS_PARAM_AspectRatio	"Aspect Ratio"
#define IDS_PARAM_SkewRadius	"Skew Radius"
#define IDS_PARAM_SkewAngle		"Skew Angle"
#define IDS_PARAM_StarFactor	"Star Factor"
#define IDS_PARAM_Pinwheel		"Pinwheel"
#define IDS_PARAM_ColorSpeed	"Color Speed"
#define IDS_PARAM_Lightness		"Lightness"
#define IDS_PARAM_Saturation	"Saturation"
#define IDS_PARAM_Alpha			"Alpha"
#define IDS_PARAM_BkHue			"Bk Hue"
#define IDS_PARAM_BkLightness	"Bk Lightness"
#define IDS_PARAM_BkSaturation	"Bk Saturation"
#define IDS_PARAM_BkAlpha		"Bk Alpha"
#define IDS_PARAM_EvenCurve		"Even Curve"
#define IDS_PARAM_OddCurve		"Odd Curve"
#define IDS_PARAM_EvenShear		"Even Shear"
#define IDS_PARAM_OddShear		"Odd Shear"

#define IDS_PROW_Val			"Value"
#define IDS_PROW_Wave			"Waveform"
#define IDS_PROW_Amp			"Amplitude"
#define IDS_PROW_Freq			"Frequency"
#define IDS_PROW_PW				"Pulse Width"
#define IDS_PROW_Global			"Global"

#define IDS_MASTER_Speed		"Speed"
#define IDS_MASTER_Zoom			"Zoom"
#define IDS_MASTER_Damping		"Damping"
#define IDS_MASTER_Trail		"Trail"
#define IDS_MASTER_Rings		"Rings"
#define IDS_MASTER_Tempo		"Tempo"
#define IDS_MASTER_HueSpan		"Hue Span"
#define IDS_MASTER_CanvasScale	"Canvas"
#define IDS_MASTER_Copies		"Copies"
#define IDS_MASTER_Spread		"Spread"

#define IDS_MAIN_Origin			"Origin"
#define IDS_MAIN_DrawMode		"Draw Mode"
#define IDS_MAIN_OrgMotion		"Origin Motion"
#define IDS_MAIN_Hue			"Hue"
#define IDS_MAIN_Mirror			"Mirror"
#define IDS_MAIN_Reverse		"Reverse"
#define IDS_MAIN_Convex			"Convex"
#define IDS_MAIN_InvertColor	"Invert Color"
#define IDS_MAIN_LoopHue		"Loop Hue"
#define IDS_MAIN_ZoomCenter		"Zoom Center"
#define IDS_MAIN_Antialiasing	"Antialiasing"

#define IDS_WAVE_TRIANGLE		"Triangle"
#define IDS_WAVE_SINE			"Sine"
#define IDS_WAVE_RAMP_UP		"Ramp Up"
#define IDS_WAVE_RAMP_DOWN		"Ramp Down"
#define IDS_WAVE_SQUARE			"Square"
#define IDS_WAVE_PULSE			"Pulse"
#define IDS_WAVE_RANDOM			"Random"
#define IDS_WAVE_RANDOM_RAMP	"Rand Ramp"
