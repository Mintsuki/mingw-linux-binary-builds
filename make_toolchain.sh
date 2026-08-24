#! /bin/sh

set -ex

srcdir="$(dirname "$0")"
test -z "$srcdir" && srcdir=.
srcdir="$(cd "${srcdir}" && pwd -P)"

cd "$srcdir"

if [ -z "$TARGET" ]; then
    set +x
    echo "TARGET not specified"
    exit 1
fi

if [ -z "$BINUTILSVERSION" ]; then
    BINUTILSVERSION=2.47
fi

if [ -z "$GCCVERSION" ]; then
    GCCVERSION=16.2.0
fi

if [ -z "$MINGWVERSION" ]; then
    MINGWVERSION=14.0.0
fi

if command -v gmake; then
    export MAKE=gmake
else
    export MAKE=make
fi

if command -v gtar; then
    export TAR=gtar
else
    export TAR=tar
fi

if [ -z "$CFLAGS" ]; then
    export CFLAGS="-O2 -pipe"
fi

unset CC
unset CXX

if [ "$(uname)" = "OpenBSD" ]; then
    # OpenBSD has an awfully ancient GCC which fails to build our toolchain.
    # Force clang/clang++.
    export CC="clang"
    export CXX="clang++"
fi

mkdir -p toolchain && cd toolchain
PREFIX="$(pwd -P)/output"

export MAKEFLAGS="-j$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || psrinfo -tc 2>/dev/null || echo 1)"

export PATH="$PREFIX/bin:$PATH"

if [ ! -f binutils-$BINUTILSVERSION.tar.xz ]; then
    curl -Lo binutils-$BINUTILSVERSION.tar.xz https://ftp.gnu.org/gnu/binutils/binutils-$BINUTILSVERSION.tar.xz
    b2sum binutils-$BINUTILSVERSION.tar.xz | grep -q 329cae8792c500c71d8cce03aab127e8d77f1d409f74872082e64df5163e5c730fe585f8f9c21905cb6227cae18e6675ae4caed653223a26b5d9d4fdb90910ea
fi
if [ ! -f gcc-$GCCVERSION.tar.xz ]; then
    curl -Lo gcc-$GCCVERSION.tar.xz https://ftp.gnu.org/gnu/gcc/gcc-$GCCVERSION/gcc-$GCCVERSION.tar.xz
    b2sum gcc-$GCCVERSION.tar.xz | grep -q ab3ffe16e042da767f3f1eac170da518d6d7de3b0f92e068f79e3bf25fdc0bdf56eea0cd586bd4b9b6e9baebadd110c2ebd77b75c99c45853814f4bea5a98ef0
fi
if [ ! -f mingw-w64-$MINGWVERSION.tar.gz ]; then
    curl -Lo mingw-w64-$MINGWVERSION.tar.gz https://github.com/mingw-w64/mingw-w64/archive/refs/tags/v$MINGWVERSION.tar.gz
    b2sum mingw-w64-$MINGWVERSION.tar.gz | grep -q e2d5b9d7b8a784ed37bc7e5502cd4bfb2d1f760e196867714e3367b623af0f2814750904fb4faaebe95a1a83f0bd82cbf385c24fa1708993261290ad206d55b2
fi

rm -rf build
mkdir build
cd build

$TAR -xf ../binutils-$BINUTILSVERSION.tar.xz
$TAR -xf ../gcc-$GCCVERSION.tar.xz
$TAR -xf ../mingw-w64-$MINGWVERSION.tar.gz

cd binutils-$BINUTILSVERSION
# Apply patches, if any
for patch in "${srcdir}"/toolchain-patches/binutils/*; do
    [ "${patch}" = "${srcdir}/toolchain-patches/binutils/*" ] && break
    patch -p1 < "${patch}"
done
cd ..
mkdir build-binutils
cd build-binutils
../binutils-$BINUTILSVERSION/configure \
    CFLAGS="$CFLAGS" \
    CXXFLAGS="$CFLAGS" \
    --target=$TARGET \
    --prefix="$PREFIX" \
    --with-sysroot="$PREFIX" \
    --disable-nls \
    --disable-werror \
    --disable-multilib
$MAKE
$MAKE install
cd ..

cd mingw-w64-$MINGWVERSION
# Apply patches, if any
for patch in "${srcdir}"/toolchain-patches/mingw/*; do
    [ "${patch}" = "${srcdir}/toolchain-patches/mingw/*" ] && break
    patch -p1 < "${patch}"
done
cd ..

mkdir build-mingw-headers
cd build-mingw-headers
../mingw-w64-$MINGWVERSION/mingw-w64-headers/configure \
    --host=$TARGET \
    --prefix="$PREFIX/$TARGET" \
    --with-default-msvcrt=msvcrt \
    --with-default-win32-winnt=0x0400
$MAKE install
ln -sfn "$TARGET" "$PREFIX/mingw"
cd ..

cd gcc-$GCCVERSION
# Apply patches, if any
for patch in "${srcdir}"/toolchain-patches/gcc/*; do
    [ "${patch}" = "${srcdir}/toolchain-patches/gcc/*" ] && break
    patch -p1 < "${patch}"
done
./contrib/download_prerequisites
cd ..

mkdir build-gcc-bootstrap
cd build-gcc-bootstrap
../gcc-$GCCVERSION/configure \
    CFLAGS="$CFLAGS" \
    CXXFLAGS="$CFLAGS" \
    --target=$TARGET \
    --prefix="$PREFIX" \
    --with-sysroot="$PREFIX" \
    --with-arch="$ARCH" \
    --enable-languages=c,c++ \
    --disable-nls \
    --disable-shared \
    --disable-multilib \
    --disable-threads \
    --disable-libgomp \
    --disable-libquadmath \
    --disable-libssp \
    --disable-libvtv \
    --disable-libstdcxx \
    --disable-libsanitizer \
    --with-newlib \
    --without-headers
$MAKE all-gcc
$MAKE install-gcc
cd ..

mkdir build-mingw-crt
cd build-mingw-crt
../mingw-w64-$MINGWVERSION/mingw-w64-crt/configure \
    CFLAGS="$CFLAGS" \
    CXXFLAGS="$CFLAGS" \
    --host=$TARGET \
    --prefix="$PREFIX/$TARGET" \
    --with-sysroot="$PREFIX" \
    --with-default-msvcrt=msvcrt \
    --disable-lib64 \
    --enable-lib32
$MAKE
$MAKE install
cd ..

mkdir build-gcc
cd build-gcc
../gcc-$GCCVERSION/configure \
    CFLAGS="$CFLAGS" \
    CXXFLAGS="$CFLAGS" \
    --target=$TARGET \
    --prefix="$PREFIX" \
    --with-sysroot="$PREFIX" \
    --with-arch="$ARCH" \
    --enable-languages=c,c++ \
    --enable-sjlj-exceptions \
    --disable-nls \
    --disable-multilib \
    --enable-threads=single \
    --enable-shared \
    --enable-static \
    --enable-fully-dynamic-string \
    --enable-libstdcxx \
    --enable-libstdcxx-time=no \
    --disable-libgomp \
    --disable-libsanitizer \
    --disable-libssp \
    --with-default-libstdcxx-abi=new
$MAKE
$MAKE install
cd ..
