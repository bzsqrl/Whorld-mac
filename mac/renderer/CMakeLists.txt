# This file is part of Whorld for macOS, a port of Whorld by Chris Korda.
# Copyright 2026 Jeff Matson.
# Written with Claude (Anthropic).
#
# This program is free software: you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by the Free
# Software Foundation, either version 3 of the License, or (at your option)
# any later version. See the LICENSE file at the repository root.

# Core Graphics renderer (macOS only).
add_library(whorld_renderer STATIC
  CGRenderer.mm
  ImageCompare.mm
  RenderJobs.mm
  VideoWriter.mm
  MetalRenderer.mm
)
target_include_directories(whorld_renderer PUBLIC ${CMAKE_CURRENT_SOURCE_DIR})
target_link_libraries(whorld_renderer PUBLIC whorld_engine whorld_gpu_geometry
  "-framework CoreGraphics" "-framework ImageIO" "-framework CoreFoundation"
  "-framework AVFoundation" "-framework CoreVideo" "-framework CoreMedia" "-framework Foundation" "-framework Metal" "-framework IOSurface")
target_compile_options(whorld_renderer PRIVATE -Wall -Wextra $<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>)

add_subdirectory(tests)
