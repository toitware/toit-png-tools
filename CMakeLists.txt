# Copyright (C) 2023 Toitware ApS.
# Use of this source code is governed by a Zero-Clause BSD license that can
# be found in the tests/TESTS_LICENSE file.

cmake_minimum_required(VERSION 3.22)

# NONE means skip testing the C compiler.
project(pngdiff NONE)

set(TOIT
    "toit${CMAKE_EXECUTABLE_SUFFIX}"
    CACHE
    FILEPATH
    "The executable used to run, compile programs and install packages")

set(DEFAULT_SDK_VERSION CACHE STRING "The default SDK version to use")

set(GIT_VERSION "$ENV{GIT_VERSION}")
if ("${GIT_VERSION}" STREQUAL "")
  include(tools/gitversion.cmake)
  # The Git version is only computed when cmake generates the Ninja files, but
  # that should be good enough.
  compute_git_version(GIT_VERSION)
endif()

# Replace the version in bin/version.toit.
configure_file(
  bin/version.toit.in
  ${CMAKE_CURRENT_SOURCE_DIR}/bin/version.toit
  @ONLY)

include("tools/toit.cmake")

add_custom_target(build)

enable_testing()
add_subdirectory(tests)
add_subdirectory(bin)
