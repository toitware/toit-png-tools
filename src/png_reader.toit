// Copyright (C) 2023 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import binary show BIG-ENDIAN byte-swap-32
import bytes show Buffer
import crypto.crc show *
import host.file
import monitor show Latch
import reader
import zlib

// The PNG file format is described in the specification:
// https://www.w3.org/TR/2003/REC-PNG-20031110/

HEADER_ ::= #[0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n']

COLOR-TYPE-GREYSCALE ::= 0
COLOR-TYPE-TRUECOLOR ::= 2
COLOR-TYPE-INDEXED ::= 3
COLOR-TYPE-GREYSCALE-ALPHA ::= 4
COLOR-TYPE-TRUECOLOR-ALPHA ::= 6

PREDICTOR-NONE_ ::= 0
PREDICTOR-SUB_ ::= 1
PREDICTOR-UP_ ::= 2
PREDICTOR-AVERAGE_ ::= 3
PREDICTOR-PAETH_ ::= 4

class Png:
  filename/string?
  bytes/ByteArray
  width/int
  height/int
  image-data/ByteArray
  image-data-position_/int := 0
  bit-depth/int
  color-type/int
  compression-method/int
  filter-method/int
  palette-r_/ByteArray? := null
  palette-g_/ByteArray? := null
  palette-b_/ByteArray? := null
  palette-a_/ByteArray? := null
  r-transparent_/int? := null
  g-transparent_/int? := null
  b-transparent_/int? := null
  pixel-width/int := 0  // Number of bits in a pixel.
  lookbehind-offset/int := 0  // How many bytes to look back to get previous pixel.
  previous-line_/ByteArray? := null
  decompressor_/zlib.Decoder
  done/Latch := Latch

  stringify:
    color-type-string/string := ?
    if color-type == COLOR-TYPE-GREYSCALE:
      color-type-string = "greyscale"
    else if color-type == COLOR-TYPE-TRUECOLOR:
      color-type-string = "truecolor"
    else if color-type == COLOR-TYPE-INDEXED:
      color-type-string = "indexed"
    else if color-type == COLOR-TYPE-GREYSCALE-ALPHA:
      color-type-string = "greyscale with alpha"
    else:
      assert: color-type == COLOR-TYPE-TRUECOLOR-ALPHA
      color-type-string = "truecolor with alpha"
    return "PNG, $(width)x$height, bit depth: $bit-depth, color type: $color-type-string"

  constructor.from-file filename/string:
    return Png --filename=filename
        file.read-content filename

  constructor .bytes --.filename/string?=null:
    pos := HEADER_.size
    if bytes.size < pos:
      throw "File too small" + (filename ? ": $filename" : "")
    if bytes[0..pos] != HEADER_:
      throw "Invalid PNG header" + (filename ? ": $filename" : "")
    ihdr := Chunk bytes pos: pos = it
    if ihdr.name != "IHDR":
      throw "First chunk is not IHDR" + (filename ? ": $filename" : "")
    width = BIG-ENDIAN.uint32 ihdr.data 0
    height = BIG-ENDIAN.uint32 ihdr.data 4
    image-data = ByteArray 4 * width * height
    bit-depth = ihdr.data[8]
    color-type = ihdr.data[9]
    compression-method = ihdr.data[10]
    filter-method = ihdr.data[11]
    if ihdr.data[12] != 0: throw "Interlaced images not supported"
    decompressor_ = zlib.Decoder
    //////////////////////////////////////////////////
    ensure-greyscale-palette_
    process-bit-depth_ bit-depth color-type filter-method
    byte-width := (width * pixel-width + 7) / 8
    previous-line_ = ByteArray byte-width
    task:: write-image-data byte-width
    while true:
      chunk := Chunk bytes pos : pos = it
      if chunk.name == "PLTE":
        handle-palette chunk
      else if chunk.name == "tRNS":
        handle-transparency chunk
      else if chunk.name == "IDAT":
        handle-image-data chunk
      else if chunk.name == "IEND":
        if pos != bytes.size:
          throw "Trailing data after IEND" + (filename ? ": $filename" : "")
        decompressor_.close
        done.get
        break
      else if chunk.name[0] & 0x20 == 0:
        throw "Unknown chunk $chunk.name" + (filename ? ": $filename" : "")

  process-bit-depth_ bit-depth/int color-type/int filter-method/int -> none:
    if filter-method != 0:
      throw "Unknown filter method"
    if bit-depth < 1 or not bit-depth.is-power-of-two:
      throw "Invalid bit depth"
    if color-type == COLOR-TYPE-GREYSCALE:
      if bit-depth > 16:
        throw "Invalid bit depth"
      pixel-width = bit-depth
      lookbehind-offset = bit-depth == 16 ? 2 : 1
    if color-type == COLOR-TYPE-TRUECOLOR:
      if not 8 <= bit-depth <= 16:
        throw "Invalid bit depth"
      pixel-width = 3 * bit-depth
      lookbehind-offset = pixel-width / 8
    if color-type == COLOR-TYPE-INDEXED:
      if bit-depth > 8:
        throw "Invalid bit depth"
      pixel-width = bit-depth
      lookbehind-offset = 1
    if color-type == COLOR-TYPE-GREYSCALE-ALPHA:
      if not 8 <= bit-depth <= 16:
        throw "Invalid bit depth"
      pixel-width = 2 * bit-depth
      lookbehind-offset = pixel-width / 8
    if color-type == COLOR-TYPE-TRUECOLOR-ALPHA:
      if not 8 <= bit-depth <= 16:
        throw "Invalid bit depth"
      pixel-width = 4 * bit-depth
      lookbehind-offset = pixel-width / 8

  handle-palette chunk/Chunk:
    if color-type != COLOR-TYPE-INDEXED:
      return  // Just a suggested palette.
    if chunk.size % 3 != 0:
      throw "Invalid palette size"
    palette-r_ = ByteArray (chunk.size / 3): chunk.data[it * 3]
    palette-g_ = ByteArray (chunk.size / 3): chunk.data[it * 3 + 1]
    palette-b_ = ByteArray (chunk.size / 3): chunk.data[it * 3 + 2]

  handle-transparency chunk/Chunk:
    if color-type == COLOR-TYPE-GREYSCALE:
      value := BIG-ENDIAN.uint16 chunk.data 0
      r-transparent_ = value
      if palette-a_:  // In case of 16 bit image.
        palette-a_[value] = 0
    else if color-type == COLOR-TYPE-TRUECOLOR:
      r-transparent_ = BIG-ENDIAN.uint16 chunk.data 0
      g-transparent_ = BIG-ENDIAN.uint16 chunk.data 2
      b-transparent_ = BIG-ENDIAN.uint16 chunk.data 4
    else if color-type == COLOR-TYPE-INDEXED:
      palette-a_.replace 0 chunk.data
    else:
      throw "Transparency chunk for non-indexed image"

  ensure-greyscale-palette_:
    if not palette-r_:
      if color-type == COLOR-TYPE-INDEXED:
        palette-a_ = ByteArray (1 << bit-depth): 255
      else if color-type == COLOR-TYPE-GREYSCALE or color-type == COLOR-TYPE-GREYSCALE-ALPHA:
        if bit-depth != 16:
          factor := [0, 255, 85, 0, 17, 0, 0, 0, 1][bit-depth]
          size := 1 << bit-depth
          palette-r_ = ByteArray size: it * factor
          palette-g_ = ByteArray size: it * factor
          palette-b_ = ByteArray size: it * factor
          palette-a_ = ByteArray size: 255

  handle-image-data chunk/Chunk:
    bytes-written := 0
    while bytes-written != chunk.data.size:
      bytes-written += decompressor_.write chunk.data[bytes-written..]

  write-image-data byte-width/int:
    reader := reader.BufferedReader decompressor_.reader
    while reader.can-ensure (byte-width + 1):
      data := reader.read-bytes (byte-width + 1)
      filter := data[0]
      line := data.copy 1
      if filter == PREDICTOR-SUB_:
        for i := lookbehind-offset; i < byte-width; i++:
          line[i] += line[i - lookbehind-offset]
      else if filter == PREDICTOR-UP_:
        byte-width.repeat:
          line[it] += previous-line_[it]
      else if filter == PREDICTOR-AVERAGE_:
        lookbehind-offset.repeat:
          line[it] += previous-line_[it] >> 1
        for i := lookbehind-offset; i < byte-width; i++:
          line[i] += (line[i - lookbehind-offset] + previous-line_[i]) >> 1
      else if filter == PREDICTOR-PAETH_:
        lookbehind-offset.repeat:
          line[it] += paeth_ 0 previous-line_[it] 0
        for i := lookbehind-offset; i < byte-width; i++:
          line[i] += paeth_ line[i - lookbehind-offset] previous-line_[i] previous-line_[i - lookbehind-offset]
      else if filter != PREDICTOR-NONE_:
        throw "Unknown filter type: $filter"
      previous-line_ = line
      if bit-depth == 1:
        width.repeat:
          index := (line[it >> 3] >> (7 - (it & 7))) & 1
          image-data[image-data-position_++] = palette-r_[index]
          image-data[image-data-position_++] = palette-g_[index]
          image-data[image-data-position_++] = palette-b_[index]
          image-data[image-data-position_++] = palette-a_[index]
      else if bit-depth == 2:
        width.repeat:
          index := (line[it >> 2] >> (6 - ((it & 3) << 1))) & 3
          image-data[image-data-position_++] = palette-r_[index]
          image-data[image-data-position_++] = palette-g_[index]
          image-data[image-data-position_++] = palette-b_[index]
          image-data[image-data-position_++] = palette-a_[index]
      else if bit-depth == 4:
        width.repeat:
          index := (line[it >> 1] >> (4 - ((it & 1) << 2))) & 0xf
          image-data[image-data-position_++] = palette-r_[index]
          image-data[image-data-position_++] = palette-g_[index]
          image-data[image-data-position_++] = palette-b_[index]
          image-data[image-data-position_++] = palette-a_[index]
      else if bit-depth == 8:
        if color-type == COLOR-TYPE-INDEXED or color-type == COLOR-TYPE-GREYSCALE:
          width.repeat:
            index := line[it]
            image-data[image-data-position_++] = palette-r_[index]
            image-data[image-data-position_++] = palette-g_[index]
            image-data[image-data-position_++] = palette-b_[index]
            image-data[image-data-position_++] = palette-a_[index]
        else if color-type == COLOR-TYPE-GREYSCALE-ALPHA:
          width.repeat:
            pix := line[it << 1]
            image-data[image-data-position_++] = pix
            image-data[image-data-position_++] = pix
            image-data[image-data-position_++] = pix
            image-data[image-data-position_++] = line[(it << 1) + 1]
        else if color-type == COLOR-TYPE-TRUECOLOR:
          width.repeat:
            r := line[it * 3]
            g := line[it * 3 + 1]
            b := line[it * 3 + 2]
            image-data[image-data-position_++] = r
            image-data[image-data-position_++] = g
            image-data[image-data-position_++] = b
            if r == r-transparent_ and g == g-transparent_ and b == b-transparent_:
              image-data[image-data-position_++] = 0
            else:
              image-data[image-data-position_++] = 255
        else if color-type == COLOR-TYPE-TRUECOLOR-ALPHA:
          image-data.replace image-data-position_ line
          image-data-position_ += width << 2
      else:
        assert: bit-depth == 16
        if color-type == COLOR-TYPE-GREYSCALE:
          width.repeat:
            value := BIG-ENDIAN.uint16 line (it << 1)
            image-data[image-data-position_++] = value >> 8
            image-data[image-data-position_++] = value >> 8
            image-data[image-data-position_++] = value >> 8
            if r-transparent_ == value:
              image-data[image-data-position_++] = 0
            else:
              image-data[image-data-position_++] = 255
        else if color-type == COLOR-TYPE-GREYSCALE-ALPHA:
          width.repeat:
            value := BIG-ENDIAN.uint16 line (it << 2)
            alpha := BIG-ENDIAN.uint16 line ((it << 2) + 2)
            image-data[image-data-position_++] = value >> 8
            image-data[image-data-position_++] = value >> 8
            image-data[image-data-position_++] = value >> 8
            image-data[image-data-position_++] = alpha >> 8
        else if color-type == COLOR-TYPE-TRUECOLOR:
          width.repeat:
            r := BIG-ENDIAN.uint16 line (it * 6)
            g := BIG-ENDIAN.uint16 line (it * 6 + 2)
            b := BIG-ENDIAN.uint16 line (it * 6 + 4)
            image-data[image-data-position_++] = r >> 8
            image-data[image-data-position_++] = g >> 8
            image-data[image-data-position_++] = b >> 8
            if r == r-transparent_ and g == g-transparent_ and b == b-transparent_:
              image-data[image-data-position_++] = 0
            else:
              image-data[image-data-position_++] = 255
        else if color-type == COLOR-TYPE-TRUECOLOR-ALPHA:
          width.repeat:
            r := BIG-ENDIAN.uint16 line (it << 3)
            g := BIG-ENDIAN.uint16 line ((it << 3) + 2)
            b := BIG-ENDIAN.uint16 line ((it << 3) + 4)
            a := BIG-ENDIAN.uint16 line ((it << 3) + 6)
            image-data[image-data-position_++] = r >> 8
            image-data[image-data-position_++] = g >> 8
            image-data[image-data-position_++] = b >> 8
            image-data[image-data-position_++] = a >> 8
    if image-data-position_ != image-data.size:
      throw "Not enough image data"
    done.set null

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

  constructor byte-array position [position-updater]:
    size = BIG-ENDIAN.uint32 byte-array position
    name = byte-array[position + 4..position + 8].to-string
    data = byte-array[position + 8..position + 8 + size]
    checksum := BIG-ENDIAN.uint32 byte-array position + 8 + size
    calculated-checksum := crc32 byte-array[position + 4..position + 8 + size]
    if checksum != calculated-checksum:
      throw "Invalid checksum"
    position-updater.call position + size + 12

main:
  png := Png.from-file "test.png"
  print png
