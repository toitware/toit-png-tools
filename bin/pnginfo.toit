// Copyright (C) 2023 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import cli
import host.file
import host.pipe
import io show Reader
import encoding.json
import png-tools.png-reader show *
import png-tools.png-writer show PngWriter
import .version

main args/List:
  root-cmd := cli.Command "pnginfo"
      --help="""
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
              --help="Output (default: stdout)."
              --type="file",
          cli.Flag "version"
              --short-name="v"
              --default=false
              --help="Print version and exit.",
          cli.Flag "json"
              --short-name="j"
              --default=false
              --help="Print information in JSON format.",
          cli.Flag "width"
              --short-name="w"
              --default=false
              --help="Print the width of the image in pixels, and nothing else.",
          cli.Flag "height"
              --short-name="h"
              --default=false
              --help="Print the width of the image in pixels, and nothing else.",
          cli.Option "chunk"
              --short-name="c"
              --default=null
              --help="Dump the contents of the named chunk and nothing else."
              --type="string",
          cli.Flag "all-chunks"
              --short-name="a"
              --default=false
              --help="Dump the contents of all non-required chunks.",
          cli.Flag "random-access"
              --short-name="r"
              --default=false
              --help="Print whether the PNG file has uncompressed random access pixel data.",
          cli.Flag "show-image-data"
              --short-name="s"
              --default=false
              --help="Use terminal graphics to show the image data.",
          cli.Flag "debug-stack-traces"
              --short-name="d"
              --default=false
              --help="Dump developer-friendly stack traces on error.",
          ]
      --rest=[
          cli.Option "file"
              --required
              --multi
              --help="PNG file input."
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

  out-stream := parsed["out"] == "-" ?
      pipe.stdout :
      file.Stream.for-write parsed["out"]

  for i := 0; i < parsed["file"].size; i++:
    file-name := parsed["file"][i]
    dump file-name parsed out-stream (i == 0)

dump file-name/string parsed out-stream is-first/bool -> none:
  if not is-first: write out-stream "\n"
  debug/bool := parsed["debug-stack-traces"]

  pngs := slurp-file file-name --debug=debug --include-image-data=parsed["show-image-data"]
  png/PngInfo := pngs[0]

  if parsed["width"]:
    write out-stream png.width.stringify
    write out-stream "\n"
    return

  if parsed["height"]:
    write out-stream png.height.stringify
    write out-stream "\n"
    return

  if parsed["random-access"]:
    if png.uncompressed-random-access:
      write out-stream "true\n"
      exit 0
    else:
      write out-stream "false\n"
      exit 1
    unreachable

  json-format := parsed["json"]

  map := {:}
  map["filename"] = file-name
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
  if parsed["all-chunks"]:
    png.saved-chunks.do: | name data |
      map[name] = json-format ? (List data.size: data[it]) : data
  else if parsed["chunk"]:
    png.saved-chunks.get parsed["chunk"] --if-present=: | data |
      map[parsed["chunk"]] = (json-format ? (List data.size: data[it]) : data)

  if json-format:
    write out-stream (json.encode map)
    write out-stream "\n"
    return

  map.remove "width"
  map.remove "height"
  map.remove "color_type"

  properties := []
  map.do: | key value |
    properties.add "$key: $value"

  write out-stream "PNG file: $(png.width)x$png.height\n$(properties.join "\n")\n"

  if parsed["show-image-data"]:
    show-image-data pngs[1] out-stream

// Terminals have a way to print approximately square pixels using "▀"
// and background and foreground colors.

class Pixel:
  r/int
  g/int
  b/int
  a/int

  constructor .r .g .b .a:

  mix odd/bool [block] -> none:
    chess := odd ? 0x9b : 0xbb
    mixed-r := (a * r + chess * (256 - a)) >> 8
    mixed-g := (a * g + chess * (256 - a)) >> 8
    mixed-b := (a * b + chess * (256 - a)) >> 8
    block.call mixed-r mixed-g mixed-b

class Terminal:
  bg-r := -1
  bg-g := -1
  bg-b := -1
  fg-r := -1
  fg-g := -1
  fg-b := -1

  writer := ?

  constructor .writer:

  reset -> none:
    bg-r = -1
    bg-g = -1
    bg-b = -1
    fg-r = -1
    fg-g = -1
    fg-b = -1

  has-fg pixel/Pixel odd/bool -> bool:
    pixel.mix odd: | r g b |
      return r == fg-r and g == fg-b and b == fg-b
    unreachable

  has-bg pixel/Pixel odd/bool -> bool:
    pixel.mix odd: | r g b |
      return r == bg-r and g == bg-b and b == bg-b
    unreachable

  set-fg pixel/Pixel odd/bool -> none:
    pixel.mix odd: | r g b |
      if r != fg-r or g != fg-b or b != fg-b:
        write writer "\x1b[38;2;$r;$g;$(b)m"
        fg-r = r
        fg-g = g
        fg-b = b

  set-bg pixel/Pixel odd/bool -> none:
    pixel.mix odd: | r g b |
      if r != bg-r or g != bg-b or b != bg-b:
        write writer "\x1b[48;2;$r;$g;$(b)m"
        bg-r = r
        bg-g = g
        bg-b = b

write writer data -> none:
  from := 0
  while from != data.size:
    from += writer.write data[from..]

show-image-data png/PngRgba out-stream -> none:
  width := png.width
  height := png.height
  data := png.image-data

  terminal := Terminal out-stream

  y := png.height & 1

  index := 0

  if y == 1:
    // Start with odd line.
    for i := 0; i < png.width; i++:
      r := data[index++]
      g := data[index++]
      b := data[index++]
      a := data[index++]
      pixel := Pixel r g b a
      odd := i & 1 != 0
      if not terminal.has-fg pixel odd:
        terminal.set-fg pixel odd
      write out-stream "▄"
    write out-stream "\x1b[0m\n"
    terminal.reset

  pixels := List width
  for ; y < height; y += 2:
    for i := 0; i < png.width; i++:
      r := data[index++]
      g := data[index++]
      b := data[index++]
      a := data[index++]
      pixel := Pixel r g b a
      pixels[i] = pixel
    for i := 0; i < png.width; i++:
      r := data[index++]
      g := data[index++]
      b := data[index++]
      a := data[index++]
      pixel := Pixel r g b a
      odd := i & 1 != 0
      if (terminal.has-fg pixels[i] (not odd)) and
          (terminal.has-bg pixel odd):
        write out-stream "▀"
      else:
        terminal.set-bg pixels[i] (not odd)
        terminal.set-fg pixel odd
        write out-stream "▄"
    terminal.reset
    write out-stream "\x1b[0m\n"

slurp-file file-name/string --debug/bool --include-image-data/bool=false -> List:
  error := catch --unwind=debug:
    reader/Reader := file-name == "-"
        ? pipe.stdin.in
        : (file.Stream.for-read file-name).in
    contents := reader.read-all
    info := PngInfo contents
    if not include-image-data: return [info]
    return [info, PngRgba contents]
  if error:
    if error == "OUT_OF_BOUNDS":
      pipe.stderr.out.write "$file-name: Broken PNG file.\n"
    else:
      pipe.stderr.out.write "$file-name: $error.\n"
    exit 1
  unreachable
