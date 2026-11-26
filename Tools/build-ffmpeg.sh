#!/bin/bash
# Builds the part of FFmpeg that Reel for iPhone, iPad and Apple TV needs (LGPL 2.1+, no GPL code, no network code):
# read films, pass the picture through untouched, and turn sound iOS can't play into
# Apple Lossless. The H.264 and HEVC decoders are only there because opening a film needs them to read its
# colour information (HDR); the picture itself is never decoded.
#
#   bash Tools/build-ffmpeg.sh                         every platform
#   bash Tools/build-ffmpeg.sh appletvos appletvsimulator   only those
#
# Source: the official ffmpeg-8.1.3.tar.xz, whose files were compared with tag n8.1.3 on 2026-11-22.
# One change of Reel's own, Tools/ffmpeg-dovi-p81.patch (LGPL like the file it changes): FFmpeg's dovi_rpu
# filter can turn Dolby Vision profile 7 (UHD Blu-ray) into profile 8.1, which Apple devices play.
set -euo pipefail

VERSION="8.1.3"
SHA256="7138d28c96d9d3e3af4ee3d8cad72741f8ffb40da90c1112235dea3ecd3178a3"
VENDOR="$HOME/Developer/Reel/vendor"
ARCHIVE="$VENDOR/ffmpeg-$VERSION-download/ffmpeg-$VERSION.tar.xz"
SOURCE="$VENDOR/ffmpeg-$VERSION-source"
OUT="$VENDOR/ffmpeg"

echo "$SHA256  $ARCHIVE" | shasum -a 256 -c -
if [[ ! -x "$SOURCE/configure" ]]; then
    mkdir -p "$SOURCE"
    tar -xJf "$ARCHIVE" -C "$SOURCE" --strip-components 1
fi
PATCH="$(cd "$(dirname "$0")" && pwd)/ffmpeg-dovi-p81.patch"
if ! grep -q "to_p81" "$SOURCE/libavcodec/bsf/dovi_rpu.c"; then
    patch -d "$SOURCE" -p1 < "$PATCH"
fi

OPTIONS=(
    --disable-everything --disable-autodetect --disable-programs --disable-doc --disable-debug
    --disable-network --disable-avdevice --disable-avfilter --disable-swscale
    --enable-static --disable-shared --enable-pic --enable-zlib --enable-iconv
    --enable-demuxer=matroska,mov,mpegts,mpegps,avi,asf,srt,ass
    --enable-muxer=mp4,mov
    --enable-decoder=h264,hevc,dca,truehd,mlp,ac3,eac3,aac,aac_latm,flac,alac,opus,vorbis,mp1,mp2,mp3,wmav1,wmav2,wmapro
    --enable-decoder=pcm_bluray,pcm_dvd,pcm_s16le,pcm_s16be,pcm_s24le,pcm_s24be,pcm_s32le,pcm_f32le
    --enable-decoder=pgssub,dvdsub,subrip,srt,ass,ssa,mov_text,webvtt
    --enable-encoder=alac
    --enable-parser=h264,hevc,av1,dca,mlp,ac3,aac,aac_latm,flac,mpegaudio,opus,vorbis,mpegvideo,vc1,mpeg4video
    --enable-bsf=extract_extradata,aac_adtstoasc,h264_mp4toannexb,hevc_mp4toannexb,eac3_core,dovi_rpu,null
)

ONLY=" $* "
build() {
    local sdk="$1" target="$2"
    [[ "$ONLY" == "  " || "$ONLY" == *" $sdk "* ]] || return 0
    local work="$VENDOR/ffmpeg-$VERSION-build/$sdk" root
    root="$(xcrun --sdk "$sdk" --show-sdk-path)"
    local flags="-target $target -isysroot $root"
    mkdir -p "$work"
    cd "$work"
    "$SOURCE/configure" --prefix="$OUT/$sdk" --arch=arm64 --target-os=darwin --enable-cross-compile \
        --cc="$(xcrun --sdk "$sdk" --find clang)" --sysroot="$root" \
        --extra-cflags="$flags" --extra-ldflags="$flags" "${OPTIONS[@]}" > configure.log
    grep -i "^License:" configure.log
    make -j"$(sysctl -n hw.ncpu)" > make.log 2>&1
    make install > install.log 2>&1
    echo "Built $sdk: $(du -sh "$OUT/$sdk/lib" | cut -f1)"
}

build iphoneos arm64-apple-ios17.0
build iphonesimulator arm64-apple-ios17.0-simulator
build appletvos arm64-apple-tvos17.0   # Apple TV plays Dolby Vision profile 7 films through the engine too
build appletvsimulator arm64-apple-tvos17.0-simulator
build macosx arm64-apple-macos14.0      # for testing the engine on this Mac
cp "$SOURCE/COPYING.LGPLv2.1" "$OUT/COPYING.LGPLv2.1"
echo "FFMPEG-RESULT=ok"
