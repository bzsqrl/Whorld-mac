// This file is part of Whorld for macOS, a port of Whorld by Chris Korda.
// Copyleft 2025 Chris Korda (original Whorld); port Copyright 2026 Jeff Matson.
// Written with Claude (Anthropic).
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See the LICENSE file at the repository root.

#pragma once

namespace whorld {

// Version of the macOS engine library (not the Windows Whorld version).
const char* EngineVersion();

// Upstream Whorld version this port is based on.
const char* UpstreamBaseline();

} // namespace whorld
