# Copyright (C) 2023 Toitware ApS.
# Use of this source code is governed by an MIT-style license that can be
# found in the LICENSE file.

# This file serves as normal cmake include, as well as a cmake-script, run with
# `cmake -P`.
# In the latter case the `EXECUTING_SCRIPT` variable is defined, and we only
# process the command that we should execute.
set(TOIT_DOWNLOAD_PACKAGE_SCRIPT "${CMAKE_CURRENT_LIST_DIR}/toit.cmake")
if (DEFINED EXECUTING_SCRIPT)
  if ("${SCRIPT_COMMAND}" STREQUAL "install_packages")
    if (NOT DEFINED TOIT_PROJECT)
      message(FATAL_ERROR "Missing TOIT_PROJECT")
    endif()
    if (NOT DEFINED TOIT)
      message(FATAL_ERROR "Missing TOIT")
    endif()

    if (EXISTS "${TOIT_PROJECT}/package.yaml" OR EXISTS "${TOIT_PROJECT}/package.lock")
      execute_process(
        COMMAND "${TOIT}" pkg install --auto-sync=false "--project-root=${TOIT_PROJECT}"
        COMMAND_ERROR_IS_FATAL ANY
      )
    endif()
  else()
    message(FATAL_ERROR "Unknown script command ${SCRIPT_COMMAND}")
  endif()

  # End the execution of this file.
  return()
endif()

# Creates a custom command to build ${TARGET} with correct dependencies.
function(ADD_TOIT_SNAPSHOT SOURCE TARGET DEP_FILE ENV)
  if (NOT DEFINED TOIT)
    set(TOIT "$ENV{TOIT}")
    if ("${TOIT}" STREQUAL "")
      # TOIT is normally set to the toit executable.
      # However, for cross-compilation the compiler must be provided manually.
      message(FATAL_ERROR "TOIT not provided")
    endif()
  endif()
  if(POLICY CMP0116)
    cmake_policy(SET CMP0116 NEW)
  endif()
  add_custom_command(
    OUTPUT "${TARGET}"
    DEPFILE ${DEP_FILE}
    DEPENDS download_packages "${SOURCE}"
    COMMAND ${CMAKE_COMMAND} -E env ${ENV} ASAN_OPTIONS=detect_leaks=false
        "${TOIT}" compile
        --snapshot
        --dependency-file "${DEP_FILE}"
        --dependency-format ninja
        -o "${TARGET}"
        "${SOURCE}"
  )
endfunction(ADD_TOIT_SNAPSHOT)

# Creates a custom command to build ${TARGET} with correct dependencies.
function(ADD_TOIT_EXE SOURCE TARGET DEP_FILE ENV)
  if (NOT DEFINED TOIT)
    set(TOITC "$ENV{TOIT}")
    if ("${TOIT}" STREQUAL "")
      # TOIT is normally set to the toit executable.
      # However, for cross-compilation the compiler must be provided manually.
      message(FATAL_ERROR "TOIT not provided")
    endif()
  endif()
  if(POLICY CMP0116)
    cmake_policy(SET CMP0116 NEW)
  endif()
  add_custom_command(
    OUTPUT "${TARGET}"
    DEPFILE ${DEP_FILE}
    DEPENDS download_packages "${SOURCE}"
    COMMAND ${CMAKE_COMMAND} -E env ${ENV} ASAN_OPTIONS=detect_leaks=false
        "${TOIT}" compile
        --dependency-file "${DEP_FILE}"
        --dependency-format ninja
        -o "${TARGET}"
        "${SOURCE}"
  )
endfunction(ADD_TOIT_EXE)

macro(toit_project NAME PATH)
  if (NOT DEFINED TOIT)
    set(TOIT "$ENV{TOIT}")
    if ("${TOIT}" STREQUAL "")
      # TOIT is normally set to the toit executable.
      # However, for cross-compilation the compiler must be provided manually.
      message(FATAL_ERROR "TOIT not provided")
    endif()
  endif()

  if (NOT TARGET download_packages)
    add_custom_target(
      download_packages
    )
    add_custom_target(
      sync_packages
      COMMAND "${TOIT}" pkg sync
    )
  endif()

  set(DOWNLOAD_TARGET_NAME "download-${NAME}-packages")
  add_custom_target(
    "${DOWNLOAD_TARGET_NAME}"
    COMMAND "${CMAKE_COMMAND}"
        -DEXECUTING_SCRIPT=true
        -DSCRIPT_COMMAND=install_packages
        "-DTOIT_PROJECT=${PATH}"
        "-DTOIT=${TOIT}"
        -P "${TOIT_DOWNLOAD_PACKAGE_SCRIPT}"
  )
  add_dependencies(download_packages "${DOWNLOAD_TARGET_NAME}")
  add_dependencies("${DOWNLOAD_TARGET_NAME}" sync_packages)
endmacro()
