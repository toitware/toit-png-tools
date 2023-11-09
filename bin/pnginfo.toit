// Copyright (C) 2023 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import cli
import host.file
import host.pipe
import encoding.json
import reader show BufferedReader
import png-tools.png-reader show PngInfo color-type-to-string
import png-tools.png-writer show PngWriter
import .version

main args/List:
  root-cmd := cli.Command "pnginfo"
      --long-help="""
          Print information about a PNG file.

          The exit code can be used to check if the PNG file is readable.

          With the -r option the exit code indicates whether the PNG file has
            random access to uncompressed pixel data.

          Limitations:
          * Interlaced PNGs are not supported.
          """
      --options=[
          cli.Option "out"
              --short-name="o"
              --default="-"
              --short-help="Output (default: stdout)."
              --type="file",
          cli.Flag "version"
              --short-name="v"
              --default=false
              --short-help="Print version and exit",
          cli.Flag "json"
              --short-name="j"
              --default=false
              --short-help="Print information in JSON format",
          cli.Flag "width"
              --short-name="w"
              --default=false
              --short-help="Print the width of the image in pixels, and nothing else",
          cli.Flag "height"
              --short-name="h"
              --default=false
              --short-help="Print the width of the image in pixels, and nothing else",
          cli.Flag "random-access"
              --short-name="r"
              --default=false
              --short-help="Print whether the PNG file has uncompressed random access pixel data",
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
      --run= :: dump it
  root-cmd.run args

dump parsed -> none:
  if parsed["version"]:
    print "pnginfo $PNGDIFF-VERSION"
    return

  formats := 0
  if parsed["json"]: formats++
  if parsed["width"]: formats++
  if parsed["height"]: formats++
  if parsed["random-access"]: formats++
  if formats > 1:
    parsed.usage
    exit 1

  file-name := parsed["file"]
  debug/bool := parsed["debug-stack-traces"]

  png := slurp-file file-name --debug=debug

  out-stream := parsed["out"] == "-" ?
      pipe.stdout :
      file.Stream.for-write parsed["out"]

  if parsed["width"]:
    out-stream.write png.width.stringify
    out-stream.write "\n"
    return

  if parsed["height"]:
    out-stream.write png.height.stringify
    out-stream.write "\n"
    return

  if parsed["random-access"]:
    if png.uncompressed-random-access:
      out-stream.write "true\n"
      exit 0
    else:
      out-stream.write "false\n"
      exit 1
    unreachable

  map := {:}
  map["width"] = png.width
  map["height"] = png.height
  map["color_type"] = png.color-type
  map["bit_depth"] = png.bit-depth
  map["color_type_string"] = color-type-to-string png.color-type
  map["compression_ratio"] = png.compression-ratio
  map["compression_ratio_rgb"] = png.compression-ratio-rgb
  map["compression_ratio_rgba"] = png.compression-ratio-rgba
  map["bytes_per_line"] = png.byte-width
  map["uncompressed_random_access"] = png.uncompressed-random-access

  if parsed["json"]:
    out-stream.write (json.encode map)
    out-stream.write "\n"
    return

  map.remove "width"
  map.remove "height"
  map.remove "color_type"

  properties := []
  map.do: | key value |
    properties.add "$key: $value"

  out-stream.write "PNG file: $(png.width)x$png.height\n$(properties.join "\n")\n"

slurp-file file-name/string --debug/bool -> PngInfo:
  error := catch --unwind=debug:
    reader := BufferedReader
        file-name == "-" ?
            pipe.stdin :
            file.Stream.for-read file-name
    reader.buffer-all
    content := reader.read-bytes reader.buffered
    png := PngInfo content
    return png
  if error:
    if error == "OUT_OF_BOUNDS":
      pipe.stderr.write "$file-name: Broken PNG file.\n"
    else:
      pipe.stderr.write "$file-name: $error.\n"
    exit 1
  unreachable
