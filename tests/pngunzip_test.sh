#!/bin/bash

set -e

mkdir -p out

TOITRUN=$1

./build/pngunzip --version foo

for name in tests/pngs/zero-is-opaque-one-is-transparent.png
do
  # Inverts the zeros and ones to make it easier to draw.
  ./build/pngunzip -o out/fixed.png $name

  # The image should still be the same.
  ./build/pngdiff out/fixed.png $name

  # The bits should not be the same
  if cmp out/fixed.png $name
  then
    echo "The bits of the image should not be the same."
    exit 1
  fi

  # Unzip once more - should not change anything.
  ./build/pngunzip -o out/fixed2.png out/fixed.png

  cmp out/fixed2.png out/fixed.png
done
