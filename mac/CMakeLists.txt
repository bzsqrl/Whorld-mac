# This file is part of Whorld for macOS, a port of Whorld by Chris Korda.
# Copyleft 2025 Chris Korda (original Whorld); port Copyright 2026 Jeff Matson.
# Written with Claude (Anthropic).
#
# This program is free software: you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by the Free
# Software Foundation, either version 3 of the License, or (at your option)
# any later version. See the LICENSE file at the repository root.

cmake_minimum_required(VERSION 3.20)
project(WhorldMac VERSION 0.1.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
  set(CMAKE_BUILD_TYPE Debug CACHE STRING "Build type" FORCE)
endif()

enable_testing()

add_subdirectory(engine)
add_subdirectory(renderer/gpu)	# portable geometry for the Metal renderer

# The Core Graphics renderer, tools and golden-image tests need macOS.
if(APPLE)
  enable_language(OBJCXX)
  set(CMAKE_OBJCXX_STANDARD 17)
  set(CMAKE_OBJCXX_STANDARD_REQUIRED ON)
  add_subdirectory(renderer)
  add_subdirectory(tools)
endif()
