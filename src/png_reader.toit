// Copyright (C) 2023 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import binary show BIG_ENDIAN byte_swap_32
import bitmap show *
import bytes show Buffer
import crypto.crc show *
import host.file
import monitor show Latch
import zlib show *

// The PNG file format is described in the specification:
// https://www.w3.org/TR/2003/REC-PNG-20031110/

HEADER_ ::= #[0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n']

COLOR_TYPE_GREYSCALE ::= 0
COLOR_TYPE_TRUECOLOR ::= 2
COLOR_TYPE_INDEXED ::= 3
COLOR_TYPE_GREYSCALE_ALPHA ::= 4
COLOR_TYPE_TRUECOLOR_ALPHA ::= 6

class Png:
  filename/string?
  bytes/ByteArray
  width/int
  height/int
  bit_depth/int
  color_type/int
  compression_method/int
  filter_method/int
  interlaced/bool
  pixels/ByteArray
  palette/ByteArray? := null
  pixel_width/int := 0  // Number of bits in a pixel.
  lookbehind_offset/int := 0  // How many byte to look back to get previous pixel.
  previous_line_/ByteArray? := null
  current_line_/ByteArray? := null

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
    bit_depth = ihdr.data[8]
    color_type = ihdr.data[9]
    compression_method = ihdr.data[10]
    filter_method = ihdr.data[11]
    interlaced = ihdr.data[12] == 1
    pixels = ByteArray width * height * 4
    //////////////////////////////////////////////////
    legal_combination_ bit_depth color_type filter_method
    byte_width := (width * pixel_width + 7) / 8
    previous_line_ = ByteArray byte_width
    current_line_ = ByteArray byte_width
    while true:
      chunk := Chunk bytes pos : pos = it
      if chunk.name == "PLTE":
        handle_palette chunk
      else if chunk.name == "IDAT":
        handle_image_data chunk
      else if chunk.name == "IEND":
        if pos != bytes.size:
          throw "Trailing data after IEND" + (filename ? ": $filename" : "")
        break
      else if chunk.name[0] & 0x20 == 0:
        throw "Unknown chunk $chunk.name" + (filename ? ": $filename" : "")

  legal_combination_ bit_depth/int color_type/int filter_method/int -> none:
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
    if color_type == COLOR_TYPE_INDEXED:
      if chunk.size % 3 != 0:
        throw "Invalid palette size"
      palette = chunk.data

  handle_image_data chunk/Chunk:
    // TODO.

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
  print "$png.width x $png.height, bit depth: $png.bit_depth, color type: $png.color_type, compression method: $png.compression_method"
