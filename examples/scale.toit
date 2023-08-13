import binary show BIG_ENDIAN
import cli
import host.file
import host.directory show *
import monitor
import png_reader
import png_display
import zlib

main args/List -> int:
  cmd := cli.Command "scale"
      --long-help="""
        Scales PNG files without introducing anti-aliasing artefacts.

        Can only scale by integer reductions.
        """
      --options=[
          cli.OptionInt "reduction" --short-help="Factor to scale down" --default=4
      ]
      --rest=[
          cli.OptionString "input"
              --type="file"
              --short-help="The input PNG file"
              --required,
          cli.OptionString "output"
              --type="file"
              --short-help="The output PNG file"
              --required,
      ]
      --run=::
        scale it
  cmd.run args
  return 0

scale parsed/cli.Parsed:
  input := parsed["input"]
  output:= parsed["output"]

  png := png_reader.Png.from_file input
  print png

  x_scale := parsed["reduction"]
  y_scale := parsed["reduction"]
  out_width := png.width / x_scale
  out_height := png.width / y_scale
  buffer := scale_ png x_scale y_scale out_width out_height
  fd := file.Stream.for_write output
  write_png_ fd buffer out_width out_height
  fd.close

scale_ png/png_reader.Png x_scale/int y_scale/int out_width/int out_height/int -> ByteArray:
  result := ByteArray out_width * out_height * 4
  i := 0
  for y := 0; y < out_height; y++:
    for x := 0; x < out_width; x++:
      r_sum := 0
      g_sum := 0
      b_sum := 0
      a_sum := 0
      for x2 := 0; x2 < x_scale; x2++:
        for y2 := 0; y2 < y_scale; y2++:
          index := 4 * (x * x_scale + x2 + (y * y_scale + y2) * png.width)
          r := png.image_data[index + 0]
          g := png.image_data[index + 1]
          b := png.image_data[index + 2]
          a := png.image_data[index + 3]
          //print "in $x2,$y2: $r $g $b $a"
          r_sum += a * r
          g_sum += a * g
          b_sum += a * b
          a_sum += a
      if a_sum == 0:
        result[i++] = 0
        result[i++] = 0
        result[i++] = 0
        result[i++] = 0
      else:
        result[i++] = r_sum / a_sum
        result[i++] = g_sum / a_sum
        result[i++] = b_sum / a_sum
        result[i++] = a_sum / (x_scale * y_scale)
  return result

write_png_ fd/file.Stream buffer/ByteArray width/int height/int:
  fd.write png_display.PngDriver_.HEADER
  ihdr := #[
    0, 0, 0, 0,          // Width.
    0, 0, 0, 0,          // Height.
    8,                   // Bit depth.
    6,                   // Color type = RGBA.
    0, 0, 0,
  ]
  BIG_ENDIAN.put_uint32 ihdr 0 width
  BIG_ENDIAN.put_uint32 ihdr 4 height
  png_display.PngDriver_.write_chunk fd "IHDR" ihdr
  compressor := zlib.Encoder
  task::
    line := ByteArray width * 4 + 1
    for y := 0; y < height; y++:
      line.replace 1 buffer[y * width * 4..(y + 1) * width * 4]
      idx := 0
      while idx < line.size:
        idx += compressor.write line[idx..]
    compressor.close
  while data := compressor.reader.read:
    png_display.PngDriver_.write_chunk fd "IDAT" data
  png_display.PngDriver_.write_chunk fd "IEND" #[]  // End chunk.
