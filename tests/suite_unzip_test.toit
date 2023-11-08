// Copyright (C) 2023 Toitware ApS.
// Use of this source code is governed by an MIT-style license that can be
// found in the TESTS_LICENSE file.

import expect show *
import host.directory show *
import host.file
import host.pipe
import encoding.json
import png-tools.png-reader show *

main args/List:
  if not file.is-directory "tests/out":
    mkdir "tests/out"
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
      path := "tests/third_party/pngsuite/png/$filename"
      args1 := ["./build/pngunzip", "-o", "tests/out/unzip-$filename", path]
      print "Running $(args1.join " ")"
      exit-value := pipe.run-program args1
      if exit-value != 0: throw "pngunzip failed with exit code $exit-value"

      // Check that uncompressing the PNGs did not change them.
      args2 := ["./build/pngdiff", path, "tests/out/unzip-$filename"]
      print "Running $(args2.join " ")"
      exit-value = pipe.run-program args2
      if exit-value != 0: throw "pngdiff failed with exit code $exit-value"

      // Check that the unzipped PNGs are now random access.
      args3 := ["./build/pnginfo", "--random-access", "tests/out/unzip-$filename"]
      print "Running $(args3.join " ")"
      exit-value = pipe.run-program args3
      if exit-value != 0: throw "pnginfo failed with exit code $exit-value"
