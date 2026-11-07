// Copyleft 2005 Chris Korda (original Oscillator.cpp)
// Port to macOS: Copyright 2026 Jeff Matson. Part of Whorld for macOS.
// Written with Claude (Anthropic).
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. The original Whorld source is licensed GPL version 2 or
// any later version. See the LICENSE file at the repository root.

#include "whorld/Oscillator.h"
#include "whorld/Random.h"

#include <cmath>

namespace whorld {

// ported from Oscillator.cpp COscillator::COscillator
Oscillator::Oscillator()
{
	Init();
}

Oscillator::Oscillator(double fTimerFreq, int nWaveform, double fFreq)
{
	Init();
	m_fTimerFreq = fTimerFreq;
	m_nWaveform = nWaveform;
	m_fFreq = fFreq;
}

// ported from Oscillator.cpp COscillator::Init
void Oscillator::Init()
{
	m_fTimerFreq = 0;
	m_nWaveform = 0;
	m_fFreq = 0;
	m_fPulseWidth = 0.5;
	m_fRandPrvPhase = 0;
	m_fRandCurVal = 0;
	m_fRandPrvVal = 0;
	m_fClock = 0;
}

// ported from Oscillator.cpp COscillator::CurPhase
double Oscillator::CurPhase() const
{
	return std::fmod(CurPos(), 1);
}

// ported from Oscillator.cpp COscillator::SetPhaseFromVal
void Oscillator::SetPhaseFromVal(double fVal)
{
	double	r;
	switch (m_nWaveform) {
	case TRIANGLE:
		r = (fVal + 1) / 2 + 10.5;
		break;
	case SINE:
		r = std::asin(fVal) / kPi;
		break;
	case RAMP_UP:
		r = fVal + 1;
		break;
	case RAMP_DOWN:
		r = 1 - fVal;
		break;
	case SQUARE:
	case PULSE:
		r = (fVal + 1) / 2 + 1;
		break;
	default:
		r = 0;
	}
	SetPhase(r / 2);
}

// ported from Oscillator.cpp COscillator::GetVal
double Oscillator::GetVal()
{
	double	r;
	switch (m_nWaveform) {
	case TRIANGLE:
		r = std::fmod(CurPos() * 2 + 0.5, 2);
		r = r < 1 ? r * 2 - 1 : 3 - r * 2;
		break;
	case SINE:
		r = std::sin(CurPos() * kPi * 2);
		break;
	case RAMP_UP:
		r = CurPhase() * 2 - 1;
		break;
	case RAMP_DOWN:
		r = 1 - CurPhase() * 2;
		break;
	case SQUARE:
		r = CurPhase() < 0.5 ? 1 : -1;
		break;
	case PULSE:
		r = CurPhase() < m_fPulseWidth ? 1 : -1;
		break;
	case RANDOM:
		r = CurPhase();
		if (r < 0.5 && m_fRandPrvPhase > 0.5)
			m_fRandCurVal = double(whorld::rand()) / kRandMax * 2 - 1;
		m_fRandPrvPhase = r;
		r = m_fRandCurVal;
		break;
	case RANDOM_RAMP:
		r = CurPhase();
		if (r < 0.5 && m_fRandPrvPhase > 0.5) {
			m_fRandPrvVal = m_fRandCurVal;
			m_fRandCurVal = double(whorld::rand()) / kRandMax * 2 - 1;
		}
		m_fRandPrvPhase = r;
		r = m_fRandPrvVal + (m_fRandCurVal - m_fRandPrvVal) * r;
		break;
	default:
		r = 0;
	}
	return r;
}

} // namespace whorld
