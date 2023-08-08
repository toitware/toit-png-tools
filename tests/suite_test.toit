// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by an MIT-style license that can be
// found in the TESTS_LICENSE file.

import png_reader show *
import host.directory show *

main:
  dir := DirectoryStream "tests/third_party/pngsuite/png"
  while filename := dir.next:
    if filename.ends_with ".png":
      if filename.starts_with "x":
        continue  // Error PNGs.
      if filename[3] == 'i':
        continue  // Interlaced PNGs.
      print filename
      png := Png.from_file "tests/third_party/pngsuite/png/$filename"
      print png
