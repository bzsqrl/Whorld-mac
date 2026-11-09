// This file is part of Whorld for macOS, a port of Whorld by Chris Korda.
// Copyright 2026 Jeff Matson.
// Written with Claude (Anthropic).
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See the LICENSE file at the repository root.

#include "WHOscServer.h"

#include <arpa/inet.h>
#include <fcntl.h>
#include <netdb.h>
#include <sys/socket.h>
#include <unistd.h>

#include <algorithm>
#include <chrono>
#include <cstring>

double WHOscServer::Now()
{
	return std::chrono::duration<double>(std::chrono::steady_clock::now().time_since_epoch()).count();
}

bool WHOscServer::Start(int inPort, int outPort, const std::string& host, Receiver fn, std::string& error)
{
	Stop();
	if (inPort <= 0 || inPort > 65535 || outPort <= 0 || outPort > 65535) {
		error = "Ports must be from 1 to 65535.";
		return false;
	}
	m_host = 0;
	if (!host.empty()) {	// a name or a dotted address
		addrinfo	hints = {};
		hints.ai_family = AF_INET;
		hints.ai_socktype = SOCK_DGRAM;
		addrinfo	*res = nullptr;
		if (getaddrinfo(host.c_str(), nullptr, &hints, &res) != 0 || !res) {
			error = "Can't find the host \"" + host + "\".";
			return false;
		}
		m_host = reinterpret_cast<sockaddr_in*>(res->ai_addr)->sin_addr.s_addr;
		freeaddrinfo(res);
	}
	int	s = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
	if (s < 0) {
		error = std::string("Can't open a network socket: ") + std::strerror(errno);
		return false;
	}
	int	yes = 1;
	setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
	setsockopt(s, SOL_SOCKET, SO_BROADCAST, &yes, sizeof(yes));	// a broadcast address as the host
	sockaddr_in	a = {};
	a.sin_family = AF_INET;
	a.sin_port = htons(static_cast<uint16_t>(inPort));
	a.sin_addr.s_addr = htonl(INADDR_ANY);
	if (bind(s, reinterpret_cast<sockaddr*>(&a), sizeof(a)) != 0) {
		error = errno == EADDRINUSE
			? "Port " + std::to_string(inPort) + " is in use by another app."
			: std::string("Can't listen on port ") + std::to_string(inPort) + ": " + std::strerror(errno);
		close(s);
		return false;
	}
	fcntl(s, F_SETFL, fcntl(s, F_GETFL) | O_NONBLOCK);
	m_sock = s;
	m_outPort = outPort;
	m_fn = std::move(fn);
	m_queue = dispatch_queue_create("whorld.osc", DISPATCH_QUEUE_SERIAL);
	m_source = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, static_cast<uintptr_t>(s), 0, m_queue);
	dispatch_source_set_event_handler(m_source, ^{ OnReadable(); });
	dispatch_source_set_cancel_handler(m_source, ^{ close(s); });
	dispatch_resume(m_source);
	return true;
}

void WHOscServer::Stop()
{
	if (m_source) {
		dispatch_source_cancel(m_source);	// closes the socket
		m_source = nullptr;
	}
	if (m_queue) {
		dispatch_sync(m_queue, ^{});	// wait for a packet being handled
		m_queue = nullptr;
	}
	m_sock = -1;
	std::lock_guard<std::mutex>	lock(m_mutex);
	m_clients.clear();
}

void WHOscServer::OnReadable()
{
	uint8_t	buf[65536];
	for (;;) {
		sockaddr_in	from = {};
		socklen_t	len = sizeof(from);
		ssize_t	n = recvfrom(m_sock, buf, sizeof(buf), 0, reinterpret_cast<sockaddr*>(&from), &len);
		if (n <= 0)
			return;	// EAGAIN: all read
		auto	msgs = whorld::Osc::Decode(buf, static_cast<size_t>(n));
		if (msgs.empty())
			continue;
		{
			std::lock_guard<std::mutex>	lock(m_mutex);
			m_clients[from.sin_addr.s_addr] = Now();
		}
		if (m_fn)
			m_fn(msgs, from.sin_addr.s_addr);
	}
}

void WHOscServer::SendPacket(in_addr_t addr, const std::vector<uint8_t>& packet)
{
	if (m_sock < 0)
		return;
	sockaddr_in	to = {};
	to.sin_family = AF_INET;
	to.sin_port = htons(static_cast<uint16_t>(m_outPort));
	to.sin_addr.s_addr = addr;
	sendto(m_sock, packet.data(), packet.size(), 0, reinterpret_cast<sockaddr*>(&to), sizeof(to));
}

void WHOscServer::SendTo(in_addr_t addr, const whorld::OscMessage& msg)
{
	SendPacket(addr, whorld::Osc::Encode(msg));
}

void WHOscServer::Send(const whorld::OscMessage& msg)
{
	if (m_sock < 0)
		return;
	std::vector<in_addr_t>	to;
	{
		std::lock_guard<std::mutex>	lock(m_mutex);
		double	now = Now();
		for (auto it = m_clients.begin(); it != m_clients.end();) {
			if (now - it->second > kClientSeconds) {
				it = m_clients.erase(it);	// gone quiet
			} else {
				to.push_back(it->first);
				++it;
			}
		}
	}
	if (m_host && std::find(to.begin(), to.end(), m_host) == to.end())
		to.push_back(m_host);
	if (to.empty())
		return;
	auto	packet = whorld::Osc::Encode(msg);
	for (in_addr_t a : to)
		SendPacket(a, packet);
}

int WHOscServer::ClientCount()
{
	std::lock_guard<std::mutex>	lock(m_mutex);
	double	now = Now();
	int	n = 0;
	for (const auto& c : m_clients)
		n += now - c.second <= kClientSeconds;
	return n + (m_host != 0 && !m_clients.count(m_host));
}

std::vector<std::string> WHOscServer::ClientNames()
{
	std::lock_guard<std::mutex>	lock(m_mutex);
	double	now = Now();
	std::vector<std::string>	names;
	for (const auto& c : m_clients) {
		if (now - c.second <= kClientSeconds) {
			char	s[INET_ADDRSTRLEN];
			in_addr	a;
			a.s_addr = c.first;
			names.push_back(inet_ntop(AF_INET, &a, s, sizeof(s)));
		}
	}
	return names;
}
