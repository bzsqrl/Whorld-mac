# This file is part of Whorld for macOS, a port of Whorld by Chris Korda.
# Copyright 2026 Jeff Matson.
#
# This program is free software: you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by the Free
# Software Foundation, either version 3 of the License, or (at your option)
# any later version. See the LICENSE file at the repository root.

add_executable(test_tessellator test_tessellator.cpp)
target_link_libraries(test_tessellator PRIVATE whorld_gpu_geometry)
target_include_directories(test_tessellator PRIVATE ${PROJECT_SOURCE_DIR}/engine/tests ${CMAKE_CURRENT_SOURCE_DIR})
target_compile_options(test_tessellator PRIVATE -Wall -Wextra -Wpedantic)
add_test(NAME test_tessellator COMMAND test_tessellator)
