#!/bin/bash

PROGNAME=$(basename "$0")
FFMPEG_VERSION=5.1.2
SCRIPT_VERSION=1.43
DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PACKAGES="$DIR/packages"
WORKSPACE="$DIR/workspace"
CFLAGS="-I$WORKSPACE/include"
LDFLAGS="-L$WORKSPACE/lib"
EXTRALIBS="-ldl -lpthread -lm -lz"
MACOS_M1=false
CONFIGURE_OPTIONS=()
LATEST=false
CURL_RETRIES="--connect-timeout 60 --retry 5 --retry-delay 5"

# Check for Apple Silicon
if [[ ("$OSTYPE" == "darwin"*) ]]; then
  if [[ ("$(uname -m)" == "arm64") ]]; then
    export ARCH=arm64
    export MACOSX_DEPLOYMENT_TARGET=11
    MACOS_M1=true
  else
    export MACOSX_DEPLOYMENT_TARGET=10.11
  fi
fi

# Speed up the process
# Env Var NUMJOBS overrides automatic detection
if [[ -n "$NUMJOBS" ]]; then
  MJOBS="$NUMJOBS"
elif [[ -f /proc/cpuinfo ]]; then
  MJOBS=$(grep -c processor /proc/cpuinfo)
elif [[ "$OSTYPE" == "darwin"* ]]; then
  MJOBS=$(sysctl -n machdep.cpu.thread_count)
  CONFIGURE_OPTIONS=("--enable-videotoolbox")
  MACOS_LIBTOOL="$(which libtool)" # gnu libtool is installed in this script and need to avoid name conflict
else
  MJOBS=3
fi

make_dir() {
  remove_dir "$1"
  if ! mkdir "$1"; then
    printf "\n Failed to create dir %s" "$1"
    exit 1
  fi
}

remove_dir() {
  if [ -d "$1" ]; then
    rm -r "$1"
  fi
}

download() {
  # download url [filename[dirname]]

  DOWNLOAD_PATH="$PACKAGES"
  DOWNLOAD_FILE="${2:-"${1##*/}"}"

  if [[ "$DOWNLOAD_FILE" =~ tar. ]]; then
    TARGETDIR="${DOWNLOAD_FILE%.*}"
    TARGETDIR="${3:-"${TARGETDIR%.*}"}"
  else
    TARGETDIR="${3:-"${DOWNLOAD_FILE%.*}"}"
  fi

  if [ ! -f "$DOWNLOAD_PATH/$DOWNLOAD_FILE" ]; then
    echo "Downloading $1 as $DOWNLOAD_FILE"
    curl $CURL_RETRIES -L --silent -o "$DOWNLOAD_PATH/$DOWNLOAD_FILE" "$1"

    EXITCODE=$?
    if [ $EXITCODE -ne 0 ]; then
      echo ""
      echo "Failed to download $1. Exitcode $EXITCODE. Retrying in 10 seconds"
      sleep 10
      curl $CURL_RETRIES -L --silent -o "$DOWNLOAD_PATH/$DOWNLOAD_FILE" "$1"
    fi

    EXITCODE=$?
    if [ $EXITCODE -ne 0 ]; then
      echo ""
      echo "Failed to download $1. Exitcode $EXITCODE"
      exit 1
    fi

    echo "... Done"
  else
    echo "$DOWNLOAD_FILE has already downloaded."
  fi

  make_dir "$DOWNLOAD_PATH/$TARGETDIR"

  if [[ "$DOWNLOAD_FILE" == *"patch"* ]]; then
    return
  fi

  if [ -n "$3" ]; then
    if ! tar -xvf "$DOWNLOAD_PATH/$DOWNLOAD_FILE" -C "$DOWNLOAD_PATH/$TARGETDIR" 2>/dev/null >/dev/null; then
      echo "Failed to extract $DOWNLOAD_FILE"
      exit 1
    fi
  else
    if ! tar -xvf "$DOWNLOAD_PATH/$DOWNLOAD_FILE" -C "$DOWNLOAD_PATH/$TARGETDIR" --strip-components 1 2>/dev/null >/dev/null; then
      echo "Failed to extract $DOWNLOAD_FILE"
      exit 1
    fi
  fi

  echo "Extracted $DOWNLOAD_FILE"

  cd "$DOWNLOAD_PATH/$TARGETDIR" || (
    echo "Error has occurred."
    exit 1
  )
}

execute() {
  echo "$ $*"

  OUTPUT=$("$@" 2>&1)

  # shellcheck disable=SC2181
  if [ $? -ne 0 ]; then
    echo "$OUTPUT"
    echo ""
    echo "Failed to Execute $*" >&2
    exit 1
  fi
}

build() {
  echo ""
  echo "building $1 - version $2"
  echo "======================="

  if [ -f "$PACKAGES/$1.done" ]; then
    if grep -Fx "$2" "$PACKAGES/$1.done" >/dev/null; then
      echo "$1 version $2 already built. Remove $PACKAGES/$1.done lockfile to rebuild it."
      return 1
    elif $LATEST; then
      echo "$1 is outdated and will be rebuilt with latest version $2"
      return 0
    else
      echo "$1 is outdated, but will not be rebuilt. Pass in --latest to rebuild it or remove $PACKAGES/$1.done lockfile."
      return 1
    fi
  fi

  return 0
}

command_exists() {
  if ! [[ -x $(command -v "$1") ]]; then
    return 1
  fi

  return 0
}

build_done() {
  echo "$2" > "$PACKAGES/$1.done"
}

cleanup() {
  remove_dir "$PACKAGES"
  remove_dir "$WORKSPACE"
  echo "Cleanup done."
  echo ""
}

echo "Using $MJOBS make jobs simultaneously."

mkdir -p "$PACKAGES"
mkdir -p "$WORKSPACE"

export PATH="${WORKSPACE}/bin:$PATH"

if ! command_exists "make"; then
  echo "make not installed."
  exit 1
fi

if ! command_exists "g++"; then
  echo "g++ not installed."
  exit 1
fi

if ! command_exists "curl"; then
  echo "curl not installed."
  exit 1
fi

if ! command_exists "cargo"; then
  echo "cargo not installed. rav1e encoder will not be available."
fi

##
## build tools
##

if build "gdbm" "1.23"; then
  download "https://ftp.gnu.org/gnu/gdbm/gdbm-1.23.tar.gz"
  # Fix -flat_namespace being used on Big Sur and later.
  curl -OL https://raw.githubusercontent.com/Homebrew/formula-patches/03cf8088210822aa2c1ab544ed58ea04c897d9c4/libtool/configure-big_sur.diff
  execute patch -p1 -i configure-big_sur.diff
  execute ./configure \
    --prefix="${WORKSPACE}" \
    --enable-libgdbm-compat \
    --without-readline
  execute make -j $MJOBS
  execute make install
  # Avoid conflicting with macOS SDK's ndbm.h.  Renaming to gdbm-ndbm.h
  # matches Debian's convention for gdbm's ndbm.h (libgdbm-compat-dev).
  mv "${WORKSPACE}"/include/ndbm.h "${WORKSPACE}"/include/gdbm-ndbm.h
  
  build_done "gdbm" "1.23"
fi

if build "xz" "5.4.1"; then
  download "https://downloads.sourceforge.net/project/lzmautils/xz-5.4.1.tar.gz"
  execute ./configure \
    --prefix="${WORKSPACE}" \
    --disable-debug
  execute make -j $MJOBS
  execute make install

  build_done "xz" "5.4.1"
fi

if build "tcl-tk" "8.6.13"; then
  download "https://downloads.sourceforge.net/project/tcl/Tcl/8.6.13/tcl8.6.13-src.tar.gz"
  cd unix
  execute ./configure \
    --prefix="${WORKSPACE}" \
    --without-x \
    --enable-threads \
    --enable-64bit
  execute make -j $MJOBS
  execute make install

  build_done "tcl-tk" "8.6.13"
fi

if build "zlib" "1.2.13"; then
  download "https://github.com/madler/zlib/releases/download/v1.2.13/zlib-1.2.13.tar.xz"
  execute ./configure --prefix="${WORKSPACE}"
  execute make -j $MJOBS
  execute make install
  build_done "zlib" "1.2.13"
fi

if build "openssl" "1.1.1t"; then
  download "https://www.openssl.org/source/openssl-1.1.1t.tar.gz"
  if $MACOS_M1; then
    sed -n 's/\(##### GNU Hurd\)/"darwin64-arm64-cc" => { \n    inherit_from     => [ "darwin-common", asm("aarch64_asm") ],\n    CFLAGS           => add("-Wall"),\n    cflags           => add("-arch arm64 "),\n    lib_cppflags     => add("-DL_ENDIAN"),\n    bn_ops           => "SIXTY_FOUR_BIT_LONG", \n    perlasm_scheme   => "macosx", \n}, \n\1/g' Configurations/10-main.conf
    execute ./Configure --prefix="${WORKSPACE}" no-shared no-asm darwin64-arm64-cc
  else
    execute ./config \
      --prefix="${WORKSPACE}" \
      --openssldir="${WORKSPACE}" \
      --with-zlib-include="${WORKSPACE}"/include/ \
      --with-zlib-lib="${WORKSPACE}"/lib \
      zlib
  fi
  execute make -j $MJOBS
  execute make install_sw
  build_done "openssl" "1.1.1t"
fi
CONFIGURE_OPTIONS+=("--enable-openssl")

if build "giflib" "5.2.1"; then
  download "https://netcologne.dl.sourceforge.net/project/giflib/giflib-5.2.1.tar.gz"
    if [[ "$OSTYPE" == "darwin"* ]]; then
      # Upstream has stripped out the previous autotools-based build system and their
      # Makefile doesn't work on macOS. See https://sourceforge.net/p/giflib/bugs/133/  
      download "https://sourceforge.net/p/giflib/bugs/_discuss/thread/4e811ad29b/c323/attachment/Makefile.patch"
      execute patch -p0 --forward "${PACKAGES}/giflib-5.2.1/Makefile" "${PACKAGES}/Makefile.patch" || true
    fi
  cd "${PACKAGES}"/giflib-5.2.1 || exit
  #multicore build disabled for this library
  execute make
  execute make PREFIX="${WORKSPACE}" install
  build_done "giflib" "5.2.1"
fi

if build "pkg-config" "0.29.2"; then
  download "https://pkgconfig.freedesktop.org/releases/pkg-config-0.29.2.tar.gz"
  execute ./configure \
    --silent --prefix="${WORKSPACE}" \
    --with-pc-path="${WORKSPACE}"/lib/pkgconfig \
    --with-internal-glib
  execute make -j $MJOBS
  execute make install
  build_done "pkg-config" "0.29.2"
fi

if build "yasm" "1.3.0"; then
  download "https://www.tortall.net/projects/yasm/releases/yasm-1.3.0.tar.gz"
  execute ./configure --prefix="${WORKSPACE}"
  execute make -j $MJOBS
  execute make install
  build_done "yasm" "1.3.0"
fi

if build "nasm" "2.16.01"; then
  download "https://www.nasm.us/pub/nasm/releasebuilds/2.16.01/nasm-2.16.01.tar.xz"
  execute ./configure --prefix="${WORKSPACE}"
  execute make -j $MJOBS
  execute make install
  build_done "nasm" "2.16.01"
fi

if build "m4" "1.4.19"; then
  download "https://ftp.gnu.org/gnu/m4/m4-1.4.19.tar.gz"
  execute ./configure --prefix="${WORKSPACE}"
  execute make -j $MJOBS
  execute make install
  build_done "m4" "1.4.19"
fi

if build "autoconf" "2.71"; then
  download "https://ftp.gnu.org/gnu/autoconf/autoconf-2.71.tar.gz"
  execute ./configure --prefix="${WORKSPACE}"
  execute make -j $MJOBS
  execute make install
  build_done "autoconf" "2.71"
fi

if build "automake" "1.16.5"; then
  download "https://ftp.gnu.org/gnu/automake/automake-1.16.5.tar.gz"
  execute ./configure --prefix="${WORKSPACE}"
  execute make -j $MJOBS
  execute make install
  build_done "automake" "1.16.5"
fi

if build "libtool" "2.4.7"; then
  download "https://ftpmirror.gnu.org/libtool/libtool-2.4.7.tar.gz"
  execute ./configure --prefix="${WORKSPACE}"
  execute make -j $MJOBS
  execute make install
  build_done "libtool" "2.4.7"
fi

if build "ncurses" "6.4"; then
  download "https://ftpmirror.gnu.org/ncurses/ncurses-6.4.tar.gz"
  execute ./configure --prefix="${WORKSPACE}"
  execute make -j $MJOBS
  execute make install
  build_done "ncurses" "6.4"
fi  

if build "libxml2" "master"; then
  cd $PACKAGES
  git clone https://github.com/GNOME/libxml2.git --branch master --depth 1
  cd libxml2
  # Fix crash when using Python 3 using Fedora's patch.
  # Reported upstream:
  # https://bugzilla.gnome.org/show_bug.cgi?id=789714
  # https://gitlab.gnome.org/GNOME/libxml2/issues/12
  #execute curl $CURL_RETRIES -L --silent -o fix_crash.patch "https://bugzilla.opensuse.org/attachment.cgi?id=746044"
  #execute patch -p1 -i fix_crash.patch
  execute autoreconf -fvi
  execute ./configure \
    --prefix="${WORKSPACE}" \
    --without-python \
    --without-lzma
  execute make -j $MJOBS
  execute make install

  build_done "libxml2" "master"
fi  
CONFIGURE_OPTIONS+=("--enable-libxml2")

if build "gettext" "0.21.1"; then
  download "https://ftpmirror.gnu.org/gettext/gettext-0.21.1.tar.gz"
  execute ./configure \
    --prefix="${WORKSPACE}" \
    --disable-java \
    --disable-csharp \
    --without-git \
    --without-cvs \
    --without-xz \
    --with-included-gettext
  execute make -j $MJOBS
  execute make install
  build_done "gettext" "0.21.1"
fi

if build "util-macros" "1.20.0"; then
  download "https://www.x.org/archive/individual/util/util-macros-1.20.0.tar.xz"
  execute ./configure --prefix="${WORKSPACE}"
  execute make -j $MJOBS
  execute make install
  build_done "util-macros" "1.20.0"
fi

if build "xorgproto" "2022.2"; then
  download "https://xorg.freedesktop.org/archive/individual/proto/xorgproto-2022.2.tar.gz"
  execute ./configure \
    --prefix="${WORKSPACE}" \
    --sysconfdir=$WORKSPACE/etc \
    --localstatedir=$WORKSPACE/var \
    --disable-dependency-tracking \
    --disable-silent-rules
  execute make -j $MJOBS
  execute make install
  build_done "xorgproto" "2022.2"
fi

if build "libXau" "1.0.11"; then
  download "https://www.x.org/archive/individual/lib/libXau-1.0.11.tar.xz"
  export PKG_CONFIG_PATH="${WORKSPACE}/share/pkgconfig:$PKG_CONFIG_PATH"
  execute ./configure --prefix="${WORKSPACE}"
  execute make -j $MJOBS
  execute make install
  build_done "libXau" "1.0.11"
fi

if build "libXdmcp" "1.1.4"; then
  download "https://www.x.org/archive/individual/lib/libXdmcp-1.1.4.tar.xz"
  export PKG_CONFIG_PATH="${WORKSPACE}/share/pkgconfig:$PKG_CONFIG_PATH"
  execute ./configure --prefix="${WORKSPACE}"
  execute make -j $MJOBS
  execute make install
  build_done "libXdmcp" "1.1.4"
fi

if build "xcb-proto" "1.15.2"; then
  download "https://xorg.freedesktop.org/archive/individual/proto/xcb-proto-1.15.2.tar.xz"
  execute ./configure --prefix="${WORKSPACE}"
  execute make -j $MJOBS
  execute make install
  build_done "xcb-proto" "1.15.2"
fi

if build "libpthread-stubs" "0.4"; then
  download "https://xcb.freedesktop.org/dist/libpthread-stubs-0.4.tar.bz2"
  execute ./configure --prefix="${WORKSPACE}"
  execute make -j $MJOBS
  execute make install
  build_done "libpthread-stubs" "0.4"
fi

if build "libxcb" "1.15"; then
  download "https://xcb.freedesktop.org/dist/libxcb-1.15.tar.gz"
  export PKG_CONFIG_PATH="${WORKSPACE}/share/pkgconfig:$PKG_CONFIG_PATH"
  execute ./configure --prefix="${WORKSPACE}"
  execute make -j $MJOBS
  execute make install
  build_done "libxcb" "1.15"
fi

if build "xtrans" "1.4.0"; then
  download "https://www.x.org/archive/individual/lib/xtrans-1.4.0.tar.bz2"
  execute sed -i "" 's/# include <sys\/stropts.h>/# include <sys\/ioctl.h>/g' Xtranslcl.c
  execute ./configure --prefix="${WORKSPACE}"
  execute make -j $MJOBS
  execute make install
  build_done "xtrans" "1.4.0"
fi

if build "libX11" "1.8.4"; then
  download "https://www.x.org/archive/individual/lib/libX11-1.8.4.tar.gz"
  export LC_ALL=""
  export LC_CTYPE="C"
  export PKG_CONFIG_PATH="${WORKSPACE}/share/pkgconfig:$PKG_CONFIG_PATH"
  execute ./configure --prefix="${WORKSPACE}"
  execute make -j $MJOBS
  execute make install
  build_done "libX11" "1.8.4"
fi

if build "python" "3.10"; then
  cd $PACKAGES
  git clone https://github.com/python/cpython --branch 3.10
  cd cpython
  execute ./configure \
    --prefix="${WORKSPACE}" \
    --with-pydebug \
    --with-openssl="${WORKSPACE}"
  execute make -j $MJOBS
  execute make install

  build_done "python" "3.10"
fi

if command_exists "python3"; then
  if command_exists "pip3"; then
    # meson and ninja can be installed via pip3
    execute pip3 install pip setuptools --quiet --upgrade --no-cache-dir --disable-pip-version-check
    for r in meson ninja jsonschema Jinja2; do
      if ! command_exists ${r}; then
        execute pip3 install ${r} --quiet --upgrade --no-cache-dir --disable-pip-version-check
      fi
    done
  fi
fi

if build "cmake" "3.25.1"; then
  download "https://github.com/Kitware/CMake/releases/download/v3.25.1/cmake-3.25.1.tar.gz"
  execute ./configure \
    --prefix="${WORKSPACE}" \
    --parallel="${MJOBS}" -- \
    -DCMAKE_USE_OPENSSL=OFF
  execute make -j $MJOBS
  execute make install
  build_done "cmake" "3.25.1"
fi

if build "libtiff" "4.5.0"; then
  download "https://download.osgeo.org/libtiff/tiff-4.5.0.tar.xz"
  execute ./configure --prefix="${WORKSPACE}" --disable-dependency-tracking --disable-lzma --disable-webp --disable-zstd --without-x
  execute make -j $MJOBS
  execute make install
  build_done "libtiff" "4.5.0"
fi

if build "libjpeg-turbo" "main"; then
  cd $PACKAGES
  git clone https://github.com/libjpeg-turbo/libjpeg-turbo.git --branch main --depth 1
  cd libjpeg-turbo
  make_dir build
  cd build || exit  
  execute cmake ../ \
    -DCMAKE_INSTALL_PREFIX="${WORKSPACE}" \
    -DCMAKE_INSTALL_NAME_DIR="${WORKSPACE}"/lib \
    -DCMAKE_BUILD_TYPE=Release \
    -DWITH_JPEG8=1
  execute make -j $MJOBS all
  execute make install

  build_done "libjpeg-turbo" "main"
fi

if build "lcms2" "master"; then
  cd $PACKAGES
  git clone https://github.com/mm2/Little-CMS.git --branch master --depth 1
  cd Little-CMS
  execute ./configure --prefix="${WORKSPACE}"
  execute make -j $MJOBS
  execute make install

  build_done "lcms2" "master"
fi

if build "glslang" "main"; then
  cd $PACKAGES
  git clone https://github.com/KhronosGroup/glslang.git --branch main --depth 1
  cd glslang
  make_dir build
  cd build || exit  
  execute cmake ../ \
    -DCMAKE_INSTALL_PREFIX="${WORKSPACE}" \
    -DCMAKE_INSTALL_NAME_DIR="${WORKSPACE}"/lib \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_EXTERNAL=OFF \
    -DENABLE_CTEST=OFF
  execute make -j $MJOBS all
  execute make install

  build_done "glslang" "main"
fi

if build "mujs" "master"; then
  cd $PACKAGES
  git clone https://github.com/ccxvii/mujs.git --branch master --depth 1
  cd mujs
  execute make -j $MJOBS release
  execute make prefix="${WORKSPACE}" install
  build_done "mujs" "master"
fi

if build "libplacebo" "master"; then
  cd $PACKAGES
  git clone --recursive https://github.com/haasn/libplacebo.git
  cd libplacebo
  execute meson setup build \
    --prefix="${WORKSPACE}" \
    --buildtype=release \
    -Dvulkan=disabled \
    -Ddemos=false
  execute meson compile -C build
  execute meson install -C build

  build_done "libplacebo" "master"
fi

if build "luajit2" "v2.1-agentzh"; then
  cd $PACKAGES
  git clone https://github.com/openresty/luajit2.git --branch v2.1-agentzh --depth 1
  cd luajit2
  execute make -j $MJOBS amalg PREFIX="${WORKSPACE}" XCFLAGS=-DLUAJIT_ENABLE_GC64
  execute make install PREFIX="${WORKSPACE}" XCFLAGS=-DLUAJIT_ENABLE_GC64

  build_done "luajit2" "v2.1-agentzh"
fi

if build "uchardet" "master"; then
  cd $PACKAGES
  git clone https://gitlab.freedesktop.org/uchardet/uchardet.git --branch master --depth 1
  cd uchardet
  make_dir build
  cd build || exit  
  execute cmake ../ \
    -DCMAKE_INSTALL_PREFIX="${WORKSPACE}" \
    -DCMAKE_INSTALL_NAME_DIR="${WORKSPACE}"/lib \
    -DCMAKE_BUILD_TYPE=Release
  execute make -j $MJOBS all
  execute make install

  build_done "uchardet" "master"
fi

##
## video library
##

if build "dav1d" "master"; then
  cd $PACKAGES
  git clone https://github.com/videolan/dav1d.git --branch master --depth 1
  cd dav1d
  make_dir build
      
  CFLAGSBACKUP=$CFLAGS
  if $MACOS_M1; then
    export CFLAGS="-arch arm64"
  fi
      
  execute meson build --prefix="${WORKSPACE}" --buildtype=release --libdir="${WORKSPACE}"/lib
  execute ninja -C build
  execute ninja -C build install
      
  if $MACOS_M1; then
    export CFLAGS=$CFLAGSBACKUP
  fi
      
  build_done "dav1d" "master"
fi
CONFIGURE_OPTIONS+=("--enable-libdav1d")

if build "davs2" "master"; then
  cd $PACKAGES
  git clone https://github.com/pkuvcl/davs2.git --branch master --depth 1
  cd davs2/build/linux
  execute ./configure \
    --prefix="${WORKSPACE}" \
    --enable-shared \
    --disable-static \
    --disable-cli \
    --enable-lto \
    --enable-pic
  execute make -j $MJOBS
  execute make install

  build_done "davs2" "master"
fi  
CONFIGURE_OPTIONS+=("--enable-libdavs2")

if build "frei0r" "master"; then
  cd $PACKAGES
  git clone https://github.com/dyne/frei0r.git --branch master --depth 1
  cd frei0r
  # Disable opportunistic linking against Cairo
  execute sed -i "" '/find_package (Cairo)/d' CMakeLists.txt
  make_dir build
  cd build || exit  
  execute cmake ../ \
    -DCMAKE_INSTALL_PREFIX="${WORKSPACE}" \
    -DWITHOUT_OPENCV=ON \
    -DWITHOUT_GAVL=ON
  execute make -j $MJOBS
  execute make install

  build_done "frei0r" "master"
fi  
CONFIGURE_OPTIONS+=("--enable-frei0r")

if build "libpng" "libpng16"; then
  cd $PACKAGES
  git clone --recursive https://github.com/glennrp/libpng.git --branch libpng16 --depth 1
  cd libpng
  export LDFLAGS="${LDFLAGS}"
  export CPPFLAGS="${CFLAGS}"
  execute ./configure --prefix="${WORKSPACE}"
  execute make -j $MJOBS
  execute make install
  build_done "libpng" "libpng16"
fi

if build "freetype" "master"; then
  cd $PACKAGES
  git clone --recursive https://github.com/freetype/freetype.git --branch master --depth 1
  cd freetype
  #Fix glibtoolize: command not found
  sed -i "" 's/glibtoolize/libtoolize/g' autogen.sh  
  execute ./autogen.sh
  execute ./configure \
    --prefix="${WORKSPACE}" \
    --enable-freetype-config \
    --without-harfbuzz
  execute make -j $MJOBS
  execute make install
  build_done "freetype" "master"
fi  
CONFIGURE_OPTIONS+=("--enable-libfreetype")

if build "fribidi" "master"; then
  cd $PACKAGES
  git clone https://github.com/fribidi/fribidi.git --branch master --depth 1
  cd fribidi
  execute meson setup build \
    --prefix="${WORKSPACE}" \
    --buildtype=release \
    -Ddocs=false \
    -Dbin=false \
    -Dtests=false \
    --libdir="${WORKSPACE}"/lib
  execute meson compile -C build
  execute meson install -C build

  build_done "friBidi" "master"
fi

if build "harfbuzz" "main"; then
  cd $PACKAGES
  git clone https://github.com/harfbuzz/harfbuzz.git --branch main --depth 1
  cd harfbuzz
  execute meson setup build \
    --prefix="${WORKSPACE}" \
    --buildtype=release \
    --default-library=both \
    --libdir="${WORKSPACE}"/lib
  execute meson compile -C build
  execute meson install -C build
  
  build_done "harfbuzz" "main"
fi

if build "libunibreak" "master"; then
  cd $PACKAGES
  git clone https://github.com/adah1972/libunibreak.git --branch master --depth 1
  cd libunibreak
  execute ./autogen.sh
  execute ./configure --prefix="${WORKSPACE}"
  execute make -j $MJOBS
  execute make install

  build_done "libunibreak" "master"   
fi

if build "libass" "master"; then
  cd $PACKAGES
  git clone https://github.com/libass/libass.git --branch master --depth 1
  cd libass
  execute ./autogen.sh
  execute ./configure --prefix="${WORKSPACE}" --disable-fontconfig
  execute make -j $MJOBS
  execute make install

  build_done "libass" "master"   
fi
CONFIGURE_OPTIONS+=("--enable-libass")

if build "fontconfig" "main"; then
  cd $PACKAGES
  git clone https://gitlab.freedesktop.org/fontconfig/fontconfig.git --branch main --depth 1
  cd fontconfig
  execute ./autogen.sh
  execute ./configure \
    --prefix="${WORKSPACE}" \
    --disable-docs \
    --enable-static
  execute make -j $MJOBS
  execute make install

  build_done "fontconfig" "main"
fi  
CONFIGURE_OPTIONS+=("--enable-libfontconfig")

if build "libbluray" "master"; then
  cd $PACKAGES
  git clone --recursive https://code.videolan.org/videolan/libbluray.git
  cd libbluray
  execute ./bootstrap
  execute ./configure \
    --prefix="${WORKSPACE}" \
    --disable-dependency-tracking \
    --disable-silent-rules \
    --disable-bdjava-jar
  execute make -j $MJOBS
  execute make install

  build_done "libbluray" "master"
fi  
CONFIGURE_OPTIONS+=("--enable-libbluray")

if build "lame" "3.100"; then
  download "http://downloads.sourceforge.net/lame/lame-3.100.tar.gz" "lame-3.100.tar.gz"
  sed -i "" '/lame_init_old/d' include/libmp3lame.sym
  execute ./configure --prefix="${WORKSPACE}"
  execute make -j $MJOBS
  execute make install

  build_done "lame" "3.100"
fi
CONFIGURE_OPTIONS+=("--enable-libmp3lame")

if build "libogg" "master"; then
  cd $PACKAGES
  git clone https://github.com/xiph/ogg.git --branch master --depth 1
  cd ogg
  execute ./autogen.sh
  execute ./configure --prefix="${WORKSPACE}"
  execute make -j $MJOBS
  execute make install
  build_done "libogg" "master"
fi

if build "libbs2b" "master"; then
  cd $PACKAGES
  git clone https://github.com/alexmarsev/libbs2b.git --branch master --depth 1
  cd libbs2b
  # Build library only
  curl -OL https://raw.githubusercontent.com/shinchiro/mpv-winbuild-cmake/master/packages/libbs2b-0001-build-library-only.patch
  execute patch -p1 -i libbs2b-0001-build-library-only.patch
  execute ./autogen.sh
  execute ./configure \
    --prefix="${WORKSPACE}" \
    --disable-static \
    --enable-shared
  execute make -j $MJOBS
  execute make install

  build_done "libbs2b" "master"
fi 
CONFIGURE_OPTIONS+=("--enable-libbs2b") 

if build "libcaca" "main"; then
  cd $PACKAGES
  git clone https://github.com/cacalabs/libcaca.git --branch main --depth 1
  cd libcaca
  curl $CURL_RETRIES -OL https://github.com/cacalabs/libcaca/pull/70.patch
  patch -p1 -i 70.patch
  execute autoreconf -fvi
  execute ./configure \
    --prefix="${WORKSPACE}" \
    --disable-cocoa \
    --disable-csharp \
    --disable-doc \
    --disable-java \
    --disable-python \
    --disable-ruby \
    --disable-slang \
    --disable-x11
  execute make -j $MJOBS
  execute make install

  build_done "libcaca" "main"
fi 
CONFIGURE_OPTIONS+=("--enable-libcaca")

if build "brotli" "master"; then
  cd $PACKAGES
  git clone https://github.com/google/brotli.git --branch master --depth 1
  cd brotli
  #fix utimensat is only available on macOS 10.13 or newer.
  curl -OL https://raw.githubusercontent.com/eko5624/mpv-macos-intel/SDK-10.11/fix-utimensat.patch
  execute patch -p1 -i fix-utimensat.patch
  make_dir out
  cd out || exit  
  execute cmake ../ \
    -DCMAKE_INSTALL_PREFIX="${WORKSPACE}" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_NAME_DIR="${WORKSPACE}"/lib
  execute make -j $MJOBS
  execute make install

  build_done "brotli" "master"
fi

if build "highway" "master"; then
  cd $PACKAGES
  git clone https://github.com/google/highway.git --branch master --depth 1
  cd highway
  make_dir out
  cd out || exit  
  execute cmake ../ \
    -DCMAKE_INSTALL_PREFIX="${WORKSPACE}" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_NAME_DIR="${WORKSPACE}"/lib \
    -DBUILD_TESTING=OFF \
    -DCMAKE_GNUtoMS=OFF \
    -DHWY_CMAKE_ARM7=OFF \
    -DHWY_ENABLE_CONTRIB=OFF \
    -DHWY_ENABLE_EXAMPLES=OFF \
    -DHWY_ENABLE_INSTALL=ON \
    -DHWY_WARNINGS_ARE_ERRORS=OFF
  execute make -j $MJOBS
  execute make install

  build_done "highway" "master"
fi

if build "libjxl" "main"; then
  cd $PACKAGES
  git clone https://github.com/libjxl/libjxl.git --branch main --depth 1
  cd libjxl
  execute curl -OL https://raw.githubusercontent.com/eko5624/mpv-macos-intel/SDK-10.11/libjxl-fix-exclude-libs.patch
  execute patch -p1 -i libjxl-fix-exclude-libs.patch
  make_dir build
  cd build || exit  
  execute cmake ../ \
    -DCMAKE_INSTALL_PREFIX="${WORKSPACE}" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_NAME_DIR="${WORKSPACE}"/lib \
    -DBUILD_TESTING=OFF \
    -DJPEGXL_EMSCRIPTEN=OFF \
    -DJPEGXL_BUNDLE_LIBPNG=OFF \
    -DJPEGXL_ENABLE_TOOLS=OFF \
    -DJPEGXL_ENABLE_VIEWERS=OFF \
    -DJPEGXL_ENABLE_DOXYGEN=OFF \
    -DJPEGXL_ENABLE_EXAMPLES=OFF \
    -DJPEGXL_ENABLE_MANPAGES=OFF \
    -DJPEGXL_ENABLE_JNI=OFF \
    -DJPEGXL_ENABLE_SKCMS=OFF \
    -DJPEGXL_ENABLE_PLUGINS=OFF \
    -DJPEGXL_ENABLE_DEVTOOLS=OFF \
    -DJPEGXL_ENABLE_BENCHMARK=OFF \
    -DJPEGXL_ENABLE_SJPEG=OFF
  execute make -j $MJOBS
  execute make install

  build_done "libjxl" "main"
fi  
CONFIGURE_OPTIONS+=("--enable-libjxl")

if build "libmodplug" "master"; then
  cd $PACKAGES
  git clone https://github.com/Konstanty/libmodplug.git --branch master --depth 1
  cd libmodplug
  # Fix -flat_namespace being used on Big Sur and later.
  # curl $CURL_RETRIES -OL "https://raw.githubusercontent.com/Homebrew/formula-patches/03cf8088210822aa2c1ab544ed58ea04c897d9c4/libtool/configure-big_sur.diff"
  # execute patch -p1 -i configure-big_sur.diff || true
  execute autoreconf -fvi
  execute ./configure \
    --prefix="${WORKSPACE}" \
    --disable-debug \
    --disable-dependency-tracking \
    --disable-silent-rules \
    --enable-static
  execute make -j $MJOBS
  execute make install

  build_done "libmodplug" "master"
fi 
CONFIGURE_OPTIONS+=("--enable-libmodplug")

if build "libmysofa" "main"; then
  cd $PACKAGES
  git clone https://github.com/hoene/libmysofa.git --branch main --depth 1
  cd libmysofa
  make_dir build
  cd build || exit  
  execute cmake ../ \
    -DCMAKE_INSTALL_PREFIX="${WORKSPACE}" \
    -DCMAKE_INSTALL_NAME_DIR="${WORKSPACE}"/lib \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_TESTS=OFF
  execute make -j $MJOBS all
  execute make install

  build_done "libmysofa" "main"
fi 
CONFIGURE_OPTIONS+=("--enable-libmysofa")

if build "cjson" "master"; then
  cd $PACKAGES
  git clone https://github.com/DaveGamble/cJSON.git --branch master --depth 1
  cd cJSON
  make_dir build
  cd build || exit  
  execute cmake ../ \
    -DCMAKE_INSTALL_PREFIX="${WORKSPACE}" \
    -DCMAKE_INSTALL_NAME_DIR="${WORKSPACE}"/lib \
    -DCMAKE_BUILD_TYPE=Release \
    -DENABLE_CJSON_UTILS=On \
    -DENABLE_CJSON_TEST=Off
  execute make -j $MJOBS all
  execute make install

  build_done "cjson" "master"
fi

if build "mbedtls" "development"; then
  cd $PACKAGES
  git clone https://github.com/Mbed-TLS/mbedtls --branch development --depth 1
  cd mbedtls
  # enable pthread mutexes
  sed -i "" 's|//#define MBEDTLS_THREADING_PTHREAD|#define MBEDTLS_THREADING_PTHREAD|g' include/mbedtls/mbedtls_config.h
  # allow use of mutexes within mbed TLS
  sed -i "" 's|//#define MBEDTLS_THREADING_C|#define MBEDTLS_THREADING_C|g' include/mbedtls/mbedtls_config.h
  make_dir build
  cd build || exit  
  execute cmake ../ \
    -DCMAKE_INSTALL_PREFIX="${WORKSPACE}" \
    -DCMAKE_INSTALL_NAME_DIR="${WORKSPACE}"/lib \
    -DCMAKE_BUILD_TYPE=Release \
    -DUSE_SHARED_MBEDTLS_LIBRARY=On \
    -DPython3_EXECUTABLE="${WORKSPACE}"/bin/python3 \
    -DENABLE_TESTING=OFF \
    -DGEN_FILES=ON
  execute make -j $MJOBS all
  execute make install

  build_done "mbedtls" "development"
fi

if build "librist" "master"; then
  cd $PACKAGES
  git clone https://code.videolan.org/rist/librist.git --branch master --depth 1
  cd librist
  execute meson setup build \
    --prefix="${WORKSPACE}" \
    --buildtype=release \
    --libdir="${WORKSPACE}"/lib
  execute meson compile -C build
  execute meson install -C build

  build_done "librist" "master"
fi 
CONFIGURE_OPTIONS+=("--enable-librist")

if build "libssh" "master"; then
  cd $PACKAGES
  git clone https://gitlab.com/libssh/libssh-mirror.git --branch master --depth 1
  cd libssh-mirror
  export OPENSSL_ROOT_DIR="${WORKSPACE}"
  export ZLIB_ROOT_DIR="${WORKSPACE}"
  make_dir build
  cd build || exit  
  execute cmake ../ \
    -DCMAKE_INSTALL_PREFIX="${WORKSPACE}" \
    -DCMAKE_INSTALL_NAME_DIR="${WORKSPACE}"/lib \
    -DCMAKE_BUILD_TYPE=Release \
    -DWITH_SYMBOL_VERSIONING=OFF
  execute make -j $MJOBS
  execute make install

  build_done "libssh" "master"
fi
CONFIGURE_OPTIONS+=("--enable-libssh")

if build "libtheora" "master"; then
  cd $PACKAGES
  git clone https://gitlab.xiph.org/xiph/theora.git --branch master --depth 1
  cd theora
  cp "${WORKSPACE}"/share/libtool/*/config.{guess,sub} ./
  execute ./autogen.sh
  execute ./configure \
    --prefix="${WORKSPACE}" \
    --with-ogg-libraries="${WORKSPACE}"/lib \
    --with-ogg-includes="${WORKSPACE}"/include/ \
    --with-vorbis-libraries="${WORKSPACE}"/lib \
    --with-vorbis-includes="${WORKSPACE}"/include/ \
    --disable-oggtest \
    --disable-vorbistest \
    --disable-examples \
    --disable-asm \
    --disable-spec
  execute make -j $MJOBS
  execute make install

  build_done "libtheora" "master"
fi
CONFIGURE_OPTIONS+=("--enable-libtheora")

if build "libvorbis" "master"; then
  cd $PACKAGES
  git clone https://github.com/AO-Yumi/vorbis_aotuv.git --branch master --depth 1
  cd vorbis_aotuv
  execute chmod +x ./autogen.sh
  execute ./autogen.sh
  execute ./configure \
    --prefix="${WORKSPACE}" \
    --with-ogg-libraries="${WORKSPACE}"/lib \
    --with-ogg-includes="${WORKSPACE}"/include/ \
    --disable-oggtest
  execute make -j $MJOBS
  execute make install

  build_done "libvorbis" "master"
fi
CONFIGURE_OPTIONS+=("--enable-libvorbis")

if build "libvpx" "main"; then
  cd $PACKAGES
  git clone https://chromium.googlesource.com/webm/libvpx.git --branch main --depth 1 
  cd libvpx
  echo "Applying Darwin patch"
  sed "s/,--version-script//g" build/make/Makefile >build/make/Makefile.patched
  sed "s/-Wl,--no-undefined -Wl,-soname/-Wl,-undefined,error -Wl,-install_name/g" build/make/Makefile.patched >build/make/Makefile
  cd build
  execute ../configure \
    --prefix="${WORKSPACE}" \
    --disable-dependency-tracking \
    --disable-examples \
    --disable-unit-tests \
    --enable-pic \
    --enable-shared \
    --enable-vp9-highbitdepth \
    --enable-runtime-cpu-detect \
    --as=yasm
  execute make -j $MJOBS
  execute make install

  build_done "libvpx" "main"
fi
CONFIGURE_OPTIONS+=("--enable-libvpx")

if build "libwebp" "main"; then
  cd $PACKAGES
  git clone https://chromium.googlesource.com/webm/libwebp.git --branch main --depth 1
  cd libwebp
  execute ./autogen.sh
  execute ./configure \
    --prefix="${WORKSPACE}" \
    --disable-dependency-tracking \
    --disable-gl \
    --with-zlib-include="${WORKSPACE}"/include/ \
    --with-zlib-lib="${WORKSPACE}"/lib
  execute make -j $MJOBS
  execute make install
  build_done "libwebp" "main"
fi
CONFIGURE_OPTIONS+=("--enable-libwebp")

if build "opencore" "0.1.6"; then
  download "https://netactuate.dl.sourceforge.net/project/opencore-amr/opencore-amr/opencore-amr-0.1.6.tar.gz" "opencore-amr-0.1.6.tar.gz"
  execute ./configure --prefix="${WORKSPACE}"
  execute make -j $MJOBS
  execute make install

  build_done "opencore" "0.1.6"
fi
CONFIGURE_OPTIONS+=("--enable-libopencore_amrnb" "--enable-libopencore_amrwb")

if build "opus" "master"; then
  cd $PACKAGES
  git clone https://github.com/xiph/opus.git --branch master --depth 1
  cd opus
  execute ./autogen.sh
  execute ./configure --prefix="${WORKSPACE}"
  execute make -j $MJOBS
  execute make install

  build_done "opus" "master"
fi
CONFIGURE_OPTIONS+=("--enable-libopus")

if build "libsamplerate" "master"; then
  cd $PACKAGES
  git clone https://github.com/libsndfile/libsamplerate.git --branch master --depth 1
  cd libsamplerate
  execute ./autogen.sh
  execute ./configure --prefix="${WORKSPACE}"
  execute make -j $MJOBS
  execute make install

  build_done "libsamplerate" "master"
fi

if build "mpg123" "1.31.2"; then
  download "https://www.mpg123.de/download/mpg123-1.31.2.tar.bz2"
  execute ./configure \
    --prefix="${WORKSPACE}" \
    --disable-debug \
    --disable-dependency-tracking \
    --enable-static \
    --with-default-audio=coreaudio \
    --with-cpu=x86-64
    
    
  execute make -j $MJOBS
  execute make install

  build_done "mpg123" "1.31.2"
fi

if build "flac" "master"; then
  cd $PACKAGES
  git clone https://gitlab.xiph.org/xiph/flac.git --branch master --depth 1
  cd flac
  execute ./autogen.sh
  execute ./configure \
    --prefix="${WORKSPACE}" \
    --disable-debug \
    --disable-dependency-tracking \
    --enable-static
  execute make -j $MJOBS
  execute make install

  build_done "flac" "master"
fi

if build "libsndfile" "master"; then
  cd $PACKAGES
  git clone https://github.com/libsndfile/libsndfile.git --branch master --depth 1
  cd libsndfile
  make_dir build
  cd build || exit  
  execute cmake ../ \
    -DCMAKE_INSTALL_PREFIX="${WORKSPACE}" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_NAME_DIR="${WORKSPACE}"/lib \
    -DBUILD_SHARED_LIBS=ON \
    -DBUILD_PROGRAMS=ON \
    -DENABLE_PACKAGE_CONFIG=ON \
    -DINSTALL_PKGCONFIG_MODULE=ON \
    -DBUILD_EXAMPLES=OFF \
    -DPYTHON_EXECUTABLE="${WORKSPACE}"/bin/python3
  execute make -j $MJOBS
  execute make install

  build_done "libsndfile" "master"
fi

if build "rubberband" "default"; then
  cd $PACKAGES
  git clone https://github.com/breakfastquay/rubberband.git --branch default --depth 1
  cd rubberband
  execute meson setup build \
    --prefix="${WORKSPACE}" \
    --buildtype=release \
    --libdir="${WORKSPACE}"/lib \
    -Dresampler=libsamplerate
  execute meson compile -C build
  execute meson install -C build

  build_done "rubberband" "default"
fi 
CONFIGURE_OPTIONS+=("--enable-librubberband")

if build "libsdl" "main"; then
  cd $PACKAGES
  git clone https://github.com/libsdl-org/SDL.git --branch main --depth 1
  cd SDL
  make_dir build
  cd build || exit  
  execute cmake ../ \
    -DCMAKE_INSTALL_PREFIX="${WORKSPACE}" \
    -DCMAKE_INSTALL_NAME_DIR="${WORKSPACE}"/lib \
    -DCMAKE_BUILD_TYPE=Release
  execute make -j $MJOBS
  execute make install

  build_done "libsdl" "main"
fi

if build "snappy" "main"; then
  cd $PACKAGES
  git clone --recursive https://github.com/google/snappy.git --branch main --depth 1
  cd snappy
  make_dir build
  cd build || exit  
  execute cmake ../ \
    -DCMAKE_INSTALL_PREFIX="${WORKSPACE}" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_NAME_DIR="${WORKSPACE}"/lib \
    -DBUILD_SHARED_LIBS=ON \
    -DSNAPPY_BUILD_TESTS=OFF \
    -DSNAPPY_BUILD_BENCHMARKS=OFF
  execute make -j $MJOBS
  execute make install

  build_done "snappy" "main"
fi
CONFIGURE_OPTIONS+=("--enable-libsnappy")

if build "soxr" "master"; then
  cd $PACKAGES
  git clone https://github.com/chirlu/soxr.git --branch master --depth 1
  cd soxr
  # Fixes the build on 64-bit ARM macOS; the __arm__ define used in the
  # code isn't defined on 64-bit Apple Silicon.
  # Upstream pull request: https://sourceforge.net/p/soxr/code/merge-requests/5/
  download "https://raw.githubusercontent.com/Homebrew/formula-patches/76868b36263be42440501d3692fd3a258f507d82/libsoxr/arm64_defines.patch"
  execute patch -p1 -i "${PACKAGES}/arm64_defines.patch" || true
  make_dir build
  cd build || exit  
  execute cmake ../ \
    -DCMAKE_INSTALL_PREFIX="${WORKSPACE}" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_NAME_DIR="${WORKSPACE}"/lib
  execute make -j $MJOBS
  execute make install

  build_done "soxr" "master"
fi
CONFIGURE_OPTIONS+=("--enable-libsoxr")

if build "speex" "master"; then
  cd $PACKAGES
  git clone https://github.com/xiph/speex.git --branch master --depth 1
  cd speex
  execute ./autogen.sh
  execute ./configure --prefix="${WORKSPACE}"
  execute make -j $MJOBS
  execute make install

  build_done "speex" "master"
fi
CONFIGURE_OPTIONS+=("--enable-libspeex")

if build "srt" "master"; then
  cd $PACKAGES
  git clone https://github.com/Haivision/srt.git
  cd srt 
  export OPENSSL_ROOT_DIR="${WORKSPACE}"
  export OPENSSL_LIB_DIR="${WORKSPACE}"/lib
  export OPENSSL_INCLUDE_DIR="${WORKSPACE}"/include/
  make_dir build
  cd build || exit  
  execute cmake ../ \
    -DCMAKE_INSTALL_PREFIX="${WORKSPACE}" \
    -DCMAKE_INSTALL_NAME_DIR="${WORKSPACE}"/lib \
    -DCMAKE_INSTALL_LIBDIR=lib \
    -DCMAKE_INSTALL_BINDIR=bin \
    -DCMAKE_INSTALL_INCLUDEDIR=include
  execute make install

  build_done "srt" "master"
fi
CONFIGURE_OPTIONS+=("--enable-libsrt")

if build "uavs3d" "master"; then
  cd $PACKAGES
  git clone https://github.com/uavs3/uavs3d.git --branch master --depth 1
  cd uavs3d
  execute mkdir -p build/linux && cd build/linux
  execute cmake ../.. \
    -DCMAKE_INSTALL_PREFIX="${WORKSPACE}" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_NAME_DIR="${WORKSPACE}"/lib \
    -DBUILD_SHARED_LIBS=ON \
    -DCOMPILE_10BIT=ON
  execute make install

  build_done "uavs3d" "master"
fi
CONFIGURE_OPTIONS+=("--enable-libuavs3d")

if build "xvidcore" "1.3.7"; then
download "https://downloads.xvid.com/downloads/xvidcore-1.3.7.tar.gz"
cd build/generic || exit
execute ./configure --prefix="${WORKSPACE}"
execute make -j $MJOBS
execute make install

if [[ -f ${WORKSPACE}/lib/libxvidcore.4.dylib ]]; then
  execute rm "${WORKSPACE}/lib/libxvidcore.4.dylib"
fi

if [[ -f ${WORKSPACE}/lib/libxvidcore.so ]]; then
  execute rm "${WORKSPACE}"/lib/libxvidcore.so*
fi

build_done "xvidcore" "1.3.7"
fi
CONFIGURE_OPTIONS+=("--enable-libxvid")

if build "zimg" "master"; then
  cd $PACKAGES
  git clone --recursive https://github.com/sekrit-twc/zimg.git --branch master --depth 1
  cd zimg
  execute ./autogen.sh
  execute ./configure --prefix="${WORKSPACE}"
  execute make -j $MJOBS
  execute make install
  build_done "zimg" "master"
fi
CONFIGURE_OPTIONS+=("--enable-libzimg")

if build "zvbi" "main"; then
  cd $PACKAGES
  git clone https://github.com/zapping-vbi/zvbi.git --branch main --depth 1
  cd zvbi
  curl $CURL_RETRIES -OL https://raw.githubusercontent.com/videolan/vlc/master/contrib/src/zvbi/zvbi-fix-clang-support.patch
  curl $CURL_RETRIES -OL https://raw.githubusercontent.com/videolan/vlc/master/contrib/src/zvbi/zvbi-ioctl.patch
  curl $CURL_RETRIES -OL https://raw.githubusercontent.com/videolan/vlc/master/contrib/src/zvbi/zvbi-ssize_max.patch
  for patch in ./*.patch; do
      echo "Applying $patch"
      patch -p1 < "$patch"
  done
  execute ./autogen.sh
  execute ./configure \
    --prefix="${WORKSPACE}" \
    --disable-dependency-tracking \
    --disable-silent-rules \
    --without-x
  execute make -C src
  execute make -C src install
  execute make SUBDIRS=. install
  
  build_done "zvbi" "main"
fi
CONFIGURE_OPTIONS+=("--enable-libzvbi")

##
## FFmpeg
##

if build "ffmpeg" "master"; then
  cd $PACKAGES
  git clone https://github.com/FFmpeg/FFmpeg.git --branch master --depth 1
  cd FFmpeg
  execute ./configure "${CONFIGURE_OPTIONS[@]}" \
    --disable-metal \
    --disable-debug \
    --disable-doc \
    --enable-gpl \
    --enable-nonfree \
    --enable-shared \
    --enable-pthreads \
    --cc=clang \
    --enable-version3 \
    --extra-cflags="${CFLAGS}" \
    --extra-ldflags="${LDFLAGS}" \
    --extra-libs="${EXTRALIBS}" \
    --pkgconfigdir="$WORKSPACE/lib/pkgconfig" \
    --prefix="${WORKSPACE}"
  execute make -j $MJOBS
  execute make install

  build_done "FFmpeg" "master"
fi

if build "mpv" "master"; then
  cd $PACKAGES
  git clone https://github.com/mpv-player/mpv.git --branch master --depth 1
  cd mpv
  
  # fix for mpv incorrectly enabling features only available on 10.14
  # https://trac.macports.org/ticket/62177#comment:16
  execute sed -i "" 's/!HAVE_MACOS_10_14_FEATURES/false/g' osdep/macos/swift_compat.swift 
  export TOOLCHAINS=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" /Library/Developer/Toolchains/swift-latest.xctoolchain/Info.plist)
  meson setup build \
    --buildtype=release \
    --libdir="${WORKSPACE}"/lib \
    -Diconv=disabled \
    -Dprefix="${WORKSPACE}" \
    -Dmacos-media-player=disabled \
    -Dmanpage-build=disabled \
    -Dswift-flags="-target x86_64-apple-macos10.11"
  meson compile -C build
  
  # fix can't find libvpx.8.dylib 
  install_name_tool -change "libvpx.8.dylib" "$WORKSPACE/lib/libvpx.8.dylib" "$WORKSPACE/lib/libavcodec.dylib"
  install_name_tool -change "libvpx.8.dylib" "$WORKSPACE/lib/libvpx.8.dylib" "$WORKSPACE/lib/libavdevice.dylib"
  install_name_tool -change "libvpx.8.dylib" "$WORKSPACE/lib/libvpx.8.dylib" "$WORKSPACE/lib/libavfilter.dylib"
  install_name_tool -change "libvpx.8.dylib" "$WORKSPACE/lib/libvpx.8.dylib" "$WORKSPACE/lib/libavformat.dylib"
  python3 TOOLS/osxbundle.py build/mpv

  build_done "mpv" "master"
fi
