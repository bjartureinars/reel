#!/bin/bash
# Builds reel-torrent, the helper Reel Server uses to download torrents straight to Google Drive.
# libtorrent 2.1.3 (BSD licence), from the official release tarball
# (sha256 de05681acc564651211b4351af7d633a7a225587f0604611d657729dec299ae6), built static with Homebrew's
# Boost headers and static OpenSSL, so the helper needs nothing installed to run.
#   bash Tools/build-torrent.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="$HOME/Developer/Reel"
V="$WORK/vendor"
LT="$V/libtorrent"
TARBALL="$V/libtorrent-download/libtorrent-rasterbar-2.1.3.tar.gz"
SUM=de05681acc564651211b4351af7d633a7a225587f0604611d657729dec299ae6
BOOST=/opt/homebrew/opt/boost
SSL=/opt/homebrew/opt/openssl@4

if [[ ! -f "$LT/lib/libtorrent-rasterbar.a" ]]; then
    command -v cmake >/dev/null || brew install cmake
    [[ -d "$BOOST/include/boost" ]] || brew install boost
    [[ -f "$SSL/lib/libssl.a" ]] || brew install openssl@4
    if [[ ! -f "$TARBALL" ]]; then
        mkdir -p "$(dirname "$TARBALL")"
        curl -sSL --fail -o "$TARBALL" https://github.com/arvidn/libtorrent/releases/download/v2.1.3/libtorrent-rasterbar-2.1.3.tar.gz
    fi
    echo "$SUM  $TARBALL" | shasum -a 256 -c - >/dev/null
    SRC="$V/libtorrent-2.1.3-source"; BUILD="$V/libtorrent-2.1.3-build"
    rm -rf "$SRC" "$BUILD"; mkdir -p "$SRC"
    tar -xzf "$TARBALL" -C "$SRC" --strip-components 1
    cmake -S "$SRC" -B "$BUILD" -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF -DCMAKE_CXX_STANDARD=17 \
        -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 -Ddeprecated-functions=OFF \
        -Dpython-bindings=OFF -Dbuild_examples=OFF -Dbuild_tests=OFF -DOPENSSL_ROOT_DIR="$SSL" \
        -DOPENSSL_USE_STATIC_LIBS=TRUE -DBoost_ROOT="$BOOST" -DCMAKE_INSTALL_PREFIX="$LT" >/dev/null
    cmake --build "$BUILD" -j 8 >/dev/null
    cmake --install "$BUILD" >/dev/null
fi

mkdir -p "$V/reel-torrent"
clang++ -std=c++17 -O2 -arch arm64 -mmacosx-version-min=14.0 -fexceptions \
    -DBOOST_ASIO_NO_DEPRECATED -DBOOST_SYSTEM_USE_UTF8 -DTORRENT_ABI_VERSION=100 -DTORRENT_USE_OPENSSL \
    -DTORRENT_USE_LIBCRYPTO -DTORRENT_SSL_PEERS \
    -I"$LT/include" -I"$SSL/include" -I"$BOOST/include" \
    "$HERE/reel-torrent/main.cpp" -o "$V/reel-torrent/reel-torrent" \
    "$LT/lib/libtorrent-rasterbar.a" "$LT/lib/libdatachannel-static.a" "$LT/lib/libjuice-static.a" "$LT/lib/libusrsctp.a" \
    "$SSL/lib/libssl.a" "$SSL/lib/libcrypto.a" \
    -framework CoreFoundation -framework SystemConfiguration -framework Security
echo "Built $V/reel-torrent/reel-torrent"
