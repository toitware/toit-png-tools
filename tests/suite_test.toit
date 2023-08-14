// Copyright (C) 2023 Toitware ApS.
// Use of this source code is governed by an MIT-style license that can be
// found in the TESTS_LICENSE file.

import expect show *
import host.directory show *
import host.file
import encoding.json
import png-reader show *

main:
  dir := DirectoryStream "tests/third_party/pngsuite/png"
  counter := 0
  while filename := dir.next:
    if filename.ends-with ".png":
      if filename.starts-with "x":
        continue  // Error PNGs.
      if filename[3] == 'i':
        continue  // Interlaced PNGs.
      print "$counter: $filename"
      counter++
      png := Png.from-file "tests/third_party/pngsuite/png/$filename"
      print png
      root := filename[..filename.size - 4]
      json-file := "tests/third_party/pngsuite/json/$(root).json"
      if not file.is-file json-file:
        continue  // No JSON file
      truncate := root.ends-with "16"
      json-in := file.read-content json-file
      parsed := json.parse json-in.to-string
      expect parsed is List
      byte-array := ByteArray parsed.size: truncate ? (parsed[it] >> 8) : parsed[it]
      expect-equals byte-array.size png.image-data.size
      byte-array.size.repeat:
        if byte-array[it] != png.image-data[it]:
          print "$filename differ at byte $it: expected 0x$(%02x byte-array[it]), got 0x$(%02x png.image-data[it])"
          return
      expect-equals byte-array      png.image-data
