# PNG Reader
Methods for reading a PNG file into an internal pixel buffer.

Uses a lot of memory, and is not suitable for embedded platforms.

## Converter

In `examples/convert.toit` there is an experimental converter from PNG
to an icon format.  Making input for this from SVG can be done with
resvg:

```
./target/release/resvg --shape-rendering optimizeSpeed --text-rendering optimizeSpeed --image-rendering optimizeSpeed input.svg output.png
```

This disables Skia anti-aliasing, which is buggy and messes up the colours.
