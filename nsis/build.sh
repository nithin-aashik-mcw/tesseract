#!/bin/bash

# GitHub actions - Create Tesseract installer for Windows

# Author: Stefan Weil (2010-2026)

set -e
set -x

LANG=C.UTF-8

ARCH=$1

case "$ARCH" in
  i686)
    MINGW=/mingw32
    ;;
  aarch64)
    MINGW=/clangarm64
    ;;
  *)
    ARCH=x86_64
    MINGW=/mingw64
    ;;
esac

ROOTDIR=$PWD
HOST=$ARCH-w64-mingw32
TAG=$(cat VERSION).$(date +%Y%m%d)
BUILDDIR=bin/ndebug/$HOST
PACMAN_REPO=${MINGW#/}

if [ "$ARCH" = "aarch64" ]; then
  # Ubuntu has no MinGW compiler for ARM64, so use llvm-mingw.
  # Its LLVM version should not be newer than the libc++ of MSYS2 clangarm64,
  # because the installer ships the libc++ DLL from MSYS2.
  LLVM_MINGW_TAG=20260616
  LLVM_MINGW=llvm-mingw-$LLVM_MINGW_TAG-ucrt-ubuntu-22.04-x86_64
  PKG_PREFIX=mingw-w64-clang-aarch64
  TOOLCHAIN_DEBS=
  EXTRA_PKGS="$PKG_PREFIX-libc++ $PKG_PREFIX-libunwind"
else
  PKG_ARCH=mingw-w64-${ARCH/_/-}
  PKG_PREFIX=mingw-w64-$ARCH
  TOOLCHAIN_DEBS="mingw-w64-tools g++-$PKG_ARCH"
  EXTRA_PKGS=
fi

# Install packages.
sudo apt-get update --quiet
sudo apt-get install --assume-yes --no-install-recommends --quiet \
  asciidoctor ruby-asciidoctor-pdf curl \
  automake dpkg-dev libtool pkg-config default-jdk-headless \
  nsis $TOOLCHAIN_DEBS \
  makepkg pacman-package-manager python3-venv unzip xz-utils

if [ -n "$LLVM_MINGW" ]; then
  curl -sSL "https://github.com/mstorsjo/llvm-mingw/releases/download/$LLVM_MINGW_TAG/$LLVM_MINGW.tar.xz" |
    sudo tar -xJ -C /opt
  export PATH=/opt/$LLVM_MINGW/bin:$PATH
fi

# Configure pacman.

# Enable mirrorlist.
sudo sed -Ei 's/^#.*(Include.*mirrorlist)/\1/' /etc/pacman.conf
(
# Add msys key for pacman.
cd /usr/share/keyrings
sudo curl -OsS https://raw.githubusercontent.com/msys2/MSYS2-keyring/master/msys2.gpg
sudo curl -OsS https://raw.githubusercontent.com/msys2/MSYS2-keyring/master/msys2-revoked
sudo curl -OsS https://raw.githubusercontent.com/msys2/MSYS2-keyring/master/msys2-trusted
)
(
# Add active environments for pacman.
# See https://www.msys2.org/docs/repos-mirrors/.
sudo mkdir -p /etc/pacman.d
cd /etc/pacman.d
cat <<eod | sudo tee mirrorlist >/dev/null
[$PACMAN_REPO]
Include = /etc/pacman.d/mirrorlist.mingw
eod
sudo curl -OsS https://raw.githubusercontent.com/msys2/MSYS2-packages/master/pacman-mirrors/mirrorlist.mingw
# sudo curl -OsS https://raw.githubusercontent.com/msys2/MSYS2-packages/master/pacman-mirrors/mirrorlist.msys
)

sudo pacman-key --init
sudo pacman-key --populate msys2
sudo pacman -Syu --noconfirm

# Install required pacman packages.
sudo pacman -S --noconfirm \
 $PKG_PREFIX-curl-winssl \
 $PKG_PREFIX-giflib \
 $PKG_PREFIX-icu \
 $PKG_PREFIX-leptonica \
 $PKG_PREFIX-libarchive \
 $PKG_PREFIX-libidn2 \
 $PKG_PREFIX-openjpeg2 \
 $PKG_PREFIX-openssl \
 $PKG_PREFIX-pango \
 $PKG_PREFIX-libpng \
 $PKG_PREFIX-libtiff \
 $PKG_PREFIX-libwebp \
 $EXTRA_PKGS

git config --global user.email "sw@weilnetz.de"
git config --global user.name "Stefan Weil"
git tag -a "v$TAG" -m "Tesseract $TAG"

# Run autogen.
./autogen.sh

# Build Tesseract installer.
mkdir -p "$BUILDDIR" && cd "$BUILDDIR"

# Run configure.
PKG_CONFIG_PATH=$MINGW/lib/pkgconfig
export PKG_CONFIG_PATH
# Disable OpenMP (see https://github.com/tesseract-ocr/tesseract/issues/1662).
if [ "$ARCH" = "aarch64" ]; then
  # The MSYS2 headers must be searched after those of libc++ and llvm-mingw,
  # otherwise libc++ fails to find its own wrappers for the C headers.
  PKG_CONFIG_SYSTEM_INCLUDE_PATH=$MINGW/include
  export PKG_CONFIG_SYSTEM_INCLUDE_PATH
  ../../../configure --disable-openmp --host="$HOST" --prefix="/usr/$HOST" \
    CC="$HOST-clang" CXX="$HOST-clang++" \
    CXXFLAGS="-fno-math-errno -Wall -Wextra -Wpedantic -g -O2 -idirafter $MINGW/include" \
    LDFLAGS="-L$MINGW/lib"
else
  ../../../configure --disable-openmp --host="$HOST" --prefix="/usr/$HOST" \
    CXX="$HOST-g++-posix" \
    CXXFLAGS="-fno-math-errno -Wall -Wextra -Wpedantic -g -O2 -isystem $MINGW/include" \
    LDFLAGS="-L$MINGW/lib"
fi

make all -j$(nproc)
make training -j$(nproc)

MINGW_INSTALL=${PWD}${MINGW}
if [ "$ARCH" = "aarch64" ]; then
  # The strip program of the build host does not support ARM64 Windows binaries.
  make install-jars install training-install html prefix="$MINGW_INSTALL"
  "$HOST-strip" "$MINGW_INSTALL"/bin/*.exe "$MINGW_INSTALL"/bin/*.dll
else
  make install-jars install training-install html prefix="$MINGW_INSTALL" INSTALL_STRIP_FLAG=-s
fi
test -d venv || python3 -m venv venv
source venv/bin/activate
pip install pefile
mkdir -p dll
ln -sv $("$ROOTDIR/nsis/find_deps.py" --dlldir "$MINGW/bin/" "$MINGW_INSTALL"/bin/*.exe "$MINGW_INSTALL"/bin/*.dll) dll/
if [ "$ARCH" = "aarch64" ]; then
  # libc++ and libunwind were found in $MINGW/bin by find_deps.py.
  make winsetup prefix="$MINGW_INSTALL" \
    WINPATH_CXX="$HOST-clang++ -static" WINPATH_STRIP="$HOST-strip"
else
  ln -svf /usr/lib/gcc/x86_64-w64-mingw32/*-win32/libstdc++-6.dll dll/
  ln -svf /usr/lib/gcc/x86_64-w64-mingw32/*-win32/libgcc_s_seh-1.dll dll/
  make winsetup prefix="$MINGW_INSTALL"
fi
