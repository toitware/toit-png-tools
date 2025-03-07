// Copyright (C) 2023 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the EXAMPLES_LICENSE file.

import io show BIG-ENDIAN
import cli
import host.file
import host.directory show *
import monitor
import png-tools.png-reader
import png-display
import zlib

main args/List -> int:
  cmd := cli.Command "scale"
      --help="""
        Scales PNG files without introducing anti-aliasing artefacts.

        Can only scale by integer reductions.

        Always writes 32bits-per-pixel RGBA PNGs.
        """
      --options=[
          cli.OptionInt "reduction" --help="Factor to scale down" --default=4
      ]
      --rest=[
          cli.Option "input"
              --type="file"
              --help="The input PNG file"
              --required,
          cli.Option "output"
              --type="file"
              --help="The output PNG file"
              --required,
      ]
      --run=::
        scale it
  cmd.run args
  return 0

scale parsed/cli.Parsed:
  input := parsed["input"]
  output:= parsed["output"]

  png-bytes := file.read-contents input
  png := png-reader.Png png-bytes --filename=input
  print png

  x-scale := parsed["reduction"]
  y-scale := parsed["reduction"]
  out-width := png.width / x-scale
  out-height := png.width / y-scale
  buffer := scale_ png x-scale y-scale out-width out-height
  fd := file.Stream.for-write output
  write-png_ fd buffer out-width out-height
  fd.close

scale_ png/png-reader.Png x-scale/int y-scale/int out-width/int out-height/int -> ByteArray:
  result := ByteArray out-width * out-height * 4
  i := 0
  for y := 0; y < out-height; y++:
    for x := 0; x < out-width; x++:
      r-sum := 0
      g-sum := 0
      b-sum := 0
      a-sum := 0
      for x2 := 0; x2 < x-scale; x2++:
        for y2 := 0; y2 < y-scale; y2++:
          index := 4 * (x * x-scale + x2 + (y * y-scale + y2) * png.width)
          r := png.image-data[index + 0]
          g := png.image-data[index + 1]
          b := png.image-data[index + 2]
          a := png.image-data[index + 3]
          //print "in $x2,$y2: $r $g $b $a"
          r-sum += a * r
          g-sum += a * g
          b-sum += a * b
          a-sum += a
      if a-sum == 0:
        result[i++] = 0
        result[i++] = 0
        result[i++] = 0
        result[i++] = 0
      else:
        result[i++] = r-sum / a-sum
        result[i++] = g-sum / a-sum
        result[i++] = b-sum / a-sum
        result[i++] = a-sum / (x-scale * y-scale)
  return result

write-png_ fd/file.Stream buffer/ByteArray width/int height/int:
  fd.out.write png-display.PngDriver_.HEADER
  ihdr := #[
    0, 0, 0, 0,          // Width.
    0, 0, 0, 0,          // Height.
    8,                   // Bit depth.
    6,                   // Color type = RGBA.
    0, 0, 0,
  ]
  BIG-ENDIAN.put-uint32 ihdr 0 width
  BIG-ENDIAN.put-uint32 ihdr 4 height
  png-display.PngDriver_.write-chunk fd "IHDR" ihdr
  compressor := zlib.Encoder
  task::
    line := ByteArray width * 4 + 1
    for y := 0; y < height; y++:
      line.replace 1 buffer[y * width * 4..(y + 1) * width * 4]
      idx := 0
      while idx < line.size:
        idx += compressor.out.write line[idx..]
    compressor.out.close
  while data := compressor.in.read:
    png-display.PngDriver_.write-chunk fd "IDAT" data
  png-display.PngDriver_.write-chunk fd "IEND" #[]  // End chunk.
