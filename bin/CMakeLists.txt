# Copyright (C) 2023 Toitware ApS.
# Use of this source code is governed by an MIT-style license that can be
# found in the LICENSE file.

message("TPKG: ${TPKG_EXEC}")
add_custom_target(
  "install-pkgs"
  COMMAND "${TPKG_EXEC}" install
  WORKING_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}/../bin"
)
