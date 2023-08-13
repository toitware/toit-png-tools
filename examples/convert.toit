import expect show *
import png_reader
import host.file
import host.directory show *

class Pixel:
  r/int
  g/int
  b/int
  a/int

  constructor .r .g .b .a:

  operator == other -> bool:
    if other is not Pixel: return false
    return other.r == r and other.g == g and other.b == b and other.a == a

  hash_code -> int:
    return r * 12361 + g * 5117 + b * 123 + a

  approx_equal p/Pixel -> bool:
    return (r - p.r).abs < 4 and (g - p.g).abs < 4 and (b - p.b).abs < 4 and (a - p.a).abs < 10

  almost_equal p/Pixel -> bool:
    // All transparent colors match.
    if a < 7 and p.a < 7: return true
    if a < 32:
      // Very transparent colors don't have to match as well.
      color_match := (r - p.r).abs < 6 and (g - p.g).abs < 4 and (b - p.b).abs < 6
      return color_match and (a - p.a).abs < 12
    color_match := (r - p.r).abs < 2 and (g - p.g).abs < 2 and (b - p.b).abs < 2
    return color_match and (a - p.a).abs < 6

  stringify:
    return "Pixel 0x$(%02x r) 0x$(%02x g) 0x$(%02x b) $a"
    /*if a == 255:
      return "$(%02x r)$(%02x g)$(%02x b)"
    else:
      return "$(%02x r)$(%02x g)$(%02x b)/$a"*/

main:
  test
  compress "/home/erik/Downloads/atom-scaled.png"

compress filename -> none:
  png := png_reader.Png.from_file filename
  print png
  map := {:}
  for i := 0; i < png.image_data.size; i += 4:
    p := Pixel
        png.image_data[i]
        png.image_data[i + 1]
        png.image_data[i + 2]
        png.image_data[i + 3]
    map.update --init=0 p: it + 1

  keys := map.keys
  keys.sort --in_place: | a b |
    map[b] - map[a]

  unaccounted_counts := map.copy
  palette := {}
  keys.do: | pixel |
    count := map[pixel]
    if count >= (png.width * png.height) / 128:
      palette.add pixel
      unaccounted_counts.remove pixel

  palette.do: | pixel |
    print "$pixel: $map[pixel]"

  pairs := []
  to_do := not_covered unaccounted_counts palette pairs

  pair_candidates := {}
  pair_candidates.add_all palette
  palette.do: | pixel |
    p := Pixel pixel.r pixel.g pixel.b 0
    pair_candidates.add p

  pair_candidates.add_all [
      Pixel 0 0 0 255,
      Pixel 255 0 0 255,
      Pixel 0 255 0 255,
      Pixel 0 0 255 255,
      Pixel 255 255 0 255,
      Pixel 255 0 255 255,
      Pixel 0 255 255 255,
      Pixel 255 255 255 255,
      ]
  print "pair_candidates.size: $pair_candidates.size"

  keys.do: | pixel |
    if pair_candidates.size < 20 and unaccounted_counts.contains pixel:
      pair_candidates.add pixel

  [0.995, 0.9999999].do: | closeness |
    print closeness
    pair_candidates.do: | cand1 |
      if palette.size < 256:
        pair_candidates.do: | cand2 |
          if cand1 != cand2:
            perhaps_pairs := pairs.copy
            perhaps_pairs.add [cand1, cand2]
            perhaps_unaccounted := not_covered unaccounted_counts palette perhaps_pairs
            if perhaps_unaccounted.to_float / to_do < closeness:
              to_do = perhaps_unaccounted
              palette.add cand1
              palette.add cand2
              pairs = perhaps_pairs
              to_do = not_covered --remove_covered unaccounted_counts palette pairs

  keys.do: | pixel |
    if unaccounted_counts.contains pixel and unaccounted_counts[pixel] > 1:
      if fuzzy_contains palette pixel:
        unaccounted_counts.remove pixel
      else if palette.size < 256:
        palette.add pixel
        unaccounted_counts.remove pixel

  to_do = not_covered --remove_covered unaccounted_counts palette pairs

  print "Palette size: $palette.size, unaccounted pixels: $to_do left $((to_do * 100 / (png.height * png.width)).to_int)%"
  print palette
  print pairs

  keys.do: | pixel |
    if unaccounted_counts.contains pixel:
      print "$pixel: $unaccounted_counts[pixel]"

  palette_map := {:}
  palette.do: | pixel |
    palette_map[pixel] = palette_map.size

  off_edge := Pixel 0 0 0 0
  List.chunk_up 0 png.height 16: | fy ty |
    List.chunk_up 0 png.width 16: | fx tx |
      pixels := List 256: off_edge
      for y := fy; y < ty; y++:
        for x := fx; x < tx; x++:
          i := (y * png.width + x) * 4
          p := Pixel
              png.image_data[i]
              png.image_data[i + 1]
              png.image_data[i + 2]
              png.image_data[i + 3]
          pixels[x - fx + (y - fy) * 16] = p
      bytes := get_compressed_bytes pixels palette_map pairs
      print "$fx,$fy, compressed to $bytes.size: $bytes"
      current := pixels[0]
      count := 0
      str := ""
      for pos := 0; pos <= 256; pos++:
        if pos > 255 or pixels[pos] != current:
          if str == "":
            str = "  (List $count: $current)"
          else:
            str += " + (List $count: $current)"
          count = 0
          if pos > 255: break
          current = pixels[pos]
        count++
      print str

/**

*/
not_covered --remove_covered=false color_counts/Map palette/Set pairs/List -> int:
  total := 0
  covered := 0
  palette_has_completely_transparent := palette.any: it.a == 0
  removed := []
  color_counts.do: | pixel count |
    total += count
    if palette.contains pixel:
      covered += count
      removed.add pixel
    else if pixel.a == 0 and palette_has_completely_transparent:
      covered += count
      removed.add pixel
    else:
      found := false
      pairs.do:
        from := it[0]
        to := it[1]
        if on_line from to pixel:
          found = true
      if found:
        covered += count
        removed.add pixel
  if remove_covered:
    removed.do: | pixel |
      color_counts.remove pixel
  return total - covered

fuzzy_contains palette/Set p/Pixel -> bool:
  if palette.contains p: return true
  palette.do: | c |
    if c.almost_equal p: return true
  return false

class Placement:
  from/int
  to/int
  p/int

  stringify: return "(Placement $from-$to $p)"

  constructor .from .to .p:

  distance -> int:
    return (from - to).abs

  in_range -> bool:
    return from - 1 <= p <= to + 1 or to - 1 <= p <= from + 1

  multiplier -> float:
    return (p - from).to_float / (to - from)

  similar_multiplier other_component/Placement -> bool:
    if from == to == p or other_component.from == other_component.to == other_component.p: return true
    // Best placement for this component.
    m := multiplier
    //print "$from-$to $p $m"
    // Use the best placement on the other component.
    other_result := (other_component.from + (other_component.to - other_component.from) * m).to_int
    return (other_component.p - other_result).abs < 2

on_line from/Pixel to/Pixel p/Pixel -> bool:
  return on_line from to p: null

on_line from/Pixel to/Pixel p/Pixel [get_scale] -> bool:
  placements := [
    Placement from.r to.r p.r,
    Placement from.g to.g p.g,
    Placement from.b to.b p.b,
    Placement from.a to.a p.a,
    ]
  if from == to: return p == from
  if (placements.any: not it.in_range): return false
  // Biggest distance first.
  placements.sort --in_place: | a b | b.distance - a.distance
  for i := 1; i < 4; i++:
    if not placements[0].similar_multiplier placements[i]: return false
  get_scale.call (placements[0].multiplier * 64.0).round
  return true

abstract class CompressionAction:
  previous/CompressionAction?
  fg/Pixel
  bg/Pixel
  last/Pixel
  cumulative_bytes_used/int := 0

  // Rough equality used to cull actions.
  operator == other -> bool:
    if other is not CompressionAction: return false
    return name == other.name and fg == other.fg and bg == other.bg and last == other.last and cumulative_bytes_used == other.cumulative_bytes_used

  hash_code -> int:
    return fg.hash_code * 1000000 + bg.hash_code * 1000 + last.hash_code

  constructor .previous .fg .bg .last:
    cumulative_bytes_used = bytes_used + (previous ? previous.cumulative_bytes_used : 0)

  abstract emit -> ByteArray

  abstract bytes_used -> int

  stringify: return "$(name)Action with $bytes_used bytes ($cumulative_bytes_used cumulative)"

  abstract name -> string

  add palette/Map p/Pixel pairs/List?=null -> List:
    if fg.almost_equal p:
      return [FgRepeatAction this]
    if bg.almost_equal p:
      return [BgRepeatAction this]
    result := []
    if palette.contains p:
      set_fg := SetFgAction this palette p
      result.add
          FgRepeatAction set_fg
      if set_fg.bytes_used == 2:  // TODO: This is a hack.
        result.add
            SetFgAndEmitAction this palette p
      set_bg := SetBgAction this palette p
      result.add
          BgRepeatAction set_bg
    else:
      palette.do: | pal |
        if result.size == 0 and pal.almost_equal p:
          set_fg := SetFgAction this palette pal
          result.add
              FgRepeatAction set_fg
          if set_fg.bytes_used == 2:  // TODO: This is a hack.
            result.add
                SetFgAndEmitAction this palette pal
          set_bg := SetBgAction this palette pal
          result.add
              BgRepeatAction set_bg
    if p.almost_equal last:
      result.add
        LastRepeatAction this
    if result.size == 0:
      if pairs:
        pairs.do:
          from := it[0]
          to := it[1]
          add_mixes_ from to p this palette result
    if result.size == 0:
      palette.do: | pal1 index1 |
        palette.do: | pal2 index2 |
          add_mixes_ pal1 pal2 p this palette result
    if result.size == 0:
      result.add
          LiteralAction this p
    return result

add_mixes_ pal1/Pixel pal2/Pixel p/Pixel predecessor/CompressionAction palette/Map result/List -> none:
  fg := predecessor.fg
  bg := predecessor.bg
  if pal1 != pal2 and on_line pal1 pal2 p:
    if fg == pal2 or bg == pal1:
      // Swap
      temp := pal1
      pal1 = pal2
      pal2 = temp
    if fg == pal1:
      if bg == pal2:
        result.add
          MixAction predecessor p
      else:
        // fg already right.
        set_bg := SetBgAction predecessor palette pal2
        result.add
            MixAction set_bg p
    else if bg == pal2:
      assert: fg != pal1
      set_fg := SetFgAction predecessor palette pal1
      result.add
          MixAction set_fg p
    else:
      // None match already.
      set_fg := SetFgAction predecessor palette pal1
      set_bg := SetBgAction set_fg palette pal2
      result.add
          MixAction set_bg p
      // It might be better to swap fg and bg.
      set_fg2 := SetFgAction predecessor palette pal2
      set_bg2 := SetBgAction set_fg2 palette pal1
      result.add
          MixAction set_bg2 p

class InitialAction extends CompressionAction:
  name: return "Initial"

  constructor fg/Pixel bg/Pixel:
    super null fg bg fg

  bytes_used := 0

  emit -> ByteArray:
    return #[]

class SetFgAction extends CompressionAction:
  name: return "SetFg"
  bytes_used/int
  index_/int

  constructor previous/CompressionAction palette/Map fg/Pixel:
    index_ = palette[fg]
    bytes_used = index_ < 32 ? 1 : 2
    super previous fg previous.bg previous.last

  emit -> ByteArray:
    if index_ < 32:
      return #[128 + index_]
    return #[192 + (index_ >> 8), index_ & 0xff]

class SetFgAndEmitAction extends SetFgAction:
  name: return "SetFgAndEmit"
  constructor previous/CompressionAction palette/Map fg/Pixel:
    super previous palette fg

  emit -> ByteArray:
    assert: index_ >= 32
    return #[208 + (index_ >> 8), index_ & 0xff]

class SetBgAction extends CompressionAction:
  name: return "SetBg"
  bytes_used/int
  index_/int

  constructor previous/CompressionAction palette/Map bg/Pixel:
    index_ = palette[bg]
    bytes_used = index_ < 32 ? 1 : 2
    super previous previous.fg bg previous.last

  emit -> ByteArray:
    if index_ < 32:
      return #[160 + index_]
    return #[224 + (index_ >> 8), index_ & 0xff]

class FgRepeatAction extends CompressionAction:
  name: return "FgRepeat"
  repeats/int

  constructor previous/CompressionAction:
    prev := ?
    if previous is FgRepeatAction:
      repeats = (previous as FgRepeatAction).repeats + 1
      prev = previous.previous
    else:
      repeats = 1
      prev = previous
    super prev previous.fg previous.bg previous.last

  emit -> ByteArray:
    if repeats <= 31:
      return #[repeats - 1]
    return #[31, repeats - 1]

  bytes_used -> int:
    if repeats <= 31: return 1
    return 2

class BgRepeatAction extends CompressionAction:
  name: return "BgRepeat"
  repeats/int

  constructor previous/CompressionAction:
    prev := ?
    if previous is BgRepeatAction:
      repeats = (previous as BgRepeatAction).repeats + 1
      prev = previous.previous
    else:
      repeats = 1
      prev = previous
    super prev previous.fg previous.bg previous.last

  emit -> ByteArray:
    if repeats <= 31:
      return #[32 + repeats - 1]
    return #[32 + 31, repeats - 1]

  bytes_used -> int:
    if repeats <= 31: return 1
    return 2

class MixAction extends CompressionAction:
  name: return "Mix"
  scale/int

  constructor previous/CompressionAction p/Pixel:
    s := -1
    on_line previous.fg previous.bg p: s = it
    if s < 0: s = 0
    if s > 63: s = 63
    scale = s
    super previous previous.fg previous.bg p

  bytes_used -> int:
    return 1

  emit -> ByteArray:
    return #[64 + scale]

class LiteralAction extends CompressionAction:
  name: return "Literal"
  pixels/List

  constructor previous/CompressionAction p/Pixel:
    prev := ?
    if previous is LiteralAction:
      pixels = (previous as LiteralAction).pixels + [p]
      prev = previous.previous
    else:
      pixels = [p]
      prev = previous
    super prev previous.fg previous.bg p

  bytes_used -> int:
    groups := (pixels.size - 1) / 8 + 1
    return groups + pixels.size * 4

  emit -> ByteArray:
    result := ByteArray bytes_used
    pos := 0
    List.chunk_up 0 pixels.size 8: | f t l |
      result[pos++] = 248 + l - 1
      for i := f; i < t; i++:
        p := pixels[i]
        result[pos++] = p.r
        result[pos++] = p.g
        result[pos++] = p.b
        result[pos++] = p.a
    return result

class LastRepeatAction extends CompressionAction:
  name: return "LastRepeat"
  repeats/int

  constructor previous/CompressionAction:
    prev := ?
    if previous is LastRepeatAction:
      repeats = (previous as LastRepeatAction).repeats + 1
      prev = previous.previous
    else:
      repeats = 1
      prev = previous
    super prev previous.fg previous.bg previous.last

  bytes_used -> int:
    return repeats <= 7 ? 1 : 2

  emit -> ByteArray:
    result := ByteArray bytes_used
    if repeats <= 7:
      result[0] = 240 + repeats - 1
    else:
      result[0] = 247
      result[1] = repeats - 1
    return result

test:
  test_almost_equal
  test_placement
  test_on_line
  test_build_actions
  test_chrome_logo

test_almost_equal:
  transparent := Pixel 0 0 0 0
  black := Pixel 0 0 0 255
  dark := Pixel 1 1 1 255
  white := Pixel 255 255 255 255
  expect: transparent.almost_equal transparent
  expect: not transparent.almost_equal black
  expect: dark.almost_equal black
  expect: not white.almost_equal black

test_placement:
  r := Placement 0 100 30
  g := Placement 0 100 30
  // Same ratio.
  expect: r.similar_multiplier g
  // Same ratio, opposite direction.
  g = Placement 100 0 70
  expect: r.similar_multiplier g
  // Scaled down by 10.
  b := Placement 20 30 23
  // Scaled down by 10, opposite direction.
  expect: r.similar_multiplier b
  a := Placement 30 20 27
  expect: r.similar_multiplier a
  x := Placement 255 255 0
  expect: not r.similar_multiplier x
  y := Placement 128 128 129
  expect: r.similar_multiplier y

test_on_line:
  expect: on_line (Pixel 0 0 0 0) (Pixel 0 0 0 0) (Pixel 0 0 0 0)
  expect: on_line (Pixel 192 35 66 0) (Pixel 192 35 66 255) (Pixel 192 35 66 128)
  expect: on_line (Pixel 192 35 66 0) (Pixel 192 35 67 255) (Pixel 192 35 66 128)
  expect: on_line (Pixel 192 35 66 0) (Pixel 192 35 66 255) (Pixel 192 35 67 128)

test_chrome_logo:
  palette_list := [
      Pixel 0x00 0x00 0x00 0,
      Pixel 0xda 0x32 0x26 255,
      Pixel 0xfc 0xc7 0x2c 255,
      Pixel 0x2e 0xa1 0x4d 255,
      Pixel 0x1a 0x73 0xe8 255,
      Pixel 0xff 0xff 0xff 255,
      Pixel 0x2c 0x9f 0x4b 255,
      Pixel 0x2b 0x9c 0x4a 255,
      Pixel 0xfc 0xc7 0x2c 0,
      Pixel 0x2e 0xa1 0x4d 0,
      Pixel 0xff 0xff 0xff 0,
      Pixel 0xfc 0xc6 0x28 255,
      Pixel 0x28 0x9a 0x47 255,
      Pixel 0xfc 0xc5 0x26 255,
      Pixel 0x2b 0xa7 0x4c 24,
      Pixel 0x29 0x9a 0x48 241,
      Pixel 0xfc 0xc5 0x27 241,
      Pixel 0xfe 0xfa 0xfa 226,
      Pixel 0xfe 0xf8 0xf7 212,
      Pixel 0xfe 0xf8 0xf8 220,
      Pixel 0xff 0xfa 0xeb 205,
      Pixel 0xf2 0xb1 0xab 183,
      Pixel 0xfe 0xeb 0xb5 192,
      Pixel 0xfb 0xe2 0xe0 192,
      Pixel 0xff 0xfd 0xf7 212,
      Pixel 0xff 0xf6 0xdc 189,
      Pixel 0xfe 0xf5 0xf4 208,
      Pixel 0xff 0xfe 0xfc 222,
      Pixel 0xff 0xfd 0xfd 230,
      Pixel 0xff 0xfd 0xf9 223,
      Pixel 0x81 0xc2 0x94 198,
      Pixel 0xf8 0xfb 0xf9 212,
      Pixel 0xf0 0xf8 0xf3 210,
      Pixel 0xed 0xf6 0xf0 203,
      Pixel 0xdb 0xed 0xe1 186,
      Pixel 0xeb 0xf6 0xee 192,
      Pixel 0xf4 0xfa 0xf6 204,
      Pixel 0xfc 0xfe 0xfd 224,
      Pixel 0xf5 0xc4 0x28 249,
      Pixel 0x2e 0xa0 0x4b 249,
      Pixel 0xfc 0xc6 0x29 241
      ]

  palette_map := {:}
  palette_list.do: palette_map[it] = palette_map.size

  mixing_pairs ::= [
      [Pixel 0x00 0x00 0x00 0, Pixel 0xff 0xff 0xff 255],
      [Pixel 0x00 0x00 0x00 0, Pixel 0x2c 0x9f 0x4b 255],
      [Pixel 0x00 0x00 0x00 0, Pixel 0x2b 0x9c 0x4a 255],
      [Pixel 0xda 0x32 0x26 255, Pixel 0xfc 0xc7 0x2c 255],
      [Pixel 0xfc 0xc7 0x2c 255, Pixel 0xfc 0xc7 0x2c 0],
      [Pixel 0x2e 0xa1 0x4d 255, Pixel 0x2e 0xa1 0x4d 0],
      [Pixel 0x1a 0x73 0xe8 255, Pixel 0xff 0xff 0xff 255],
      [Pixel 0xff 0xff 0xff 255, Pixel 0xff 0xff 0xff 0],
      [Pixel 0x2e 0xa1 0x4d 0, Pixel 0x2c 0x9f 0x4b 255],
      [Pixel 0x2e 0xa1 0x4d 0, Pixel 0x2b 0x9c 0x4a 255],
      [Pixel 0x00 0x00 0x00 0, Pixel 0xfc 0xc7 0x2c 255],
      [Pixel 0xfc 0xc7 0x2c 255, Pixel 0x2e 0xa1 0x4d 0],
      [Pixel 0xfc 0xc7 0x2c 255, Pixel 0xff 0xff 0xff 0],
      [Pixel 0x2e 0xa1 0x4d 255, Pixel 0xff 0xff 0xff 0],
      [Pixel 0xff 0xff 0xff 255, Pixel 0xfc 0xc7 0x2c 0],
      [Pixel 0xff 0xff 0xff 0, Pixel 0x2b 0x9c 0x4a 255],
      ]

  all_transparent := List 256: Pixel 0 0 0 0
  compressed := get_compressed_bytes all_transparent palette_map mixing_pairs
  expect_equals #[0x1f, 0xff] compressed

  square_160_0 := (List 207: Pixel 0x00 0x00 0x00 0) + (List 1: Pixel 0xda 0x32 0x26 255) + (List 12: Pixel 0x00 0x00 0x00 0) + (List 4: Pixel 0xda 0x32 0x26 255) + (List 9: Pixel 0x00 0x00 0x00 0) + (List 1: Pixel 0xff 0x55 0x00 3) + (List 6: Pixel 0xda 0x32 0x26 255) + (List 7: Pixel 0x00 0x00 0x00 0) + (List 9: Pixel 0xda 0x32 0x26 255)
  compressed = get_compressed_bytes square_160_0 palette_map mixing_pairs
  expect_equals compressed #[
      0x1f,  // Wide repeat of fg.
      206,   // 207 repeats of fg.
      0x20,  // One repeat of bg, Pixel 0xda 0x32 0x26 255.
      0x0b,  // 12 repeats of fg.
      0x23,  // 4 repeats of bg.
      0x09,  // 10 repeats of fg.
      0x25,  // 6 repeats of bg, Pixel 0xda 0x32 0x26 255.
      0x06,  // 7 repeats of fg.
      0x28,  // 9 repeats of bg.
      ]

  square_176_0 := (List 140: Pixel 0x00 0x00 0x00 0) + (List 1: Pixel 0xbf 0x40 0x40 4) + (List 3: Pixel 0xda 0x32 0x26 255) + (List 9: Pixel 0x00 0x00 0x00 0) + (List 7: Pixel 0xda 0x32 0x26 255) + (List 5: Pixel 0x00 0x00 0x00 0) + (List 1: Pixel 0xff 0x55 0x00 3) + (List 10 : Pixel 0xda 0x32 0x26 255) + (List 2: Pixel 0x00 0x00 0x00 0) + (List 78: Pixel 0xda 0x32 0x26 255)
  compressed = get_compressed_bytes square_176_0 palette_map mixing_pairs
  expect_equals #[
      0x1f,  // Wide repeat of fg.
      0x8c,  // 141 repeats of fg.
      0x22,  // Emit 3 pixels bg.
      0x08,  // Emit 9 pixels fg.
      0x26,  // Emit 7 pixels bg.
      0x05,  // Emit 6 pixels fg.
      0x29,  // Emit 10 pixels bg.
      0x01,  // Emit 2 pixels fg.
      0x3f,  // Wide repeat of bg.
      0x4d,  // 78 repeats of bg.
      ] compressed

test_build_actions:
  palette := {:}
  transparent := Pixel 0 0 0 0
  black := Pixel 0 0 0 255
  white := Pixel 255 255 255 255
  red := Pixel 255 0 0 255
  cyan := Pixel 255 255 0 255
  palette_pixels ::= [
      transparent,
      black,
      white,
      red,
      cyan,
      ]
  palette_pixels.do:
    palette[it] = palette.size

  compressed := get_compressed_bytes palette_pixels palette
  expect_equals compressed #[
      0x00,  // One repeat of fg.
      0x20,  // One repeat of bg.
      0x82,  // Set fg to palette 2.
      0x00,  // One repeat of fg.
      0x83,  // Set fg to palette 3.
      0x00,  // One repeat of fg.
      0x84,  // Set fg to palette 4.
      0x00,  // One repeat of fg.
      ]

  // 2 one-byte pixels that match the initial fg and bg, then 3 that need us to
  // set the fg first.
  expect_equals 8 compressed.size

  image := [
      red, cyan, red,
      ]

  compressed = get_compressed_bytes image palette

  expect_equals compressed #[
      0x83,  // Set fg to palette 3.
      0x00,  // One repeat of fg.
      0xa4,  // Set bg to palette 4.
      0x20,  // One repeat of bg.
      0x00,  // One repeat of fg.
      ]

  image = [
      black, black, white, white, red, red,
      transparent, transparent, transparent, transparent,
      ]

  compressed = get_compressed_bytes image palette

  expect_equals compressed #[
      0x21,  // Two repeats of bg.
      0x82,  // Set fg to palette 2.
      0x01,  // Two repeats of fg.
      0x83,  // Set fg to palette 3.
      0x01,  // Two repeats of fg.
      0xf3,  // Four repeats of last (initially set to palette 0).
      ]

  grey := Pixel 128 128 128 255
  image = [grey, grey, grey, grey]
  compressed = get_compressed_bytes image palette
  expect_equals compressed #[
      0x82,  // Set fg to palette 2 (white).
      0x60,  // One pixel of mixed fg and bg.
      0xf2,  // Three repeats of last pixel.
      ]

  dark_grey := Pixel 64 64 64 255
  light_grey := Pixel 192 192 192 255
  image = [white, white, white, white, light_grey, grey, grey, grey, dark_grey, black, black, black, black]
  compressed = get_compressed_bytes image palette
  expect_equals compressed #[
      0x82,  // Set fg to palette 2 (white).
      0x03,  // 4 repeats of fg.
      0x50,  // 1 pixel of mixed fg and bg.
      0x60,  // 1 pixel of mixed fg and bg.
      0xf1,  // Two repeats of last pixel.
      0x70,  // 1 pixel of mixed fg and bg.
      0x23,  // Four repeats of bg.
      ]

  half_transparent := Pixel 0 0 0 128
  image = [white, white, white, white, light_grey, grey, grey, grey, dark_grey, black, black, black, black, half_transparent, transparent, transparent, transparent, transparent]
  compressed = get_compressed_bytes image palette
  expect_equals compressed #[
      0x82,  // Set fg to palette 2 (white).
      0x03,  // 4 repeats of fg.
      0x50,  // One pixel of mixed fg and bg.
      0x60,  // One pixel of mixed fg and bg.
      0xf1,  // Two repeats of last pixel.
      0x70,  // One pixel of mixed fg and bg.
      0x23,  // Four repeats of bg.
      0x80,  // Set fg to palette 0 (transparent).
      0x60,  // One pixel of mixed fg and bg.
      0x03,  // Four repeats of fg.
      ]

  strange_color := Pixel 123 53 22 42
  image = [black, black, strange_color, black, black]
  compressed = get_compressed_bytes image palette
  expect_equals compressed #[
      0x21,  // Two repeats of bg.
      0xf8,  // One literal pixel.
      123, 53, 22, 42,  // The literal pixel.
      0x21,  // Two repeats of bg.
      ]

  image = [black, black, strange_color, strange_color, black, black]
  compressed = get_compressed_bytes image palette
  expect_equals compressed #[
      0x21,  // Two repeats of bg.
      0xf8,  // One literal pixel.
      123, 53, 22, 42,  // The literal pixel.
      0xf0,  // One repeat of last pixel.
      0x21,  // Two repeats of bg.
      ]

  image = List 256: light_grey
  compressed = get_compressed_bytes image palette
  print compressed

get_compressed_bytes pixels/List palette/Map pairs/List?=null -> ByteArray:
  best/CompressionAction? := get_best_chain pixels palette pairs
  result := ByteArray best.cumulative_bytes_used
  pos := result.size
  while best:
    pos -= best.bytes_used
    result.replace pos best.emit
    best = best.previous
  return result

get_best_chain pixels/List palette/Map pairs/List?=null -> CompressionAction:
  palette_pixels ::= palette.keys
  root := InitialAction palette_pixels[0] palette_pixels[1]
  states := [root]

  pixels.do: | p/Pixel |
    new_states := []
    states.do: | s/CompressionAction |
      new_states.add_all
          s.add palette p pairs
    states = new_states
    if states.size > 1000:
      best_score := 100000000000
      states.do:
        c := it.cumulative_bytes_used
        if c < best_score: best_score = c
      new_states.filter --in_place:
        it.cumulative_bytes_used <= best_score + 8
      states = new_states
    if states.size > 1000:
      set := {}
      set.add_all states
      states = set.to_list

  best := states[0]
  states.do:
    if it.cumulative_bytes_used < best.cumulative_bytes_used:
      best = it

  return best

do_print action/CompressionAction:
  if action.previous:
    do_print action.previous
  print action
