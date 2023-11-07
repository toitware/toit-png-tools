# Copyright (C) 2023 Toitware ApS.
# Use of this source code is governed by an MIT-style license that can be
# found in the LICENSE file.

message("TPKG: ${TOITPKG}")
add_custom_target(
  "install-pkgs"
  COMMAND "${TOITPKG}" install
  WORKING_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}/../bin"
)

toit_project(pngtools "${CMAKE_CURRENT_LIST_DIR}")

set(PNGDIFF_SOURCE "${CMAKE_CURRENT_LIST_DIR}/pngdiff.toit")
set(PNGDIFF_EXE "${CMAKE_BINARY_DIR}/pngdiff${CMAKE_EXECUTABLE_SUFFIX}")
set(PNGDIFF_DEP "${CMAKE_CURRENT_BINARY_DIR}/pngdiff.dep")

ADD_TOIT_EXE(
  ${PNGDIFF_SOURCE}
  ${PNGDIFF_EXE}
  ${PNGDIFF_DEP}
  ""
)

set(PNGUNZIP_SOURCE "${CMAKE_CURRENT_LIST_DIR}/pngunzip.toit")
set(PNGUNZIP_EXE "${CMAKE_BINARY_DIR}/pngunzip${CMAKE_EXECUTABLE_SUFFIX}")
set(PNGUNZIP_DEP "${CMAKE_CURRENT_BINARY_DIR}/pngunzip.dep")

ADD_TOIT_EXE(
  ${PNGUNZIP_SOURCE}
  ${PNGUNZIP_EXE}
  ${PNGUNZIP_DEP}
  ""
)

add_custom_target(
  build_binaries
  DEPENDS ${PNGDIFF_EXE} ${PNGUNZIP_EXE}
)

add_dependencies(build build_binaries)
