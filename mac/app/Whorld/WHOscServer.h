// This file is part of Whorld for macOS, a port of Whorld by Chris Korda.
// Copyright 2026 Jeff Matson.
// Written with Claude (Anthropic).
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See the LICENSE file at the repository root.

#pragma once

// OSC over UDP (new in the Mac port): listens on one port, and sends to
// every IPv4 address that has sent it something in the last 30 seconds (a
// TouchOSC layout pings every second) on the send port, plus an optional
// fixed host (for a monitor that never sends). Messages arrive on a queue
// of its own; Send may be called from any thread.

#include "whorld/Osc.h"

#include <dispatch/dispatch.h>
#include <netinet/in.h>

#include <functional>
#include <map>
#include <mutex>
#include <string>
#include <vector>

class WHOscServer {
public:
	// Called on the server's queue with each packet's messages and the
	// sender's IPv4 address (network byte order).
	using Receiver = std::function<void(const std::vector<whorld::OscMessage>&, in_addr_t sender)>;

	~WHOscServer() { Stop(); }

	// Listens on inPort (all interfaces) and sends to outPort; host: also
	// send there (a name or address; empty for none). On failure returns
	// false with a reason.
	bool	Start(int inPort, int outPort, const std::string& host, Receiver fn, std::string& error);
	void	Stop();
	bool	IsRunning() const { return m_sock >= 0; }

	void	Send(const whorld::OscMessage& msg);	// to everyone listening
	void	SendTo(in_addr_t addr, const whorld::OscMessage& msg);	// one address, on the send port
	int		ClientCount();	// addresses heard from in the last 30 seconds
	std::vector<std::string>	ClientNames();

private:
	static constexpr double	kClientSeconds = 30;
	int		m_sock = -1;
	int		m_outPort = 0;
	in_addr_t	m_host = 0;		// the fixed host, or 0
	dispatch_queue_t	m_queue = nullptr;
	dispatch_source_t	m_source = nullptr;
	Receiver	m_fn;
	std::mutex	m_mutex;	// guards m_clients
	std::map<in_addr_t, double>	m_clients;	// address -> last heard (seconds)

	void	OnReadable();
	void	SendPacket(in_addr_t addr, const std::vector<uint8_t>& packet);
	static double	Now();
};
