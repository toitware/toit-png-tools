// Copyright (C) 2023 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import bitmap
import cli
import host.file
import host.pipe
import png-tools.png-reader show Png COLOR-TYPE-INDEXED COLOR-TYPE-GRAYSCALE
import png-tools.png-writer show PngWriter
import reader show BufferedReader
import .version

main args/List:
  root-cmd := cli.Command "pngunzip"
      --long-help="""
          Uncompress a PNG file.

          This can be used to create PNG files that don't use any
            compression.  This enables random access to pixel data
            in embedded scenarios with limited RAM, but plentiful
            flash.

          Limitations:
          * Interlaced PNGs are not supported.
          * Removes all non-critical chunks except tRNS (transparency).
          """
      --options=[
          cli.Flag "quiet"
              --short-name="q"
              --default=false
              --short-help="Do not write messages to stderr, just return the exit code.",
          cli.Option "out"
              --short-name="o"
              --default="-"
              --short-help="Output (default: stdout)."
              --type="file",
          cli.Flag "version"
              --short-name="v"
              --default=false
              --short-help="Print version and exit",
          cli.Flag "debug-stack-traces"
              --short-name="d"
              --default=false
              --short-help="Dump developer-friendly stack traces on error.",
          ]
      --rest=[
          cli.Option "file"
              --required
              --short-help="PNG file input."
              --type="file",
          ]
      --run= :: unzip it
  root-cmd.run args

unzip parsed -> none:
  if parsed["version"]:
    print "pngunzip $PNGDIFF-VERSION"
    return

  file-name := parsed["file"]
  debug/bool := parsed["debug-stack-traces"]
  quiet/bool := parsed["quiet"]

  png := slurp-file file-name --debug=debug

  out-stream := parsed["out"] == "-" ?
      pipe.stdout :
      file.Stream.for-write parsed["out"]

  writer := PngWriter out-stream png.width png.height
      --bit-depth=png.bit-depth
      --color-type=png.color-type
      --no-compression

  invert-bits := false
  replacement-trns := null
  if png.bit-depth == 1 and png.color-type == COLOR-TYPE-INDEXED:
    png.saved-chunks.get "tRNS" --if-present=: | data |
      if data == #[0xff, 0]:  // Opaque, transparent.
        // The Toit primitives can use faster primitives if the zeros
        // are transparent and the ones are opaque.
        invert-bits = true
        replacement-trns = #[0, 0xff]
  if png.bit-depth == 1 and png.color-type == COLOR-TYPE-GRAYSCALE:
    png.saved-chunks.get "tRNS" --if-present=: | data |
      if data == #[1, 0]:  // Index 1 is transparent (little-endian 16 bit).
        invert-bits = true
        replacement-trns = #[0, 0]

  ["PLTE", "tRNS"].do: | name |
    png.saved-chunks.get name --if-present=: | data |
      if name == "tRNS" and invert-bits: data = replacement-trns
      if name == "PLTE" and invert-bits: data = data[3..6] + data[0..3]
      writer.write-chunk name data

  bytes-per-line := png.byte-width + 1
  // Avoid hitting the 64k limit on literal blocks.
  lines-per-block := 64000 / bytes-per-line
  buffer := ByteArray (bytes-per-line * lines-per-block)

  lut := invert-bits ? (ByteArray 256: it ^ 0xff) : null
  List.chunk-up 0 png.height lines-per-block: | y-from y-to block-height |
    buffer-y := 0
    for y := y-from; y < y-to; y++:
      index := buffer-y * bytes-per-line + 1  // Add one for filter byte.
      buffer.replace index png.image-data
          y * png.byte-width
          y * png.byte-width + png.byte-width
      if invert-bits:
        slice := buffer[index .. index + png.byte-width]
        bitmap.blit slice slice png.byte-width
            --lookup-table=lut
      buffer-y++
    bytes := bytes-per-line * block-height
    writer.write-uncompressed buffer[0..bytes]
  writer.close

/// Maps all non-zero bytes to the brightest possible value.
MAX-OUT := ByteArray 0x100: it == 0 ? 0 : 0xff

slurp-file file-name/string --debug/bool -> Png:
  error := catch --unwind=debug:
    reader := BufferedReader
        file-name == "-" ?
            pipe.stdin :
            file.Stream.for-read file-name
    reader.buffer-all
    content := reader.read-bytes reader.buffered
    png := Png content
    return png
  if error:
    if error == "OUT_OF_BOUNDS":
      pipe.stderr.write "$file-name: Broken PNG file.\n"
    else:
      pipe.stderr.write "$file-name: $error.\n"
    exit 1
  unreachable
