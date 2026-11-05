# This file is part of Whorld for macOS, a port of Whorld by Chris Korda.
# Copyleft 2025 Chris Korda (original Whorld); port Copyright 2026 Jeff Matson.
#
# This program is free software: you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by the Free
# Software Foundation, either version 3 of the License, or (at your option)
# any later version. See the LICENSE file at the repository root.

# Each test file is one executable registered with CTest.
function(whorld_add_test name)
  add_executable(${name} ${name}.cpp)
  target_link_libraries(${name} PRIVATE whorld_engine)
  target_include_directories(${name} PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})
  target_compile_options(${name} PRIVATE -Wall -Wextra -Wpedantic)
  target_compile_definitions(${name} PRIVATE
    WHORLD_TESTDATA_DIR="${PROJECT_SOURCE_DIR}/testdata")
  add_test(NAME ${name} COMMAND ${name})
endfunction()

whorld_add_test(test_version)
whorld_add_test(test_basics)
whorld_add_test(test_whorldbase)
whorld_add_test(test_oscillator)
whorld_add_test(test_utilities)
whorld_add_test(test_patch)
whorld_add_test(test_snapshot)
