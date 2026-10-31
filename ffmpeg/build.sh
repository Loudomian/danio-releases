#!/bin/sh
# Builds danio's FFmpeg: a small, fully static ffmpeg that only does what
# danio asks of it (danio's 01-ARCHITECTURE §10). danio encodes each
# rendered shot into a fragment with libx264 (or ProRes 4444), from PNG,
# JPEG or TIFF frames, and joins the fragments with the concat demuxer
# without encoding again; nothing else is built in. No hardware encoders:
# fragments must all be libx264 to join, and a static build can't load a
# driver's encoder anyway.
#
# This script is the whole recipe, published with every build as the GPL
# asks: the sources it builds are fetched from their projects and checked
# against the hashes below.
#
#   build.sh <target> <out>    build for one target into <out>/
#   build.sh source <out>      the sources and this script, one archive
#   build.sh tag               the release tag of this recipe
#
# Targets: linux-amd64, linux-arm64 (on Alpine, natively: musl links fully
# static), windows-amd64 (mingw-w64), windows-arm64 (llvm-mingw).
#
# To move to a new FFmpeg: change FFMPEG_VERSION and FFMPEG_SHA256 (check
# the tarball's .asc against the FFmpeg release key first), set REVISION
# back to 1, and run the workflow. A fix to this recipe alone: REVISION + 1.
set -eu

FFMPEG_VERSION=9.0.2
FFMPEG_SHA256=8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e
X264_COMMIT=b35605ace3ddf7c1a5d67a2eb553f034aef41d55 # the stable branch
ZLIB_VERSION=1.3.2
ZLIB_SHA256=bb329a0a2cd0274d05519d61c667c062e06990d72e125ee2dfa8de64f0119d16
REVISION=1

VERSION="$FFMPEG_VERSION-danio.$REVISION"
NAME="ffmpeg-$VERSION"
HERE=$(cd "$(dirname "$0")" && pwd)

die() { echo "build.sh: $*" >&2; exit 1; }

sha256() {
	if command -v sha256sum >/dev/null; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

# fetch <url> <file> <sha256>: downloads once, checks the hash.
fetch() {
	if [ ! -f "$2" ]; then
		curl -fsSL --retry 3 -o "$2.part" "$1"
		mv "$2.part" "$2"
	fi
	got=$(sha256 "$2")
	[ "$got" = "$3" ] || die "$2: sha256 $got, want $3"
}

sources() {
	mkdir -p "$SRC"
	cd "$SRC"
	fetch "https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VERSION.tar.xz" "ffmpeg-$FFMPEG_VERSION.tar.xz" "$FFMPEG_SHA256"
	fetch "https://zlib.net/fossils/zlib-$ZLIB_VERSION.tar.gz" "zlib-$ZLIB_VERSION.tar.gz" "$ZLIB_SHA256"
	if [ ! -f "x264-$X264_COMMIT.tar.gz" ]; then
		rm -rf x264-git
		git init -q x264-git
		git -C x264-git fetch -q --depth 1 https://code.videolan.org/videolan/x264.git "$X264_COMMIT"
		[ "$(git -C x264-git rev-parse FETCH_HEAD)" = "$X264_COMMIT" ] || die "x264: not $X264_COMMIT"
		git -C x264-git archive --format=tar.gz --prefix="x264-$X264_COMMIT/" -o "$SRC/x264-$X264_COMMIT.tar.gz" FETCH_HEAD
		rm -rf x264-git
	fi
	cd - >/dev/null
}

[ $# -ge 1 ] || die "usage: build.sh <target>|source <out> | tag"
TARGET=$1
if [ "$TARGET" = tag ]; then
	echo "ffmpeg-$VERSION"
	exit 0
fi
[ $# -eq 2 ] || die "usage: build.sh <target>|source <out>"
mkdir -p "$2"
OUT=$(cd "$2" && pwd)
WORK=${WORK:-$OUT/work}
SRC=$WORK/src
mkdir -p "$WORK"

if [ "$TARGET" = source ]; then
	sources
	rm -rf "$WORK/source" && mkdir -p "$WORK/source/$NAME-source"
	cp "$SRC/ffmpeg-$FFMPEG_VERSION.tar.xz" "$SRC/zlib-$ZLIB_VERSION.tar.gz" "$SRC/x264-$X264_COMMIT.tar.gz" \
		"$HERE/build.sh" "$HERE/README.txt" "$WORK/source/$NAME-source/"
	tar -C "$WORK/source" -czf "$OUT/$NAME-source.tar.gz" "$NAME-source"
	echo "$OUT/$NAME-source.tar.gz"
	exit 0
fi

EXE=ffmpeg
case $TARGET in
linux-amd64 | linux-arm64)
	[ -f /etc/alpine-release ] || die "$TARGET builds on Alpine (musl), for a fully static program"
	want=x86_64
	[ "$TARGET" = linux-arm64 ] && want=aarch64
	[ "$(uname -m)" = "$want" ] || die "$TARGET builds natively, on $want"
	CROSS=""
	# Alpine's gcc links static-pie: x264's assembly must be PIC too, or
	# on aarch64 the link fails (read-only segment has dynamic relocations)
	X264_HOST="--enable-pic"
	FF_CROSS=""
	;;
windows-amd64)
	CROSS=x86_64-w64-mingw32-
	X264_HOST="--host=x86_64-w64-mingw32"
	FF_CROSS="--enable-cross-compile --target-os=mingw32 --arch=x86_64"
	EXE=ffmpeg.exe
	;;
windows-arm64)
	CROSS=aarch64-w64-mingw32-
	X264_HOST="--host=aarch64-w64-mingw32"
	FF_CROSS="--enable-cross-compile --target-os=mingw32 --arch=aarch64"
	EXE=ffmpeg.exe
	;;
*) die "unknown target $TARGET" ;;
esac
command -v "${CROSS}gcc" >/dev/null || command -v "${CROSS}clang" >/dev/null || die "no ${CROSS}gcc"
CC=${CROSS}gcc
command -v "$CC" >/dev/null || CC=${CROSS}clang
JOBS=$(nproc 2>/dev/null || echo 4)

sources
B=$WORK/$TARGET
P=$B/prefix
rm -rf "$B" && mkdir -p "$P"
cd "$B"
tar xf "$SRC/ffmpeg-$FFMPEG_VERSION.tar.xz"
tar xzf "$SRC/zlib-$ZLIB_VERSION.tar.gz"
tar xzf "$SRC/x264-$X264_COMMIT.tar.gz"

# zlib, for PNG
(cd "zlib-$ZLIB_VERSION" &&
	CC=$CC AR=${CROSS}ar RANLIB=${CROSS}ranlib CHOST=${CROSS%-} ./configure --prefix="$P" --static >"$B/zlib.log" 2>&1 &&
	make -j"$JOBS" >>"$B/zlib.log" 2>&1 && make install >>"$B/zlib.log" 2>&1) || { tail -40 "$B/zlib.log" >&2; die "zlib failed (log above)"; }

# x264: the library only
(cd "x264-$X264_COMMIT" &&
	CC=$CC ./configure --prefix="$P" $X264_HOST ${CROSS:+--cross-prefix=$CROSS} \
		--enable-static --disable-cli --disable-opencl --disable-lavf --disable-swscale \
		--disable-ffms --disable-gpac --disable-lsmash --enable-strip >"$B/x264.log" 2>&1 &&
	make -j"$JOBS" >>"$B/x264.log" 2>&1 && make install >>"$B/x264.log" 2>&1) || { tail -40 "$B/x264.log" >&2; die "x264 failed (log above)"; }

static="-static"
cd "ffmpeg-$FFMPEG_VERSION"
PKG_CONFIG_PATH="$P/lib/pkgconfig" ./configure \
	--prefix="$P" $FF_CROSS ${CROSS:+--cross-prefix=$CROSS} --cc="$CC" \
	--pkg-config=pkg-config --pkg-config-flags=--static \
	--extra-cflags="-I$P/include" --extra-ldflags="-L$P/lib $static" \
	--extra-version="danio.$REVISION" \
	--enable-gpl --enable-static --disable-shared \
	--disable-autodetect --disable-everything --disable-network --disable-doc \
	--disable-ffplay --disable-ffprobe --disable-debug --enable-stripping \
	--enable-zlib --enable-libx264 \
	--enable-protocol=file \
	--enable-demuxer=image2,concat,mov \
	--enable-decoder=png,mjpeg,tiff,h264,prores \
	--enable-parser=png,mjpeg,h264 \
	--enable-encoder=libx264,prores_ks \
	--enable-muxer=mp4,mov \
	--enable-filter=pad,scale,format,null \
	--enable-bsf=h264_mp4toannexb \
	>"$B/configure.log" 2>&1 || { tail -40 "$B/configure.log" >&2; tail -60 ffbuild/config.log >&2; die "FFmpeg configure failed (log above)"; }
make -j"$JOBS" >"$B/make.log" 2>&1 || { tail -40 "$B/make.log" >&2; die "FFmpeg build failed (log above)"; }

PKG=$B/$NAME-$TARGET
mkdir -p "$PKG"
cp "$EXE" "$PKG/"
cp COPYING.GPLv2 "$PKG/"
{
	cat "$HERE/README.txt"
	echo
	echo "Version: $VERSION ($TARGET)"
	echo "Sources: FFmpeg $FFMPEG_VERSION, x264 $X264_COMMIT, zlib $ZLIB_VERSION"
	echo "Configured with (<prefix>: where this build put x264 and zlib):"
	sed -n 's/^#define FFMPEG_CONFIGURATION "\(.*\)"$/\1/p' config.h | sed -e "s|$P|<prefix>|g" -e 's/  */ /g'
} >"$PKG/README.txt"
tar -C "$B" -czf "$OUT/$NAME-$TARGET.tar.gz" "$NAME-$TARGET"
echo "$OUT/$NAME-$TARGET.tar.gz"
