// Copyright (C) 2023 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import binary
import binary show BIG-ENDIAN
import bitmap
import cli
import crypto.crc show *
import host.file
import host.pipe
import monitor show Latch
import reader show BufferedReader
import png-reader show Png
import zlib
import .version

main args/List:
  root-cmd := cli.Command "pngdiff"
      --long-help="""
          Compare two PNG files at the pixel level.

          This can be used to compare PNGs that have been compressed with
            different compression schemes, or with different bit depths.

          Optionally produces a PNG file that highlights the differences.
            In the output, the pixels that differ are made bright, and the
            parts that are the same are made dark.  Any pixels that differ
            have the alpha set to 100% opaque.

          All compression schemes and bit depths <= 8 are supported.  The
            alpha channel is compared just like the color values of the pixels.

          The return code is 0 if the files are identical, 1 if they differ.

          Filenames specified as "-" are read from stdin or written to stdout.

          Limitations:
          * No diff PNG is produced if the files differ in size.
          * 16 bit PNGs are not supported.
          * Interlaced PNGs are not supported.
          * The output PNG is always 8 bit RGBA format.
          * Chunks that are not understood are ignored and do not form
              part of the comparison.  This includes color model chunks
              and gamma adjustments.
          """
      --options=[
          cli.Flag "quiet"
              --short-name="q"
              --default=false
              --short-help="Do not write messages to stderr, just return the exit code.",
          cli.Option "out"
              --short-name="o"
              --default=null
              --short-help="Output (default: no output file)."
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
          cli.Option "file1"
              --required
              --short-help="PNG file input 1."
              --type="file",
          cli.Option "file2"
              --default="-"
              --short-help="PNG file input 2."
              --type="file",
          ]
      --run= :: diff it
  root-cmd.run args

diff parsed -> none:
  if parsed["version"]:
    print "pngdiff $PNGDIFF-VERSION"
    return

  file1-name := parsed["file1"]
  file2-name := parsed["file2"]
  debug/bool := parsed["debug-stack-traces"]
  quiet/bool := parsed["quiet"]

  error := catch --unwind=debug:
    if file1-name == "-" and file2-name == "-":
      throw "Must specify at least one file"
  if error:
    if not quiet:
      pipe.stderr.write "$error\n"
    exit 1

  png1 := slurp-file file1-name --debug=debug
  png2 := slurp-file file2-name --debug=debug

  if png1.width != png2.width or png1.height != png2.height:
    if not quiet:
      pipe.stderr.write "Different sizes:\n"
      pipe.stderr.write "  $file1-name: $(png1.width)x$(png1.height)\n"
      pipe.stderr.write "  $file2-name: $(png2.width)x$(png2.height)\n"
    exit 1

  if png1.image-data == png2.image-data:
    exit 0

  if quiet:
    exit 1

  w := png1.width
  for y := 0; (not quiet) and y < png1.height; y++:
    line1 := png1.image-data[w * 4 * y .. w * 4 * (y + 1)]
    line2 := png2.image-data[w * 4 * y .. w * 4 * (y + 1)]
    if line1 != line2:
      line1.size.repeat: | x |
        if line1[x] != line2[x]:
          x = round-down x 4
          alpha1 := line1[x + 3]
          pixel1 := BIG-ENDIAN.uint24 line1 x
          alpha2 := line2[x + 3]
          pixel2 := BIG-ENDIAN.uint24 line2 x
          if pixel1 != pixel2 or alpha1 != alpha2:
            pipe.stderr.write "Different pixels at $(x / 4), $y:\n"
            pipe.stderr.write "  $file1-name: $(%06x pixel1) (alpha $(%02x alpha1))\n"
            pipe.stderr.write "  $file2-name: $(%06x pixel2) (alpha $(%02x alpha2))\n"
          break

  if not parsed["out"]:
    exit 1

  out-stream := parsed["out"] == "-" ?
      pipe.stdout :
      file.Stream.for-write parsed["out"]
  diff-image := ByteArray png1.image-data.size
  // Make all pixels darker.
  bitmap.blit
      png1.image-data  // Source.
      diff-image       // Destination.
      3                // Pixels per line (skip alpha bytes).
      --source-line-stride=4
      --destination-line-stride=4
      --shift=2
      --mask=0x3f
  // Copy over the alphas unchanged.
  bitmap.blit
      png1.image-data[3..]  // Source.
      diff-image[3..]       // Destination.
      png1.width            // Pixels per line.
      --source-pixel-stride=4
      --destination-pixel-stride=4
  // Make an array that is non-zero in all the places where the pixels
  // differ.
  xored := png1.image-data.copy
  bitmap.blit
      png2.image-data  // Source.
      xored            // Destination.
      png1.width * 4   // Line length.
      --operation=bitmap.XOR
  // Makes the pixels that differ very bright in the components that differ.
  bitmap.blit
      xored            // Source.
      diff-image       // Destination.
      png1.width * 4   // Line length.
      --operation=bitmap.OR
      --lookup-table=MAX-OUT
  3.repeat: | component |
    // For all pixels that differ, set the opacity to 100%.
    bitmap.blit
        xored[component..]  // Source, starting at r, g, or b.
        diff-image[3..]     // Destination, starting at an alpha byte.
        png1.width          // Line length.
        --source-pixel-stride=4
        --destination-pixel-stride=4
        --operation=bitmap.OR
        --lookup-table=MAX-OUT

  writer := PngWriter out-stream png1.width png1.height
  List.chunk-up 0 diff-image.size (png1.width * 4): | from to length |
    writer.write-uncompressed #[0]  // Filter type 0.
    writer.write-uncompressed diff-image[from..to]
  writer.close

  exit 1

/// Maps all non-zero bytes to the brightest possible value.
MAX-OUT := ByteArray 0x100: it == 0 ? 0 : 0xff

class PngWriter:
  stream_/any
  compressor_/zlib.Encoder
  done_/Latch

  constructor .stream_ width/int height/int:
    HEADER ::= #[0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n']
    compressor_ = zlib.Encoder
    done_ = Latch

    write_ HEADER
    ihdr := #[
      0, 0, 0, 0,          // Width.
      0, 0, 0, 0,          // Height.
      8,                   // Bit depth.
      6,                   // Color type is true color with alpha
      0, 0, 0,
    ]
    BIG-ENDIAN.put-uint32 ihdr 0 width
    BIG-ENDIAN.put-uint32 ihdr 4 height
    write-chunk_ "IHDR" ihdr
    task:: write-function

  write-uncompressed data/ByteArray -> none:
    compressor_.write data

  close -> none:
    compressor_.close
    done_.get

  static byte_swap_ ba/ByteArray -> ByteArray:
    result := ba.copy
    binary.byte_swap_32 result
    return result

  write-function:
    while data := compressor_.reader.read:
      write-chunk_ "IDAT" data
    write-chunk_ "IEND" #[]
    done_.set null

  write-chunk_ name/string data/ByteArray -> none:
    length := ByteArray 4
    if name.size != 4: throw "invalid name"
    BIG-ENDIAN.put-uint32 length 0 data.size
    write_ length
    write_ name
    write_ data
    crc := Crc32
    crc.add name
    crc.add data
    write_
      byte-swap_
        crc.get

  write_ byte-array -> none:
    done := 0
    while done != byte-array.size:
      done += stream_.write byte-array[done..]

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
