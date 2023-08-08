// Copyright (C) 2023 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import binary show BIG_ENDIAN byte_swap_32
import bytes show Buffer
import crypto.crc show *
import host.file
import monitor show Latch
import reader
import zlib

// The PNG file format is described in the specification:
// https://www.w3.org/TR/2003/REC-PNG-20031110/

HEADER_ ::= #[0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n']

COLOR_TYPE_GREYSCALE ::= 0
COLOR_TYPE_TRUECOLOR ::= 2
COLOR_TYPE_INDEXED ::= 3
COLOR_TYPE_GREYSCALE_ALPHA ::= 4
COLOR_TYPE_TRUECOLOR_ALPHA ::= 6

FILTER_TYPE_NONE_ ::= 0
FILTER_TYPE_SUB_ ::= 1
FILTER_TYPE_UP_ ::= 2
FILTER_TYPE_AVERAGE_ ::= 3
FILTER_TYPE_PAETH_ ::= 4

class Png:
  filename/string?
  bytes/ByteArray
  width/int
  height/int
  image_data/ByteArray
  image_data_position_/int := 0
  bit_depth/int
  color_type/int
  compression_method/int
  filter_method/int
  pixels/ByteArray
  palette_r_/ByteArray? := null
  palette_g_/ByteArray? := null
  palette_b_/ByteArray? := null
  palette_a_/ByteArray? := null
  r_transparent_/int? := null
  g_transparent_/int? := null
  b_transparent_/int? := null
  pixel_width/int := 0  // Number of bits in a pixel.
  lookbehind_offset/int := 0  // How many byte to look back to get previous pixel.
  previous_line_/ByteArray? := null
  decompressor_/zlib.Decoder

  stringify:
    color_type_string/string := ?
    if color_type == COLOR_TYPE_GREYSCALE:
      color_type_string = "greyscale"
    else if color_type == COLOR_TYPE_TRUECOLOR:
      color_type_string = "truecolor"
    else if color_type == COLOR_TYPE_INDEXED:
      color_type_string = "indexed"
    else if color_type == COLOR_TYPE_GREYSCALE_ALPHA:
      color_type_string = "greyscale with alpha"
    else:
      assert: color_type == COLOR_TYPE_TRUECOLOR_ALPHA
      color_type_string = "truecolor with alpha"
    return "PNG, $(width)x$height, bit depth: $bit_depth, color type: $color_type_string"

  constructor.from_file filename/string:
    return Png --filename=filename
        file.read_content filename

  constructor .bytes --.filename/string?=null:
    pos := HEADER_.size
    if bytes[0..pos] != HEADER_:
      throw "Invalid PNG header" + (filename ? ": $filename" : "")
    ihdr := Chunk bytes pos: pos = it
    if ihdr.name != "IHDR":
      throw "First chunk is not IHDR" + (filename ? ": $filename" : "")
    width = BIG_ENDIAN.uint32 ihdr.data 0
    height = BIG_ENDIAN.uint32 ihdr.data 4
    image_data = ByteArray 4 * width * height
    bit_depth = ihdr.data[8]
    color_type = ihdr.data[9]
    compression_method = ihdr.data[10]
    filter_method = ihdr.data[11]
    if ihdr.data[12] != 0: throw "Interlaced images not supported"
    pixels = ByteArray width * height * 4
    decompressor_ = zlib.Decoder
    //////////////////////////////////////////////////
    ensure_greyscale_palette_
    process_bit_depth_ bit_depth color_type filter_method
    byte_width := (width * pixel_width + 7) / 8
    previous_line_ = ByteArray byte_width
    task:: write_image_data byte_width
    while true:
      chunk := Chunk bytes pos : pos = it
      if chunk.name == "PLTE":
        handle_palette chunk
      else if chunk.name == "tRNS":
        handle_transparency chunk
      else if chunk.name == "IDAT":
        handle_image_data chunk
      else if chunk.name == "IEND":
        if pos != bytes.size:
          throw "Trailing data after IEND" + (filename ? ": $filename" : "")
        decompressor_.close
        break
      else if chunk.name[0] & 0x20 == 0:
        throw "Unknown chunk $chunk.name" + (filename ? ": $filename" : "")

  process_bit_depth_ bit_depth/int color_type/int filter_method/int -> none:
    if filter_method != 0:
      throw "Unknown filter method"
    if bit_depth < 1 or not bit_depth.is_power_of_two:
      throw "Invalid bit depth"
    if color_type == COLOR_TYPE_GREYSCALE:
      if bit_depth > 16:
        throw "Invalid bit depth"
      pixel_width = bit_depth
      lookbehind_offset = bit_depth == 16 ? 2 : 1
    if color_type == COLOR_TYPE_TRUECOLOR:
      if not 8 <= bit_depth <= 16:
        throw "Invalid bit depth"
      pixel_width = 3 * bit_depth
      lookbehind_offset = pixel_width / 8
    if color_type == COLOR_TYPE_INDEXED:
      if bit_depth > 8:
        throw "Invalid bit depth"
      pixel_width = bit_depth
      lookbehind_offset = 1
    if color_type == COLOR_TYPE_GREYSCALE_ALPHA:
      if not 8 <= bit_depth <= 16:
        throw "Invalid bit depth"
      pixel_width = 2 * bit_depth
      lookbehind_offset = pixel_width / 8
    if color_type == COLOR_TYPE_TRUECOLOR_ALPHA:
      if not 8 <= bit_depth <= 16:
        throw "Invalid bit depth"
      pixel_width = 4 * bit_depth
      lookbehind_offset = pixel_width / 8

  handle_palette chunk/Chunk:
    if color_type != COLOR_TYPE_INDEXED:
      return  // Just a suggested palette.
    if chunk.size % 3 != 0:
      throw "Invalid palette size"
    palette_r_ = ByteArray (chunk.size / 3): chunk.data[it * 3]
    palette_g_ = ByteArray (chunk.size / 3): chunk.data[it * 3 + 1]
    palette_b_ = ByteArray (chunk.size / 3): chunk.data[it * 3 + 2]

  handle_transparency chunk/Chunk:
    if color_type == COLOR_TYPE_GREYSCALE:
      value := BIG_ENDIAN.uint16 chunk.data 0
      r_transparent_ = value
      if palette_a_:  // In case of 16 bit image.
        palette_a_[value] = 0
    else if color_type == COLOR_TYPE_TRUECOLOR:
      r_transparent_ = BIG_ENDIAN.uint16 chunk.data 0
      g_transparent_ = BIG_ENDIAN.uint16 chunk.data 2
      b_transparent_ = BIG_ENDIAN.uint16 chunk.data 4
    else if color_type == COLOR_TYPE_INDEXED:
      palette_a_.replace 0 chunk.data
    else:
      throw "Transparency chunk for non-indexed image"

  ensure_greyscale_palette_:
    if not palette_r_:
      if color_type == COLOR_TYPE_INDEXED:
        palette_a_ = ByteArray (1 << bit_depth): 255
      else if color_type == COLOR_TYPE_GREYSCALE or color_type == COLOR_TYPE_GREYSCALE_ALPHA:
        if bit_depth != 16:
          factor := [0, 255, 85, 0, 17, 0, 0, 0, 1][bit_depth]
          size := 1 << bit_depth
          palette_r_ = ByteArray size: it * factor
          palette_g_ = ByteArray size: it * factor
          palette_b_ = ByteArray size: it * factor
          palette_a_ = ByteArray size: 255

  handle_image_data chunk/Chunk:
    decompressor_.write chunk.data

  write_image_data byte_width/int:
    reader := reader.BufferedReader decompressor_.reader
    while reader.can_ensure (byte_width + 1):
      data := reader.read_bytes (byte_width + 1)
      filter := data[0]
      line := data[1..]
      if filter == FILTER_TYPE_SUB_:
        for i := lookbehind_offset; i < byte_width; i++:
          line[i] += line[i - lookbehind_offset]
      else if filter == FILTER_TYPE_UP_:
        byte_width.repeat:
          line[it] += previous_line_[it]
      else if filter == FILTER_TYPE_AVERAGE_:
        lookbehind_offset.repeat:
          line[it] += previous_line_[it] >> 1
        for i := lookbehind_offset; i < byte_width; i++:
          line[i] += (line[i - lookbehind_offset] + previous_line_[i]) >> 1
      else if filter == FILTER_TYPE_PAETH_:
        lookbehind_offset.repeat:
          line[it] += paeth_ 0 previous_line_[it] 0
        for i := lookbehind_offset; i < byte_width; i++:
          line[i] += paeth_ line[i - lookbehind_offset] previous_line_[i] previous_line_[i - lookbehind_offset]
      else if filter != FILTER_TYPE_NONE_:
        throw "Unknown filter type: $filter"
      previous_line_ = line
      if bit_depth == 1:
        width.repeat:
          index := (line[it >> 3] >> (7 - (it & 7))) & 1
          image_data[image_data_position_++] = palette_r_[index]
          image_data[image_data_position_++] = palette_g_[index]
          image_data[image_data_position_++] = palette_b_[index]
          image_data[image_data_position_++] = palette_a_[index]
      else if bit_depth == 2:
        width.repeat:
          index := (line[it >> 2] >> (6 - ((it & 3) << 1))) & 3
          image_data[image_data_position_++] = palette_r_[index]
          image_data[image_data_position_++] = palette_g_[index]
          image_data[image_data_position_++] = palette_b_[index]
          image_data[image_data_position_++] = palette_a_[index]
      else if bit_depth == 4:
        width.repeat:
          index := (line[it >> 1] >> (4 - ((it & 1) << 2))) & 0xf
          image_data[image_data_position_++] = palette_r_[index]
          image_data[image_data_position_++] = palette_g_[index]
          image_data[image_data_position_++] = palette_b_[index]
          image_data[image_data_position_++] = palette_a_[index]
      else if bit_depth == 8:
        if color_type == COLOR_TYPE_INDEXED or color_type == COLOR_TYPE_GREYSCALE:
          width.repeat:
            index := line[it]
            image_data[image_data_position_++] = palette_r_[index]
            image_data[image_data_position_++] = palette_g_[index]
            image_data[image_data_position_++] = palette_b_[index]
            image_data[image_data_position_++] = palette_a_[index]
        else if color_type == COLOR_TYPE_GREYSCALE_ALPHA:
          width.repeat:
            pix := line[it << 1]
            image_data[image_data_position_++] = pix
            image_data[image_data_position_++] = pix
            image_data[image_data_position_++] = pix
            image_data[image_data_position_++] = line[(it << 1) + 1]
        else if color_type == COLOR_TYPE_TRUECOLOR:
          width.repeat:
            r := line[it * 3]
            g := line[it * 3 + 1]
            b := line[it * 3 + 2]
            image_data[image_data_position_++] = r
            image_data[image_data_position_++] = g
            image_data[image_data_position_++] = b
            if r == r_transparent_ and g == g_transparent_ and b == b_transparent_:
              image_data[image_data_position_++] = 0
            else:
              image_data[image_data_position_++] = 255
        else if color_type == COLOR_TYPE_TRUECOLOR_ALPHA:
          image_data.replace image_data_position_ line
          image_data_position_ += width << 2
      else:
        assert: bit_depth == 16
        if color_type == COLOR_TYPE_GREYSCALE:
          width.repeat:
            value := BIG_ENDIAN.uint16 line (it << 1)
            image_data[image_data_position_++] = value >> 8
            image_data[image_data_position_++] = value >> 8
            image_data[image_data_position_++] = value >> 8
            if r_transparent_ == value:
              image_data[image_data_position_++] = 0
            else:
              image_data[image_data_position_++] = 255
        else if color_type == COLOR_TYPE_GREYSCALE_ALPHA:
          width.repeat:
            value := BIG_ENDIAN.uint16 line (it << 2)
            alpha := BIG_ENDIAN.uint16 line ((it << 2) + 2)
            image_data[image_data_position_++] = value >> 8
            image_data[image_data_position_++] = value >> 8
            image_data[image_data_position_++] = value >> 8
            image_data[image_data_position_++] = alpha >> 8
        else if color_type == COLOR_TYPE_TRUECOLOR:
          width.repeat:
            r := BIG_ENDIAN.uint16 line (it * 6)
            g := BIG_ENDIAN.uint16 line (it * 6 + 2)
            b := BIG_ENDIAN.uint16 line (it * 6 + 4)
            image_data[image_data_position_++] = r >> 8
            image_data[image_data_position_++] = g >> 8
            image_data[image_data_position_++] = b >> 8
            if r == r_transparent_ and g == g_transparent_ and b == b_transparent_:
              image_data[image_data_position_++] = 0
            else:
              image_data[image_data_position_++] = 255
        else if color_type == COLOR_TYPE_TRUECOLOR_ALPHA:
          width.repeat:
            r := BIG_ENDIAN.uint16 line (it << 3)
            g := BIG_ENDIAN.uint16 line ((it << 3) + 2)
            b := BIG_ENDIAN.uint16 line ((it << 3) + 4)
            a := BIG_ENDIAN.uint16 line ((it << 3) + 6)
            image_data[image_data_position_++] = r >> 8
            image_data[image_data_position_++] = g >> 8
            image_data[image_data_position_++] = b >> 8
            image_data[image_data_position_++] = a >> 8
    if image_data_position_ != image_data.size:
      throw "Not enough image data"

  static paeth_ a/int b/int c/int -> int:
    p := a + b - c
    pa := (p - a).abs
    pb := (p - b).abs
    pc := (p - c).abs
    if pa <= pb and pa <= pc:
      return a
    else if pb <= pc:
      return b
    else:
      return c

class Chunk:
  name/string
  data/ByteArray
  size/int

  constructor byte_array position [position_updater]:
    size = BIG_ENDIAN.uint32 byte_array position
    name = byte_array[position + 4..position + 8].to_string
    data = byte_array[position + 8..position + 8 + size]
    checksum := BIG_ENDIAN.uint32 byte_array position + 8 + size
    calculated_checksum := crc32 byte_array[position + 4..position + 8 + size]
    if checksum != calculated_checksum:
      throw "Invalid checksum"
    position_updater.call position + size + 12

main:
  png := Png.from_file "test.png"
  print png
