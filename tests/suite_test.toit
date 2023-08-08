// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by an MIT-style license that can be
// found in the TESTS_LICENSE file.

import expect show *
import host.directory show *
import host.file
import encoding.json
import png_reader show *

main:
  dir := DirectoryStream "tests/third_party/pngsuite/png"
  counter := 0
  while filename := dir.next:
    if filename.ends_with ".png":
      if filename.starts_with "x":
        continue  // Error PNGs.
      if filename[3] == 'i':
        continue  // Interlaced PNGs.
      print "$counter: $filename"
      counter++
      png := Png.from_file "tests/third_party/pngsuite/png/$filename"
      print png
      root := filename[..filename.size - 4]
      json_file := "tests/third_party/pngsuite/json/$(root).json"
      if not file.is_file json_file:
        continue  // No JSON file
      truncate := root.ends_with "16"
      json_in := file.read_content json_file
      parsed := json.parse json_in.to_string
      expect parsed is List
      byte_array := ByteArray parsed.size: truncate ? (parsed[it] >> 8) : parsed[it]
      expect_equals byte_array.size png.image_data.size
      byte_array.size.repeat:
        if byte_array[it] != png.image_data[it]:
          print "$filename differ at byte $it: expected 0x$(%02x byte_array[it]), got 0x$(%02x png.image_data[it])"
          return
      expect_equals byte_array      png.image_data
