# This file is part of Whorld for macOS, a port of Whorld by Chris Korda.
# Copyright 2026 Jeff Matson.
#
# This program is free software: you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by the Free
# Software Foundation, either version 3 of the License, or (at your option)
# any later version. See the LICENSE file at the repository root.

function(whorld_add_renderer_test name)
  add_executable(${name} ${name}.mm)
  target_link_libraries(${name} PRIVATE whorld_renderer)
  target_include_directories(${name} PRIVATE ${PROJECT_SOURCE_DIR}/engine/tests)
  target_compile_options(${name} PRIVATE -Wall -Wextra)
  target_compile_definitions(${name} PRIVATE
    WHORLD_TESTDATA_DIR="${PROJECT_SOURCE_DIR}/testdata")
  add_test(NAME ${name} COMMAND ${name})
endfunction()

whorld_add_renderer_test(test_cgrenderer)
whorld_add_renderer_test(test_golden)
