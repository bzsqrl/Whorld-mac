# This file is part of Whorld for macOS, a port of Whorld by Chris Korda.
# Copyright 2026 Jeff Matson.
# Written with Claude (Anthropic).
#
# This program is free software: you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by the Free
# Software Foundation, either version 3 of the License, or (at your option)
# any later version. See the LICENSE file at the repository root.

# Portable geometry for the GPU renderer: flattening, stroke and fill
# tessellation. Plain C++, built and tested on Linux too.
add_library(whorld_gpu_geometry STATIC Tessellator.cpp)
target_include_directories(whorld_gpu_geometry PUBLIC ${CMAKE_CURRENT_SOURCE_DIR}/..)
target_link_libraries(whorld_gpu_geometry PUBLIC whorld_engine)
target_compile_options(whorld_gpu_geometry PRIVATE -Wall -Wextra -Wpedantic)

add_subdirectory(tests)
