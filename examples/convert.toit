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
    if a == 0 and p.a == 0: return true
    if a == 0 or p.a == 0:
      // If only one of them is completely transparent, then they don't match.
      return false
    if a < 32:
      // Very transparent colors don't have to match as well.
      color_match := (r - p.r).abs < 6 and (g - p.g).abs < 4 and (b - p.b).abs < 6
      return color_match and (a - p.a).abs < 12
    color_match := (r - p.r).abs < 2 and (g - p.g).abs < 2 and (b - p.b).abs < 2
    return (a - p.a).abs < 6

  stringify:
    if a == 255:
      return "$(%02x r)$(%02x g)$(%02x b)"
    else:
      return "$(%02x r)$(%02x g)$(%02x b)/$a"

main:
  test
  compress "examples/chrome.png"

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

  keys.do: | pixel |
    if unaccounted_counts.contains pixel:
      print "$pixel: $unaccounted_counts[pixel]"

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

  constructor .previous .fg .bg .last:
    cumulative_bytes_used = bytes_used + (previous ? previous.cumulative_bytes_used : 0)

  abstract emit -> ByteArray

  abstract bytes_used -> int

  stringify: return "$(name)Action with $bytes_used bytes ($cumulative_bytes_used cumulative)"

  abstract name -> string

  add palette/Map p/Pixel -> List:
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
          BgRepeatAction set_fg
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
    if result.size == 0:
      palette.do: | pal1 index1 |
        palette.do: | pal2 index2 |
          if pal1 != pal2 and on_line pal1 pal2 p:
            if fg == pal2 or bg == pal1:
              // Swap
              temp := pal1
              pal1 = pal2
              pal2 = temp
            if fg == pal1:
              if bg == pal2:
                result.add
                  MixAction this p
              else:
                // fg already right.
                set_bg := SetBgAction this palette pal2
                result.add
                    MixAction set_bg p
            else if bg == pal2:
              assert: fg != pal1
              set_fg := SetFgAction this palette pal1
              result.add
                  MixAction set_fg p
            else:
              // None match already.
              set_fg := SetFgAction this palette pal1
              set_bg := SetBgAction set_fg palette pal2
              result.add
                  MixAction set_bg p
              // It might be better to swap fg and bg.
              set_fg2 := SetFgAction this palette pal2
              set_bg2 := SetBgAction set_fg2 palette pal1
              result.add
                  MixAction set_bg2 p
    if p == last:
      result.add
        LastRepeatAction this
    if result.size == 0:
      result.add
          LiteralAction this p
    return result

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
    if repeats <= 28:
      return #[repeats - 1]
    return #[28 + (repeats >> 8), repeats & 0xff]

  bytes_used -> int:
    if repeats <= 28: return 1
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
    if repeats <= 28:
      return #[32 + repeats - 1]
    return #[32 + 28 + (repeats >> 8), repeats & 0xff]

  bytes_used -> int:
    if repeats <= 28: return 1
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
    super prev previous.fg previous.bg previous.last

  bytes_used -> int:
    groups := repeats / 8 + 1
    return groups

  emit -> ByteArray:
    result := ByteArray bytes_used
    pos := 0
    List.chunk_up 0 repeats 8: | _ _ l |
      result[pos++] = 240 + l - 1
    return result

test:
  test_placement
  test_on_line
  test_build_actions

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

test_build_actions:
  palette := {:}
  first := Pixel 0 0 0 0
  second := Pixel 0 0 0 255
  palette_pixels ::= [
      first,
      second,
      Pixel 255 255 255 255,
      Pixel 255 0 0 255,
      Pixel 255 255 0 255,
      ]
  counter := 0
  palette_pixels.do:
    palette[it] = counter++

  root := InitialAction first second
  states := [root]

  palette_pixels.do: | p/Pixel |
    new_states := []
    states.do: | s/CompressionAction |
      new_states.add_all
          s.add palette p
    states = new_states
    print "After $p, $states.size states"

  best := states[0]
  states.do:
    if it.bytes_used < best.bytes_used:
      best = it
  do_print best

do_print action/CompressionAction:
  if action.previous:
    do_print action.previous
  print action
  














