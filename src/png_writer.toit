// Copyright (C) 2023 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import binary
import binary show BIG-ENDIAN byte-swap-32
import bytes show Buffer
import crypto.crc show *
import host.file
import monitor show Latch
import .png-reader
import reader
import zlib

class PngWriter:
  stream_/any
  compressor_ := ?
  done_/Latch
  compressed_data_/Buffer? := null

  constructor .stream_ width/int height/int
      --bit-depth/int=8
      --color-type/int=COLOR-TYPE-TRUECOLOR-ALPHA
      --compression/bool?=null
      --run-length-encoding/bool?=null
      --compression-level/int=6
      --all-in-one-chunk/bool=false:
    if all-in-one-chunk: compressed_data_ = Buffer
    HEADER ::= #[0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n']
    if compression == null and run-length-encoding == null:
      compression = true
    if compression and run-length-encoding: throw "cannot use run-length encoding with compression"
    compressor_ = compression ?
        zlib.Encoder --level=compression-level :
        run-length-encoding ?
            zlib.RunLengthZlibEncoder :
            zlib.UncompressedZlibEncoder
    done_ = Latch

    write_ HEADER
    ihdr := #[
      0, 0, 0, 0,          // Width.
      0, 0, 0, 0,          // Height.
      bit-depth,
      color-type,
      0, 0, 0,
    ]
    BIG-ENDIAN.put-uint32 ihdr 0 width
    BIG-ENDIAN.put-uint32 ihdr 4 height
    write-chunk "IHDR" ihdr
    task:: write-function

  /**
  Write PNG image data in its uncompressed form. It will
    be compressed and written to the file.  This is a raw
    interface where the caller is in charge of the prediction
    byte that precedes each scanline.  An easy way to handle
    that is to prepend each scanline with a 0 byte (no predictor).
  */
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
      if compressed_data_:
        compressed_data_.write data
      else:
        write-chunk "IDAT" data
    if compressed_data_:
      write-chunk "IDAT" compressed_data_.bytes
    write-chunk "IEND" #[]
    done_.set null

  write-chunk name/string data -> none:
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
