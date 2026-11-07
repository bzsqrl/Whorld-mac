// Copyleft 2005 Chris Korda (original Oscillator.h)
// Port to macOS: Copyright 2026 Jeff Matson. Part of Whorld for macOS.
// Written with Claude (Anthropic).
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. The original Whorld source is licensed GPL version 2 or
// any later version. See the LICENSE file at the repository root.

#pragma once

// ported from Oscillator.h: general-purpose waveform generator

#include "whorld/Types.h"

namespace whorld {

class Oscillator {
public:
// Constants
	enum WAVEFORM {
		TRIANGLE,
		SINE,
		RAMP_UP,
		RAMP_DOWN,
		SQUARE,
		PULSE,
		RANDOM,
		RANDOM_RAMP,
		WAVEFORMS
	};

// Construction
	Oscillator();
	Oscillator(double fTimerFreq, int nWaveform, double fFreq);

// Attributes
	double	GetTimerFreq() const;
	void	SetTimerFreq(double fTimerFreq);	// in Hz
	int		GetWaveform() const;
	void	SetWaveform(int nWaveform);
	double	GetFreq() const;
	void	SetFreq(double fFreq);		// doesn't change phase, but loses sync
	void	SetFreqSync(double fFreq);	// stays in sync, but changes phase
	double	GetPulseWidth() const;
	void	SetPulseWidth(double fPulseWidth);	// 0..1, 1 = 100% duty
	double	GetClock() const;
	void	SetClock(double fClock);	// in ticks
	double	GetPhase() const;	// 0..1, 1 = 360 degrees
	void	SetPhase(double fPhase);		// 0..1, 1 = 360 degrees
	void	SetPhaseFromVal(double fVal);	// -1..1
	double	GetVal();	// -1..1

// Operations
	void	TimerHook();

protected:
// Member data
	double	m_fTimerFreq;	// frequency at which timer hook runs, in Hz
	int		m_nWaveform;	// type of waveform to generate; see enum above
	double	m_fFreq;		// output frequency, in Hz
	double	m_fPulseWidth;	// for pulse waveform: pulse duty cycle, from 0..1
	double	m_fRandPrvPhase;	// for random waveform: previous tick's phase
	double	m_fRandCurVal;	// for random waveform: current random value
	double	m_fRandPrvVal;	// for random waveform: previous random value
	double	m_fClock;		// clock tick count; fractional ticks allowed

// Helpers
	void	Init();
	double	CurPos() const;
	double	CurPhase() const;
	void	Resync(double fPhase);
};

inline double Oscillator::GetTimerFreq() const
{
	return m_fTimerFreq;
}

inline void Oscillator::SetTimerFreq(double fTimerFreq)
{
	m_fTimerFreq = fTimerFreq;
}

inline int Oscillator::GetWaveform() const
{
	return m_nWaveform;
}

inline void Oscillator::SetWaveform(int nWaveform)
{
	m_nWaveform = nWaveform;
}

inline double Oscillator::GetFreq() const
{
	return m_fFreq;
}

inline void Oscillator::SetFreq(double fFreq)
{
	double	fPhase = CurPhase();
	m_fFreq = fFreq;
	Resync(fPhase);
}

inline void Oscillator::SetFreqSync(double fFreq)
{
	m_fFreq = fFreq;
}

inline double Oscillator::GetPulseWidth() const
{
	return m_fPulseWidth;
}

inline void Oscillator::SetPulseWidth(double fPulseWidth)
{
	m_fPulseWidth = fPulseWidth;
}

inline double Oscillator::GetClock() const
{
	return m_fClock;
}

inline void Oscillator::SetClock(double fClock)
{
	m_fClock = fClock;
}

inline double Oscillator::GetPhase() const
{
	return CurPhase();
}

inline void Oscillator::SetPhase(double fPhase)
{
	Resync(fPhase);
}

inline void Oscillator::TimerHook()
{
	m_fClock++;
}

inline double Oscillator::CurPos() const
{
	return m_fFreq / m_fTimerFreq * m_fClock;
}

inline void Oscillator::Resync(double fPhase)
{
	m_fClock = m_fFreq ? fPhase * (m_fTimerFreq / m_fFreq) : 0;
}

// ported from Oscillator.h CTriggerOscillator
class TriggerOscillator : public Oscillator {
public:
	TriggerOscillator();
	TriggerOscillator(double fTimerFreq, double fFreq);
	bool	IsTrigger();
	void	Reset();

protected:
	// The original default constructor leaves this uninitialized, which is
	// undefined behavior in C++; initialized here. See "Upstream notes".
	bool	m_bIsHigh = false;	// true if previous output was high
};

inline TriggerOscillator::TriggerOscillator()
{
}

inline TriggerOscillator::TriggerOscillator(double fTimerFreq, double fFreq)
	: Oscillator(fTimerFreq, SQUARE, fFreq)
{
	m_bIsHigh = false;
}

inline bool TriggerOscillator::IsTrigger()
{
	TimerHook();
	bool	bIsHigh = GetVal() >= 1 - DPoint::m_fEpsilon;	// true if output is high
	bool	bIsTrigger = bIsHigh && !m_bIsHigh;	// true if transition from low to high
	m_bIsHigh = bIsHigh;	// update previous output state
	return bIsTrigger;
}

inline void TriggerOscillator::Reset()
{
	SetClock(0);
	m_bIsHigh = false;
}

} // namespace whorld
