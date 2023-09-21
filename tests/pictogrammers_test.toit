// Copyright (C) 2023 Toitware ApS.
// Use of this source code is governed by an MIT-style license that can be
// found in the TESTS_LICENSE file.

import expect show *
import host.directory show *
import host.file
import png-reader show *

main:
  dir := DirectoryStream "tests/third_party/pictogrammers/compressed"
  counter := 0
  while filename := dir.next:
    if filename.ends-with ".png":
      print "$counter: $filename"
      counter++
      png := Png.from-file "tests/third_party/pictogrammers/compressed/$filename"
      print png
