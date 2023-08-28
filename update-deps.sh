#!/bin/bash

DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
deps=('gdbm'
      'xz'
      'tcl-tk'
      'zlib'
      'openssl@1.1'
      'giflib'
      'pkg-config'
      'yasm'
      'nasm'
      'm4'
      'autoconf'
      'automake'
      'libtool'
      'ncurses'
      'gettext'
      'util-macros'
      'xorgproto'
      'libxau'
      'libxdmcp'
      'xcb-proto'
      'libpthread-stubs'
      'libxcb'
      'xtrans'
      'libx11'
      'python@3.11'
      'cmake'
      'libtiff'
      'lame'
      'librist'
      'opencore-amr'
      'mpg123'
      'snappy'
      'xvid')
for i in "${deps[@]}"; do
  echo "ver_$i=$(brew info $i | grep "$i:" | awk '{print $4}')" >> $DIR/ver.sh
done
