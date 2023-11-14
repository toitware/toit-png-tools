#!/bin/bash

set -e

mkdir -p tests/out

TOITRUN=$1

./build/pngunzip --version foo

for name in tests/pngs/zero-is-opaque-one-is-transparent.png
do
  # Inverts the zeros and ones to make it easier to draw.
  ./build/pngunzip -o tests/out/fixed.png $name

  # The image should still be the same.
  ./build/pngdiff tests/out/fixed.png $name

  # The bits should not be the same
  if cmp tests/out/fixed.png $name
  then
    echo "The bits of the image should not be the same."
    exit 1
  fi

  # Unzip once more - should not change anything.
  ./build/pngunzip -o tests/out/fixed2.png tests/out/fixed.png

  cmp tests/out/fixed2.png tests/out/fixed.png
done
