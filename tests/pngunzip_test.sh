#!/bin/bash

set -e

mkdir -p out

TOITRUN=$1

$TOITRUN bin/pngunzip.toit --version foo

for name in tests/pngs/zero-is-opaque-one-is-transparent.png
do
  # Inverts the zeros and ones to make it easier to draw.
  $TOITRUN bin/pngunzip.toit -o out/fixed.png $name

  # The image should still be the same.
  $TOITRUN bin/pngdiff.toit out/fixed.png $name

  # The bits should not be the same
  if cmp out/fixed.png $name
  then
    echo "The bits of the image should not be the same."
    exit 1
  fi
done
