# This file is part of Whorld for macOS, a port of Whorld by Chris Korda.
# Copyright 2026 Jeff Matson.
#
# This program is free software: you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by the Free
# Software Foundation, either version 3 of the License, or (at your option)
# any later version. See the LICENSE file at the repository root.

add_executable(whorld-render whorld-render.mm)
target_link_libraries(whorld-render PRIVATE whorld_renderer)
target_compile_options(whorld-render PRIVATE -Wall -Wextra)
