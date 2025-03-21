// Copyright (C) 2023 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import io show BIG-ENDIAN LITTLE-ENDIAN
import bitmap
import bitmap show blit bytemap-zap
import bytes show Buffer
import crypto.crc show *
import monitor show Latch
import reader
import zlib

// The PNG file format is described in the specification:
// https://www.w3.org/TR/2003/REC-PNG-20031110/

HEADER_ ::= #[0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n']

COLOR-TYPE-GRAYSCALE ::= 0
COLOR-TYPE-TRUECOLOR ::= 2
COLOR-TYPE-INDEXED ::= 3
COLOR-TYPE-GRAYSCALE-ALPHA ::= 4
COLOR-TYPE-TRUECOLOR-ALPHA ::= 6

PREDICTOR-NONE_ ::= 0
PREDICTOR-SUB_ ::= 1
PREDICTOR-UP_ ::= 2
PREDICTOR-AVERAGE_ ::= 3
PREDICTOR-PAETH_ ::= 4


rgb-to-gray_ r/int g/int b/int -> int:
  // Standard weights for RGB to gray conversion.
  RED-WEIGHT ::= 77
  GREEN-WEIGHT ::= 150
  BLUE-WEIGHT ::= 29
  WEIGHT-SHIFT ::= 8
  return (r * RED-WEIGHT + g * GREEN-WEIGHT + b * BLUE-WEIGHT) >> WEIGHT-SHIFT

/**
A PNG reader that converts all PNG files into
  32 bit per pixel RGBA format.
*/
class PngRgba extends PngDecompressor_:
  constructor bytes/ByteArray --filename/string?=null:
    super bytes --filename=filename --convert-to-rgba

  get-indexed-image-data line/int to-line/int --accept-8-bit/bool --need-gray-palette/bool [block] -> none:
    unreachable

blit-map-cache_ := Map.weak

get-blit-map_ color/int -> ByteArray:
  blit-map := blit-map-cache_.get color
  if blit-map: return blit-map
  blit-map = ByteArray 256: | byte |
    nibble := 0
    if  byte >> 6      == color: nibble |= 8
    if (byte >> 4) & 3 == color: nibble |= 4
    if (byte >> 2) & 3 == color: nibble |= 2
    if  byte       & 3 == color: nibble |= 1
    nibble  // Initialize the byte array with the last value in the block.
  blit-map-cache_[color] = blit-map
  return blit-map

/**
A PNG reader that converts all PNG files into
  a decompressed format with the bit depths
  and color types of the original file.
*/
class Png extends PngDecompressor_:
  constructor bytes/ByteArray --filename/string?=null:
    super bytes --filename=filename --no-convert-to-rgba

  /// See super.
  get-indexed-image-data line/int to-line/int --accept-8-bit/bool --need-gray-palette/bool [block] -> none:
    source-slice-block :=: | y-from y-to |
      image-data[y-from * byte-width .. y-to * byte-width]
    get-indexed-image-data-helper_ line to-line accept-8-bit byte-width need-gray-palette block source-slice-block

/**
Scans a Png file for useful information, without decompressing the image data.
*/
class PngInfo extends PngScanner_:
  uncompressed_ := false

  constructor bytes/ByteArray --filename/string?=null:
    super bytes --filename=filename
    uncompressed_ = scan-uncompressed-image-data_ bytes --save-chunks --record-line-location=: null

  /**
  Returns true if the image data in the PNG is uncompressed, and all
    scanlines are each present in one continuous byte range that does
    not depend on the other scanlines.
  */
  uncompressed-random-access -> bool:
    return uncompressed_

  /**
  Compression ratio in percent, relative to a 32 bit per pixel RGBA image with
    no headers or metadata.
  Normally returns a percentage less than 100, but could return about 200 for
    a 16 bit image.
  */
  compression-ratio-rgba -> float:
    rgba-size := width * height * 4
    return (bytes.size.to-float * 100) / rgba-size

  /**
  Compression ratio in percent, relative to a 24 bit per pixel RGB image with
    no headers or metadata and no transparency information.  The returned
    value is similar to the file size relative to a PNM file with the same
    image data.
  Normally returns a percentage less than 100, but could return about 200 for
    a 16 bit image.
  */
  compression-ratio-rgb -> float:
    rgb-size := width * height * 3
    return (bytes.size.to-float * 100) / rgb-size

  /**
  Compression ratio in percent, relative to an uncompressed image stored with
    the same bit depth and color type, with no headers or metadata.
  Normally returns a percentage less than 100.
  */
  compression-ratio -> float:
    uncompressed-size := byte-width * height
    return (bytes.size.to-float * 100) / uncompressed-size

  get-indexed-image-data line/int to-line/int --accept-8-bit/bool --need-gray-palette/bool [block] -> none:
    unreachable

/**
A PNG reader that gives random access to the decompressed pixel data.  Bit
  widths smaller than 8 are expanded on demand.  See $get-indexed-image-data.

Available image types formats are indexed (palette) and grayscale.

This class is intended for use with PNGs produced by the pngunzip tool in bin/.
Such PNGs may have a compact representation, like 2 bits per pixel, but they
are not compressed. Therefore we have random access to the pixel data. They are
designed to be kept in flash and used for UI elements that are almost always in
use.

For UI elements that are large in number, but seldom in use it may be better to
use the PngUncompressed class, which decompresses to RAM when it is used.
*/
class PngRandomAccess extends PngScanner_:
  // A sequence of y-coordinates and file positions for uncompressed lines.
  // The uncompressed data includes a filter byte for each line, which
  // must always be 0 (no predictor).
  uncompressed-line-offsets_ := []

  constructor bytes/ByteArray --filename/string?=null:
    super bytes --filename=filename
    process-bit-depth_ bit-depth color-type
    uncompressed := scan-uncompressed-image-data_ bytes --record-line-location=: | y offset |
      uncompressed-line-offsets_.add y
      uncompressed-line-offsets_.add offset

    if not uncompressed:
      throw "PNG is not uncompressed" + (filename ? ": $filename" : "")

  // See super.
  get-indexed-image-data line/int to-line/int --accept-8-bit/bool --need-gray-palette/bool [block] -> none:
    offsets := uncompressed-line-offsets_
    source-line-stride := byte-width + 1  // Because of the filter byte.
    // Although the PNG is uncompressed, the image data may not be contiguous
    // since the zlib blocks have a maximum size.  Find the correct block for
    // the first line.
    for i := 0; i < offsets.size; i += 2:
      top := max line offsets[i]
      bottom := min
          to-line
          i + 2 == offsets.size ? height : offsets[i + 2]
      if top >= bottom: continue
      index := uncompressed-line-offsets_[i + 1] - top * source-line-stride
      source-slice-block :=: | y-from y-to |
        bytes[index + 1 + y-from * source-line-stride .. index + y-to * source-line-stride]
      get-indexed-image-data-helper_ top bottom accept-8-bit source-line-stride need-gray-palette block source-slice-block

abstract class PngScanner_ extends AbstractPng:
  constructor bytes/ByteArray --filename/string?=null:
    super bytes --filename=filename

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
  scan-uncompressed-image-data_ bytes/ByteArray --save-chunks/bool=false [--record-line-location] -> bool:
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
        ensure-alpha-palette_ (1 << bit-depth)
        ensure-rgb-palette_ (1 << bit-depth)
        chunk-pos := 0
        // A chunk of zlib-encoded data.  Check to see if it's actually
        // uncompressed data.
        if not found-header:
          chunk-pos += 2
          found-header = true
        while chunk-pos != chunk.size:
          if chunk-pos > chunk.size:
            return false  // Some zlib control bytes were chopped up.
          if literal-bytes-left-in-block != 0:
            // Record line position in PNG file.
            record-line-location.call y (file-offset + chunk-pos)

            next-part-of-block := min (chunk.data.size - chunk-pos) literal-bytes-left-in-block
            if next-part-of-block % (byte-width + 1) != 0:
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
              chunk-pos += 4  // Skip checksum bytes.
              continue
            block-bits := chunk.data[chunk-pos] & 7
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
        if chunk.name == "PLTE":
          handle-palette chunk
        else if chunk.name == "tRNS":
          handle-transparency chunk
        else if chunk.name == "IEND":
          return true
        if save-chunks:
          saved-chunks[chunk.name] = chunk.data

abstract class AbstractPng:
  filename/string?
  bytes/ByteArray
  width/int
  height/int
  bit-depth/int
  color-type/int
  pos := 0
  palette_/ByteArray := #[]
  gray-palette_/ByteArray? := null
  saved-chunks/Map := {:}
  palette-a_/ByteArray := #[]
  r-transparent_/int? := null
  g-transparent_/int? := null
  b-transparent_/int? := null
  pixel-width/int := 0  // Number of bits in a pixel.
  byte-width/int := 0   // Number of bytes in a line.
  lookbehind-offset/int := 0  // How many bytes to look back to get previous pixel.
  previous-line_/ByteArray? := null

  constructor .bytes --.filename/string?:
    pos = HEADER_.size
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
    if ihdr.data[10] != 0: throw "Unknown compression method"
    if ihdr.data[11] != 0: throw "Unknown filter method"
    if ihdr.data[12] != 0: throw "Interlaced images not supported"
    process-bit-depth_ bit-depth color-type

  process-bit-depth_ bit-depth/int color-type/int -> none:
    if bit-depth < 1 or not bit-depth.is-power-of-two:
      throw "Invalid bit depth"
    if color-type == COLOR-TYPE-GRAYSCALE:
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
    if color-type == COLOR-TYPE-GRAYSCALE-ALPHA:
      if not 8 <= bit-depth <= 16:
        throw "Invalid bit depth"
      pixel-width = 2 * bit-depth
      lookbehind-offset = pixel-width / 8
    if color-type == COLOR-TYPE-TRUECOLOR-ALPHA:
      if not 8 <= bit-depth <= 16:
        throw "Invalid bit depth"
      pixel-width = 4 * bit-depth
      lookbehind-offset = pixel-width / 8
    byte-width = (width * pixel-width + 7) / 8

  /**
  Returns a ByteArray describing the palette for the PNG, with
    three bytes per index in the order RGBRGBRGB...
  If the image is true-color or true-color with alpha, or
    gray-scale with alpha, returns a zero length byte array.
  */
  palette -> ByteArray:
    return palette_

  gray-palette -> ByteArray:
    if not gray-palette_:
      if palette_.size == 0:
        gray-palette_ = #[]
      else:
        gray-palette_ = ByteArray (palette_.size - 2):
          if it % 3 == 0:
            r := palette_[it]
            g := palette_[it + 1]
            b := palette_[it + 2]
            rgb-to-gray_ r g b
          else:
            0
    return gray-palette_

  /**
  Returns a ByteArray describing the alpha-palette for the PNG, with
    one bytes per index where 0 is transparent and 255 is opaque.
  If the image is true-color or true-color with alpha, or
    gray-scale with alpha, returns a zero length byte array.
  */
  alpha-palette -> ByteArray:
    return palette-a_

  /**
  Gets the image data for the given lines.
  The pixel data should be read in connection with $palette.
  In compressed PNGs this method may cause a lot of image data to be
    decompressed, especially if this method is not called in order
    of non-descending $line.
  It is assumed that 1-bit image data is always allowed, but some
    callers can also used 8-bit indexed image data, indicated with
    $accept-8-bit.
  If the caller can only handle gray-scale images, the $need-gray-palette flag
    should be set.  In this case the palette entries passed to the block will
    contain a weighted average of the red, green, and blue intensities.
  Throws an exception if the PNG is in RGB, RGBA, or gray-with-alpha format.
  Guard against this by checking whether $color-type returns
    $COLOR-TYPE-TRUECOLOR, $COLOR-TYPE-TRUECOLOR-ALPHA, or
    $COLOR-TYPE-GRAYSCALE-ALPHA.
  The block is called with the arguments line-from, line-to, bits-per-pixel,
    pixel-byte-array, line-stride, palette, alpha-palette.  bits-per-pixel is
    always 1 or 8
  The block may be called multiple times.  The pixel byte array may be larger
    than needed, and the caller should only use the first line-to - line-from
    lines.
  */
  abstract get-indexed-image-data line/int to-line/int --accept-8-bit/bool --need-gray-palette/bool [block] -> none

  stringify:
    color-type-string/string := color-type-to-string color-type
    return "PNG, $(width)x$height, bit depth: $bit-depth, color type: $color-type-string"

  handle-palette chunk/Chunk:
    saved-chunks[chunk.name] = chunk.data
    if color-type != COLOR-TYPE-INDEXED:
      return  // Just a suggested palette.
    if chunk.size % 3 != 0:
      throw "Invalid palette size"
    palette_ = chunk.data

  handle-transparency chunk/Chunk:
    saved-chunks[chunk.name] = chunk.data
    if color-type == COLOR-TYPE-GRAYSCALE:
      value := BIG-ENDIAN.uint16 chunk.data 0
      ensure-alpha-palette_ (value + 1)
      r-transparent_ = value
      if palette-a_.size != 0:  // Skip this for 16 bit image.
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
    if bit-depth <= 8 and palette-a_.size == 0:
      if color-type == COLOR-TYPE-INDEXED:
        palette-a_ = ByteArray (max min-size (1 << bit-depth)): 255
      else if color-type == COLOR-TYPE-GRAYSCALE or color-type == COLOR-TYPE-GRAYSCALE-ALPHA:
        if bit-depth != 16:
          size := 1 << bit-depth
          palette-a_ = ByteArray (max min-size size): 255

  ensure-rgb-palette_ min-size/int:
    if bit-depth <= 8 and palette_.size == 0:
      if color-type == COLOR-TYPE-INDEXED:
        throw "No palette for indexed image"
      else if color-type == COLOR-TYPE-GRAYSCALE or color-type == COLOR-TYPE-GRAYSCALE-ALPHA:
        if bit-depth <= 4:
          factor := [0, 255, 85, 0, 17, 0, 0, 0, 1][bit-depth]
          size := 1 << bit-depth
          palette_ = ByteArray (size * 3): (it / 3) * factor

  get-indexed-image-data-helper_ line to-line accept-8-bit source-line-stride/int need-gray-palette/bool [block] [source-slice-block]:
    if color-type == COLOR-TYPE-TRUECOLOR-ALPHA or color-type == COLOR-TYPE-TRUECOLOR or color-type == COLOR-TYPE-GRAYSCALE-ALPHA:
      throw "PNG is not palette or grayscale"
    if bit-depth == 16:
      throw "PNG is 16 bit per pixel"
    palette-argument := need-gray-palette ? gray-palette : palette
    if bit-depth == 1 or (bit-depth == 8 and accept-8-bit):
      source := source-slice-block.call line to-line
      block.call line to-line bit-depth source source-line-stride palette-argument alpha-palette
    else if bit-depth == 2 and not accept-8-bit:
      get-two-bit-as-four-one-bit-draws_ line to-line need-gray-palette source-line-stride block source-slice-block
    else if accept-8-bit:
      get-two-or-four-bit-as-eight-bit-draws_ line to-line palette-argument source-line-stride block source-slice-block
    else:
      throw "This display can't handle $(bit-depth)-bit PNGs"

  // Takes 2-bit data and converts it to up to 4 one-bit draws.  For example,
  // if the palette has red, black, and transparent then we will draw a red
  // bitmap, and a black bitmap.  Since this is for displays that don't support
  // partial transparency we allow a little slack in the PNG:
  // Almost-transparent pixels are ignored (drawn as transparent), and
  // almost-opaque pixels are drawn as opaque.
  get-two-bit-as-four-one-bit-draws_ y-from/int y-to/int need-gray-palette/bool bytes-per-line/int [block] [get-source-slice]:
    one-bit-byte-width := (width + 7) >> 3
    buffer-height := min
        height
        max 1 (4096 / one-bit-byte-width)
    List.chunk-up y-from y-to buffer-height: | y-from-2 y-to-2 |
      source := get-source-slice.call y-from-2 y-to-2
      buffer := buffers_.loan ((y-to-2 - y-from-2) * one-bit-byte-width)
      try:
        4.repeat: | palette-index |
          alpha := alpha-palette[palette-index]
          ALMOST-OPAQUE ::= 0xf0
          ALMOST-TRANSPARENT ::= 0x0f
          if alpha > ALMOST-TRANSPARENT and palette_.size > palette-index * 3:
            if alpha < ALMOST-OPAQUE: throw "No partially transparent PNGs on this display"
            blit
                source
                buffer
                (byte-width + 1) >> 1  // Pixels per line
                --shift=4
                --source-pixel-stride=2
                --source-line-stride=bytes-per-line
                --destination-line-stride=one-bit-byte-width
                --lookup-table=(get-blit-map_ palette-index)
            blit
                source[1..]
                buffer
                byte-width >> 1  // Pixels per line
                --source-pixel-stride=2
                --source-line-stride=bytes-per-line
                --destination-line-stride=one-bit-byte-width
                --lookup-table=(get-blit-map_ palette-index)
                --operation=bitmap.OR
            pr := palette_[palette-index * 3]
            pg := palette_[palette-index * 3 + 1]
            pb := palette_[palette-index * 3 + 2]
            bit-palette := #[0, 0, 0, pr, pg, pb]
            if need-gray-palette:
              bit-palette[3] = rgb-to-gray_ pr pg pb
            block.call y-from-2 y-to-2 1 buffer one-bit-byte-width bit-palette #[0, 0xff]
      finally:
        buffers_.put-back buffer

  // Takes 2-bit or 4-bit image data and blows it up to 8-bit data
  // that can be drawn with the bitmap primitives.
  get-two-or-four-bit-as-eight-bit-draws_ y-from/int y-to/int palette-argument/ByteArray bytes-per-line/int [block] [get-source-slice]:
    buffer-height := min
        height
        max 1 (4096 / width)
    List.chunk-up y-from y-to buffer-height: | y-from-2 y-to-2 |
      source := get-source-slice.call y-from-2 y-to-2
      buffer := buffers_.loan ((y-to-2 - y-from-2) * width)
      try:
        expansion := 8 / bit-depth
        mask := (1 << bit-depth) - 1
        shift-rights := (bit-depth == 2) ? "\x06\x04\x02\x00" : "\x04\x00"
        expansion.repeat: | shift |
          blit
              source
              buffer[shift..]                              // Destination.
              (width + expansion - 1 - shift) / expansion  // Pixels per line.
              --shift=shift-rights[shift]                  // Shift right 6, 4, 2, 0 bits.
              --mask=mask                                  // Mask out the other 6 bits.
              --source-line-stride=bytes-per-line
              --destination-pixel-stride=expansion
              --destination-line-stride=width
        block.call y-from-2 y-to-2 8 buffer width palette-argument alpha-palette
      finally:
        buffers_.put-back buffer

color-type-to-string color-type/int -> string:
  if color-type == COLOR-TYPE-GRAYSCALE:
    return "grayscale"
  if color-type == COLOR-TYPE-TRUECOLOR:
    return "truecolor"
  if color-type == COLOR-TYPE-INDEXED:
    return "indexed"
  if color-type == COLOR-TYPE-GRAYSCALE-ALPHA:
    return "grayscale with alpha"
  else:
    assert: color-type == COLOR-TYPE-TRUECOLOR-ALPHA
    return "truecolor with alpha"

abstract class PngDecompressor_ extends AbstractPng:
  image-data/ByteArray? := null
  image-data-position_/int := 0
  convert-to-rgba_/bool
  decompressor_/zlib.CopyingInflater
  done/Latch := Latch

  constructor bytes/ByteArray --filename/string?=null --convert-to-rgba/bool?:
    convert-to-rgba_ = convert-to-rgba
    decompressor_ = zlib.CopyingInflater
    super bytes --filename=filename
    if convert-to-rgba_:
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
        decompressor_.out.close
        done.get
        break
      else if chunk.name[0] & 0x20 == 0:
        throw "Unknown chunk $chunk.name" + (filename ? ": $filename" : "")

  handle-image-data chunk/Chunk:
    bytes-written := 0
    while bytes-written != chunk.data.size:
      bytes-written += decompressor_.out.write chunk.data[bytes-written..]

  write-image-data:
    reader := decompressor_.in
    for y := 0; reader.try-ensure-buffered (byte-width + 1); y++:
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
      palette := ?
      if palette_.size != 0:
        palette = palette_
      else:
        palette = ByteArray 768: it / 3

      if not convert-to-rgba_:
        image-data.replace image-data-position_ line
        image-data-position_ += byte-width
        continue

      if bit-depth == 1:
        width.repeat:
          index := (line[it >> 3] >> (7 - (it & 7))) & 1
          image-data[image-data-position_++] = palette[index * 3 + 0]
          image-data[image-data-position_++] = palette[index * 3 + 1]
          image-data[image-data-position_++] = palette[index * 3 + 2]
          image-data[image-data-position_++] = palette-a_[index]
      else if bit-depth == 2:
        width.repeat:
          index := (line[it >> 2] >> (6 - ((it & 3) << 1))) & 3
          image-data[image-data-position_++] = palette[index * 3 + 0]
          image-data[image-data-position_++] = palette[index * 3 + 1]
          image-data[image-data-position_++] = palette[index * 3 + 2]
          image-data[image-data-position_++] = palette-a_[index]
      else if bit-depth == 4:
        width.repeat:
          index := (line[it >> 1] >> (4 - ((it & 1) << 2))) & 0xf
          image-data[image-data-position_++] = palette[index * 3 + 0]
          image-data[image-data-position_++] = palette[index * 3 + 1]
          image-data[image-data-position_++] = palette[index * 3 + 2]
          image-data[image-data-position_++] = palette-a_[index]
      else if bit-depth == 8:
        if color-type == COLOR-TYPE-INDEXED or color-type == COLOR-TYPE-GRAYSCALE:
          width.repeat:
            index := line[it]
            image-data[image-data-position_++] = palette[index * 3 + 0]
            image-data[image-data-position_++] = palette[index * 3 + 1]
            image-data[image-data-position_++] = palette[index * 3 + 2]
            image-data[image-data-position_++] = palette-a_[index]
        else if color-type == COLOR-TYPE-GRAYSCALE-ALPHA:
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
        if color-type == COLOR-TYPE-GRAYSCALE:
          width.repeat:
            value := BIG-ENDIAN.uint16 line (it << 1)
            image-data[image-data-position_++] = value >> 8
            image-data[image-data-position_++] = value >> 8
            image-data[image-data-position_++] = value >> 8
            if r-transparent_ == value:
              image-data[image-data-position_++] = 0
            else:
              image-data[image-data-position_++] = 255
        else if color-type == COLOR-TYPE-GRAYSCALE-ALPHA:
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

buffers_ := BufferUnchurner_

/**
A store of temporary byte buffers.
You can ask for a buffer of a certain size, and it will loan
  one to you.  When you are done, put it back with put-back.
When memory pressure is high, the store will be emptied by
  the GC.
*/
class BufferUnchurner_:
  map_ /Map

  constructor:
    map_ = Map.weak

  loan size/int -> ByteArray:
    return (loan-helper_ size) or (ByteArray size)

  loan-helper_ size/int -> ByteArray?:
    map_.get size --if-present=: | byte-array |
      if byte-array:
        // Found an exact size match.
        map_.remove size
        return byte-array
      else:
        // Since the map is weak, the byte-array can be null if the GC has
        // reclaimed it.
        map_.remove size  // Clean up the weak reference.
    best-size := null
    max-size := size + size
    map_.do: | found-size/int found-array/ByteArray? |
      // When iterating we may find a key whose value has been nulled by
      // the GC, so we need to check for nullness here.  We can't clear
      // up such keys in the middle of a do loop, so we leave them, but
      // the map also has a cleaner on a different task that will clean
      // it eventually.
      if found-array and size <= found-size <= max-size:
        if (not best-size) or found-size < best-size:
        best-size = found-size
    if best-size:
      byte-array := map_[best-size]
      map_.remove best-size
      return byte-array
    return null

  put-back byte-array/ByteArray -> none:
    map_[byte-array.size] = byte-array
