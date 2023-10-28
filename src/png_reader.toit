// Copyright (C) 2023 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import binary show BIG-ENDIAN byte-swap-32 LITTLE-ENDIAN
import bytes show Buffer
import crypto.crc show *
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

/**
A PNG reader that converts all PNG files into
  32 bit per pixel RGBA format.
*/
class PngRgba:

/**
A PNG reader that converts all PNG files into
  a decompressed format with the bit depths
  and color types of the original file.
*/
class PngReader:

/**
A PNG reader that gives random access to the
  decompressed pixel data.  Bit widths other
  than 8 are expanded/truncated on demand.

Available formats are 8-bit palette (with
  alpha, and 32-bit RGBA.  Grayscale and
  palette with 1/2/4 bits per pixel are
  delivered as 8-bit palette.

The PNG must be uncompressed to give random
  access.  Such PNGs are created by the
  pngunzip tool from this repository - see
  https://github.com/toitware/toit-png-tools/releases.
*/
class PngRandomAccess extends Png:
  // A sequence of y-coordinates and file positions for uncompressed lines.
  // The uncompressed data includes a filter byte for each line, which
  // must always be 0 (no predictor).
  uncompressed-line-offsets_ := []


  constructor .bytes --filename/string?=null:
    super bytes --filename=filename
    if image-data-is-uncompressed_ bytes pos:
      print "Uncompressed image data"
      print uncompressed-line-offsets_
    else:
      uncompressed-line-offsets_ = []

class Png:
  filename/string?
  bytes/ByteArray
  width/int
  height/int
  image-data/ByteArray? := null
  image-data-position_/int := 0
  bit-depth/int
  color-type/int
  compression-method/int
  filter-method/int
  palette/ByteArray? := null
  saved-chunks/Map := {:}
  palette-a_/ByteArray? := null
  r-transparent_/int? := null
  g-transparent_/int? := null
  b-transparent_/int? := null
  pixel-width/int := 0  // Number of bits in a pixel.
  byte-width/int := 0   // Number of bytes in a line.
  lookbehind-offset/int := 0  // How many bytes to look back to get previous pixel.
  previous-line_/ByteArray? := null
  decompressor_/zlib.CopyingInflater
  done/Latch := Latch
  convert-to-rgba/bool

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

  constructor .bytes --.filename/string?=null --.convert-to-rgba/bool?=true:
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
    bit-depth = ihdr.data[8]
    color-type = ihdr.data[9]
    compression-method = ihdr.data[10]
    filter-method = ihdr.data[11]
    if ihdr.data[12] != 0: throw "Interlaced images not supported"
    decompressor_ = zlib.CopyingInflater
    //////////////////////////////////////////////////
    process-bit-depth_ bit-depth color-type filter-method
    byte-width = (width * pixel-width + 7) / 8
    if convert-to-rgba:
      image-data = ByteArray (4 * width * height)
    else:
      image-data = ByteArray (byte-width * height)
    previous-line_ = ByteArray byte-width
    task:: write-image-data
    while true:
      chunk := Chunk bytes pos : pos = it
      if chunk.name == "PLTE":
        handle-palette chunk
      else if chunk.name == "tRNS":
        handle-transparency chunk
      else if chunk.name == "IDAT":
        ensure-alpha-palette_ (1 << bit-depth)
        ensure-rgb-palette_ (1 << bit-depth)
        handle-image-data chunk
      else if chunk.name == "IEND":
        if pos != bytes.size:
          throw "Trailing data after IEND" + (filename ? ": $filename" : "")
        decompressor_.close
        done.get
        break
      else if chunk.name[0] & 0x20 == 0:
        throw "Unknown chunk $chunk.name" + (filename ? ": $filename" : "")

  /**
  Check that the image data is uncompressed, meaning it is all literal
    zlib blocks with no compression.  We need this to be able to access
    the image data directly without decompressing it.
  Image data in PNG is divided up into separate IDAT chunks, which are
    independent of the zlib stream, and we also check that no line of image
    data is split between two IDAT chunks.
  The literal zlib blocks have a 16 bit size, so they cannot be more than 64k
    large.  We check that no line of image data is split between two literal
    blocks.
  The PNG format specifies a predictor byte for each line of image data.
    A non-trivial value for this makes the lines depend on each other and
    we cannot access them independently, so we return false in this case.
  */
  image-data-is-uncompressed_ bytes/ByteArray pos/int -> bool:
    y := 0
    found-header := false
    literal-bytes-left-in-block := 0
    end-of-zlib-stream := false

    while true:
      file-offset := 0
      chunk := Chunk bytes pos: | position-after-chunk chunk-data-position |
        pos = position-after-chunk
        file-offset = chunk-data-position
      if chunk.name == "IDAT":
        chunk-pos := 0
        // A chunk of zlib-encoded data.  Check to see if it's actually
        // uncompressed data.
        if not found-header:
          chunk-pos += 2
          found-header = true
        while chunk-pos != chunk.size:
          if chunk-pos > chunk.size:
            print "Chopped up"
            return false  // Some zlib control bytes were chopped up.
          if literal-bytes-left-in-block != 0:
            // Record line position in PNG file.
            uncompressed-line-offsets_.add y
            uncompressed-line-offsets_.add (file-offset + chunk-pos)

            next-part-of-block := min (chunk.data.size - chunk-pos) literal-bytes-left-in-block
            if next-part-of-block % (byte-width + 1) != 0:
              print "next-part-of-block $next-part-of-block, $byte-width"
              return false  // Chunk boundary and line boundary don't match.
            for i := 0; i < next-part-of-block; i += byte-width + 1:
              y++
              if chunk.data[chunk-pos + i] != 0:
                return false  // Non-trivial predictor byte.
            literal-bytes-left-in-block -= next-part-of-block
            chunk-pos += next-part-of-block
          else:
            // Next zlib block has a 3-bit intro.  If it's a literal block, the
            // full size of the intro is 5 bytes.
            if end-of-zlib-stream:
              return true
            block-bits := chunk.data[chunk_pos] & 7
            if block-bits & 6 != 0:
              return false  // Not uncompressed.
            if block-bits & 1 == 1:
              end-of-zlib-stream = true
            literal-bytes-left-in-block = LITTLE-ENDIAN.uint16 chunk.data (chunk-pos + 1)
            chunk-pos += 5
            if literal-bytes-left-in-block % (byte-width + 1) != 0:
              // Zlib literal block size and line width don't match.
              return false
      else:
        // Skip unknown chunks at this stage.

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
    saved-chunks[chunk.name] = chunk.data
    if color-type != COLOR-TYPE-INDEXED:
      return  // Just a suggested palette.
    if chunk.size % 3 != 0:
      throw "Invalid palette size"
    palette = chunk.data

  handle-transparency chunk/Chunk:
    saved-chunks[chunk.name] = chunk.data
    if color-type == COLOR-TYPE-GREYSCALE:
      value := BIG-ENDIAN.uint16 chunk.data 0
      ensure-alpha-palette_ (value + 1)
      r-transparent_ = value
      if palette-a_:  // Skip this for 16 bit image.
        palette-a_[value] = 0
    else if color-type == COLOR-TYPE-TRUECOLOR:
      r-transparent_ = BIG-ENDIAN.uint16 chunk.data 0
      g-transparent_ = BIG-ENDIAN.uint16 chunk.data 2
      b-transparent_ = BIG-ENDIAN.uint16 chunk.data 4
    else if color-type == COLOR-TYPE-INDEXED:
      ensure-alpha-palette_ chunk.data.size
      palette-a_.replace 0 chunk.data
    else:
      throw "Transparency chunk for non-indexed image"

  ensure-alpha-palette_ min-size/int:
    if bit-depth <= 8 and not palette-a_:
      if color-type == COLOR-TYPE-INDEXED:
        palette-a_ = ByteArray (max min-size (1 << bit-depth)): 255
      else if color-type == COLOR-TYPE-GREYSCALE or color-type == COLOR-TYPE-GREYSCALE-ALPHA:
        if bit-depth != 16:
          size := 1 << bit-depth
          palette-a_ = ByteArray (max min-size size): 255

  ensure-rgb-palette_ min-size/int:
    if bit-depth <= 8 and not palette:
      if color-type == COLOR-TYPE-INDEXED:
        throw "No palette for indexed image"
      else if color-type == COLOR-TYPE-GREYSCALE or color-type == COLOR-TYPE-GREYSCALE-ALPHA:
        if bit-depth <= 4:
          factor := [0, 255, 85, 0, 17, 0, 0, 0, 1][bit-depth]
          size := 1 << bit-depth
          palette = ByteArray (size * 3): (it / 3) * factor

  handle-image-data chunk/Chunk:
    bytes-written := 0
    while bytes-written != chunk.data.size:
      bytes-written += decompressor_.write chunk.data[bytes-written..]

  write-image-data:
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
      pal := palette or (ByteArray 768: it / 3)

      if not convert-to-rgba:
        image-data.replace image-data-position_ line
        image-data-position_ += byte-width
        continue

      if bit-depth == 1:
        width.repeat:
          index := (line[it >> 3] >> (7 - (it & 7))) & 1
          image-data[image-data-position_++] = pal[index * 3 + 0]
          image-data[image-data-position_++] = pal[index * 3 + 1]
          image-data[image-data-position_++] = pal[index * 3 + 2]
          image-data[image-data-position_++] = palette-a_[index]
      else if bit-depth == 2:
        width.repeat:
          index := (line[it >> 2] >> (6 - ((it & 3) << 1))) & 3
          image-data[image-data-position_++] = pal[index * 3 + 0]
          image-data[image-data-position_++] = pal[index * 3 + 1]
          image-data[image-data-position_++] = pal[index * 3 + 2]
          image-data[image-data-position_++] = palette-a_[index]
      else if bit-depth == 4:
        width.repeat:
          index := (line[it >> 1] >> (4 - ((it & 1) << 2))) & 0xf
          image-data[image-data-position_++] = pal[index * 3 + 0]
          image-data[image-data-position_++] = pal[index * 3 + 1]
          image-data[image-data-position_++] = pal[index * 3 + 2]
          image-data[image-data-position_++] = palette-a_[index]
      else if bit-depth == 8:
        if color-type == COLOR-TYPE-INDEXED or color-type == COLOR-TYPE-GREYSCALE:
          width.repeat:
            index := line[it]
            image-data[image-data-position_++] = pal[index * 3 + 0]
            image-data[image-data-position_++] = pal[index * 3 + 1]
            image-data[image-data-position_++] = pal[index * 3 + 2]
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
    position-updater.call (position + size + 12) (position + 8)
