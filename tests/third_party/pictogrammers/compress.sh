#!/bin/sh

set -e

# Make sure we are in the right directory.
ls compressed/.. > /dev/null

for name in *.png
do
  basename=${name%.png}
  echo $name
  pngquant 10 --speed=1 --strip --nofs --force $name -o compressed/$basename-pngquant-10.png
  pngout -c3     -y $name compressed/$basename-pngout-c3.png
  pngout -c3     -y compressed/$basename-pngquant-10.png compressed/$basename-pngquant-10-pngout-c3.png
  pngout -c3 -d8 -y compressed/$basename-pngquant-10.png compressed/$basename-pngquant-10-pngout-c3-d8.png
done
