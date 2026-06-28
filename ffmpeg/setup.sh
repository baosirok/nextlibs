#!/bin/bash
set -e
set -u

# Versions
VPX_VERSION=1.13.0
MBEDTLS_VERSION=3.4.1
FFMPEG_VERSION=8.1

# Directories
BASE_DIR=$(cd "$(dirname "$0")" && pwd)
BUILD_DIR=$BASE_DIR/build
OUTPUT_DIR=$BASE_DIR/output
SOURCES_DIR=$BASE_DIR/sources
FFMPEG_DIR=$SOURCES_DIR/ffmpeg-$FFMPEG_VERSION
VPX_DIR=$SOURCES_DIR/libvpx-$VPX_VERSION
MBEDTLS_DIR=$SOURCES_DIR/mbedtls-$MBEDTLS_VERSION

# Configuration
ANDROID_ABIS="armeabi-v7a arm64-v8a"
ANDROID_PLATFORM=21
JOBS=$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || sysctl -n hw.physicalcpu 2>/dev/null || echo 4)

# Set up host platform variables
HOST_PLATFORM="linux-x86_64"
case "$OSTYPE" in
darwin*) HOST_PLATFORM="darwin-x86_64" ;;
linux*) HOST_PLATFORM="linux-x86_64" ;;
msys)
  case "$(uname -m)" in
  x86_64) HOST_PLATFORM="windows-x86_64" ;;
  i686) HOST_PLATFORM="windows" ;;
  esac
  ;;
esac

# Build tools
TOOLCHAIN_PREFIX="${ANDROID_NDK_HOME}/toolchains/llvm/prebuilt/${HOST_PLATFORM}"
CMAKE_EXECUTABLE="${ANDROID_SDK_HOME}/cmake/${ANDROID_CMAKE_VERSION}/bin/cmake"

# Verify NDK toolchain exists
if [[ ! -d "$TOOLCHAIN_PREFIX" ]]; then
  echo "ERROR: NDK toolchain not found at $TOOLCHAIN_PREFIX"
  echo "ANDROID_NDK_HOME: $ANDROID_NDK_HOME"
  echo "HOST_PLATFORM: $HOST_PLATFORM"
  exit 1
fi

# Check if sdkmanager is in PATH
if command -v sdkmanager &> /dev/null; then
  echo "Using sdkmanager from PATH"
  echo y | sdkmanager --sdk_root="${ANDROID_SDK_HOME}" "cmake;${ANDROID_CMAKE_VERSION}"
else
  SDKMANAGER_EXECUTABLE="${ANDROID_SDK_HOME}/cmdline-tools/latest/bin/sdkmanager"
  if [[ -x "$SDKMANAGER_EXECUTABLE" ]]; then
    echo "Using sdkmanager from Android SDK"
    echo y | "$SDKMANAGER_EXECUTABLE" --sdk_root="${ANDROID_SDK_HOME}" "cmake;${ANDROID_CMAKE_VERSION}"
  else
    echo "Error: sdkmanager not found in PATH or Android SDK"
    exit 1
  fi
fi

mkdir -p $SOURCES_DIR

function downloadLibVpx() {
  pushd $SOURCES_DIR
  echo "Downloading Vpx source code of version $VPX_VERSION..."
  VPX_FILE=libvpx-$VPX_VERSION.tar.gz
  curl -L "https://github.com/webmproject/libvpx/archive/refs/tags/v${VPX_VERSION}.tar.gz" -o $VPX_FILE
  [ -e $VPX_FILE ] || { echo "$VPX_FILE does not exist. Exiting..."; exit 1; }
  tar -zxf $VPX_FILE
  rm $VPX_FILE
  popd
}

function downloadMbedTLS() {
  pushd $SOURCES_DIR
  echo "Downloading mbedtls source code of version $MBEDTLS_VERSION..."
  MBEDTLS_FILE=mbedtls-$MBEDTLS_VERSION.tar.gz
  curl -L "https://github.com/Mbed-TLS/mbedtls/archive/refs/tags/v${MBEDTLS_VERSION}.tar.gz" -o $MBEDTLS_FILE
  [ -e $MBEDTLS_FILE ] || { echo "$MBEDTLS_FILE does not exist. Exiting..."; exit 1; }
  tar -zxf $MBEDTLS_FILE
  rm $MBEDTLS_FILE
  popd
}

function downloadFfmpeg() {
  pushd $SOURCES_DIR
  
  if [[ -d "$FFMPEG_DIR" ]]; then
    echo "Removing existing FFmpeg directory..."
    rm -rf "$FFMPEG_DIR"
  fi
  
  echo "========================================="
  echo "Cloning custom FFmpeg from baosirok/FFmpeg"
  echo "Branch: release/8.1"
  echo "========================================="
  
  git clone -b release/8.1 --depth 1 https://github.com/baosirok/FFmpeg.git "$FFMPEG_DIR"
  
  if [ $? -ne 0 ]; then
    echo "ERROR: Failed to clone FFmpeg repository"
    exit 1
  fi
  
  echo "✓ Custom FFmpeg cloned successfully"
  echo ""
  popd
}

function buildLibVpx() {
  pushd $VPX_DIR

  for ABI in $ANDROID_ABIS; do
    echo "========================================="
    echo "Building libvpx for $ABI..."
    echo "========================================="
    
    make distclean 2>/dev/null || true
    rm -f .config.mk config.log 2>/dev/null || true
    
    case $ABI in
    armeabi-v7a)
      EXTRA_BUILD_FLAGS="--force-target=armv7-android-gcc"
      TOOLCHAIN=armv7a-linux-androideabi21-
      # 对于 ARMv7，使用 llvm-ar 作为汇编器
      AS_EXEC="${TOOLCHAIN_PREFIX}/bin/llvm-ar"
      ;;
    arm64-v8a)
      EXTRA_BUILD_FLAGS="--force-target=armv8-android-gcc"
      TOOLCHAIN=aarch64-linux-android21-
      AS_EXEC="${TOOLCHAIN_PREFIX}/bin/llvm-ar"
      ;;
    x86)
      EXTRA_BUILD_FLAGS="--force-target=x86-android-gcc --disable-sse2 --disable-sse3 --disable-ssse3 --disable-sse4_1 --disable-avx --disable-avx2 --enable-pic"
      AS_EXEC="${TOOLCHAIN_PREFIX}/bin/yasm"
      TOOLCHAIN=i686-linux-android21-
      ;;
    x86_64)
      EXTRA_BUILD_FLAGS="--force-target=x86_64-android-gcc --disable-sse2 --disable-sse3 --disable-ssse3 --disable-sse4_1 --disable-avx --disable-avx2 --enable-pic"
      AS_EXEC="${TOOLCHAIN_PREFIX}/bin/yasm"
      TOOLCHAIN=x86_64-linux-android21-
      ;;
    *)
      echo "Unsupported architecture: $ABI"
      exit 1
      ;;
    esac

    COMPILER="${TOOLCHAIN_PREFIX}/bin/${TOOLCHAIN}clang"
    if [[ ! -x "$COMPILER" ]]; then
      echo "ERROR: Compiler not found: $COMPILER"
      exit 1
    fi
    echo "Using compiler: $COMPILER"
    echo "Using assembler: $AS_EXEC"

    CC=${COMPILER} \
      CXX=${COMPILER}++ \
      LD=${COMPILER} \
      AR=${TOOLCHAIN_PREFIX}/bin/llvm-ar \
      AS=${AS_EXEC} \
      STRIP=${TOOLCHAIN_PREFIX}/bin/llvm-strip \
      NM=${TOOLCHAIN_PREFIX}/bin/llvm-nm \
      LDFLAGS="-Wl,-z,max-page-size=16384" \
      ./configure \
      --prefix=$BUILD_DIR/external/$ABI \
      --libc="${TOOLCHAIN_PREFIX}/sysroot" \
      --enable-vp8 \
      --enable-vp9 \
      --enable-static \
      --disable-shared \
      --disable-examples \
      --disable-docs \
      --enable-realtime-only \
      --enable-install-libs \
      --enable-multithread \
      --disable-webm-io \
      --disable-libyuv \
      --enable-better-hw-compatibility \
      --disable-runtime-cpu-detect \
      ${EXTRA_BUILD_FLAGS}

    if [ $? -ne 0 ]; then
      echo "ERROR: libvpx configure failed for $ABI"
      [ -f config.log ] && cat config.log
      exit 1
    fi

    make clean
    make -j$JOBS
    
    if [ $? -ne 0 ]; then
      echo "ERROR: libvpx build failed for $ABI"
      exit 1
    fi
    
    make install
    echo "✓ libvpx built successfully for $ABI"
    echo ""
  done
  popd
}

function buildMbedTLS() {
    pushd $MBEDTLS_DIR

    for ABI in $ANDROID_ABIS; do
      echo "========================================="
      echo "Building mbedTLS for $ABI..."
      echo "========================================="

      CMAKE_BUILD_DIR=$MBEDTLS_DIR/mbedtls_build_${ABI}
      rm -rf ${CMAKE_BUILD_DIR}
      mkdir -p ${CMAKE_BUILD_DIR}
      cd ${CMAKE_BUILD_DIR}

      ${CMAKE_EXECUTABLE} .. \
       -DANDROID_PLATFORM=${ANDROID_PLATFORM} \
       -DANDROID_ABI=$ABI \
       -DCMAKE_TOOLCHAIN_FILE=${ANDROID_NDK_HOME}/build/cmake/android.toolchain.cmake \
       -DCMAKE_INSTALL_PREFIX=$BUILD_DIR/external/$ABI \
       -DCMAKE_SHARED_LINKER_FLAGS="-Wl,-z,max-page-size=16384" \
       -DENABLE_TESTING=0

      if [ $? -ne 0 ]; then
        echo "ERROR: mbedTLS configure failed for $ABI"
        exit 1
      fi

      make -j$JOBS
      
      if [ $? -ne 0 ]; then
        echo "ERROR: mbedTLS build failed for $ABI"
        exit 1
      fi
      
      make install
      echo "✓ mbedTLS built successfully for $ABI"
      echo ""
    done
    
    popd
}

function buildFfmpeg() {
  for ABI in $ANDROID_ABIS; do
    echo "========================================="
    echo "Building custom FFmpeg for $ABI..."
    echo "========================================="

    FFMPEG_BUILD_DIR=$BUILD_DIR/ffmpeg-build-$ABI
    rm -rf $FFMPEG_BUILD_DIR
    mkdir -p $FFMPEG_BUILD_DIR
    
    echo "Copying custom FFmpeg source to build directory..."
    cp -r $FFMPEG_DIR/* $FFMPEG_BUILD_DIR/
    
    pushd $FFMPEG_BUILD_DIR

    # 基础的通用优化标志（保留所有解码器，不裁剪）
    EXTRA_CFLAGS="-O3 -fPIC -fomit-frame-pointer -ffast-math -fstrict-aliasing -funroll-loops -flto -fno-math-errno"
    EXTRA_LDFLAGS="-flto -Wl,-z,max-page-size=16384"
    EXTRA_BUILD_CONFIGURATION_FLAGS=""

    case $ABI in
    armeabi-v7a)
      TOOLCHAIN=armv7a-linux-androideabi21-
      CPU=armv7-a
      ARCH=arm
      EXTRA_CFLAGS="$EXTRA_CFLAGS -march=armv7-a -mfpu=neon -mfloat-abi=softfp -mtune=cortex-a53"
      EXTRA_BUILD_CONFIGURATION_FLAGS="--enable-neon --enable-asm"
      ;;
    arm64-v8a)
      TOOLCHAIN=aarch64-linux-android21-
      CPU=armv8-a
      ARCH=aarch64
      EXTRA_CFLAGS="$EXTRA_CFLAGS -march=armv8.2-a+fp16+rcpc+dotprod -mtune=cortex-a76 -mcpu=cortex-a76"
      EXTRA_BUILD_CONFIGURATION_FLAGS="--enable-neon --enable-asm"
      ;;
    x86)
      TOOLCHAIN=i686-linux-android21-
      CPU=i686
      ARCH=i686
      EXTRA_CFLAGS="$EXTRA_CFLAGS -march=i686 -msse3 -mssse3 -mfpmath=sse"
      EXTRA_BUILD_CONFIGURATION_FLAGS="--disable-asm"
      ;;
    x86_64)
      TOOLCHAIN=x86_64-linux-android21-
      CPU=x86-64
      ARCH=x86_64
      EXTRA_CFLAGS="$EXTRA_CFLAGS -march=x86-64 -mtune=generic"
      EXTRA_BUILD_CONFIGURATION_FLAGS=""
      ;;
    *)
      echo "Unsupported architecture: $ABI"
      exit 1
      ;;
    esac

    DEP_CFLAGS="-I$BUILD_DIR/external/$ABI/include"
    DEP_LD_FLAGS="-L$BUILD_DIR/external/$ABI/lib"

    COMPILER="${TOOLCHAIN_PREFIX}/bin/${TOOLCHAIN}clang"
    if [[ ! -x "$COMPILER" ]]; then
      echo "ERROR: Compiler not found: $COMPILER"
      exit 1
    fi
    echo "Using compiler: $COMPILER"

    ./configure \
      --prefix=$BUILD_DIR/$ABI \
      --enable-cross-compile \
      --arch=$ARCH \
      --cpu=$CPU \
      --cross-prefix="${TOOLCHAIN_PREFIX}/bin/$TOOLCHAIN" \
      --nm="${TOOLCHAIN_PREFIX}/bin/llvm-nm" \
      --ar="${TOOLCHAIN_PREFIX}/bin/llvm-ar" \
      --ranlib="${TOOLCHAIN_PREFIX}/bin/llvm-ranlib" \
      --strip="${TOOLCHAIN_PREFIX}/bin/llvm-strip" \
      --extra-cflags="$EXTRA_CFLAGS $DEP_CFLAGS" \
      --extra-ldflags="$DEP_LD_FLAGS $EXTRA_LDFLAGS" \
      --pkg-config="$(which pkg-config)" \
      --target-os=android \
      --enable-shared \
      --disable-static \
      \
      --disable-doc \
      --disable-programs \
      --disable-ffmpeg \
      --disable-ffplay \
      --disable-ffprobe \
      \
      --enable-avcodec \
      --enable-avformat \
      --enable-avutil \
      --enable-swresample \
      --enable-swscale \
      --enable-avfilter \
      \
      --enable-libvpx \
      --enable-mbedtls \
      \
      --enable-protocol=file,http,https,mmsh,mmst,pipe,rtmp,rtmps,rtmpt,rtmpts,rtp,tcp,udp,tls \
      \
      --enable-version3 \
      --enable-pic \
      --enable-optimizations \
      --enable-asm \
      --enable-inline-asm \
      --enable-runtime-cpudetect \
      --disable-debug \
      --disable-symver \
      --extra-ldexeflags=-pie \
      ${EXTRA_BUILD_CONFIGURATION_FLAGS}

    if [ $? -ne 0 ]; then
      echo "ERROR: FFmpeg configure failed for $ABI"
      echo "========================================="
      echo "Dumping config.log..."
      echo "========================================="
      cat ffbuild/config.log || echo "No config.log found"
      exit 1
    fi

    echo "Building custom FFmpeg for $ARCH..."
    make -j$JOBS
    
    if [ $? -ne 0 ]; then
      echo "ERROR: FFmpeg build failed for $ABI"
      exit 1
    fi
    
    make install

    OUTPUT_LIB=${OUTPUT_DIR}/lib/${ABI}
    mkdir -p "${OUTPUT_LIB}"
    
    for so in "${BUILD_DIR}"/"${ABI}"/lib/*.so; do
      if [ -f "$so" ]; then
        ${TOOLCHAIN_PREFIX}/bin/llvm-strip --strip-unneeded "$so"
        cp "$so" "${OUTPUT_LIB}/"
      fi
    done

    OUTPUT_HEADERS=${OUTPUT_DIR}/include/${ABI}
    mkdir -p "${OUTPUT_HEADERS}"
    cp -r "${BUILD_DIR}"/"${ABI}"/include/* "${OUTPUT_HEADERS}"

    popd
    
    echo "✓ Custom FFmpeg built successfully for $ABI"
    echo ""
  done
}

# ========================================
# 主构建流程
# ========================================

echo "========================================="
echo "NextLibs Build Script (Optimized)"
echo "Using CUSTOM FFmpeg from baosirok/FFmpeg"
echo "========================================="
echo ""
echo "Target ABIs: $ANDROID_ABIS"
echo "Jobs: $JOBS"
echo "NDK: $ANDROID_NDK_HOME"
echo "Toolchain: $TOOLCHAIN_PREFIX"
echo "FFmpeg Version: $FFMPEG_VERSION (custom)"
echo ""
echo "Optimizations enabled:"
echo "  - Runtime CPU detection (ARMv8.2+ dotprod/fp16)"
echo "  - LTO (Link Time Optimization)"
echo "  - Loop unrolling"
echo "  - NEON/ASM for ARM"
echo "========================================="
echo ""

# Download mbedtls source code if it doesn't exist
if [[ ! -d "$MBEDTLS_DIR" ]]; then
  downloadMbedTLS
fi

# Download Vpx source code if it doesn't exist
if [[ ! -d "$VPX_DIR" ]]; then
  downloadLibVpx
fi

# Download/Clone custom FFmpeg if it doesn't exist
if [[ ! -d "$FFMPEG_DIR" ]]; then
  downloadFfmpeg
else
  echo "Custom FFmpeg directory already exists at $FFMPEG_DIR"
  echo "To use the latest version, delete the directory and re-run"
  echo ""
fi

# Building library
echo "[1/3] Building mbedTLS..."
buildMbedTLS

echo "[2/3] Building libvpx..."
buildLibVpx

echo "[3/3] Building custom FFmpeg..."
buildFfmpeg

echo ""
echo "========================================="
echo "✓ Build completed successfully!"
echo "========================================="
echo "FFmpeg: Custom build from baosirok/FFmpeg (release/8.1)"
echo "Output directory: $OUTPUT_DIR"
echo "Libraries: $OUTPUT_DIR/lib/{armeabi-v7a,arm64-v8a,x86,x86_64}"
echo "Headers: $OUTPUT_DIR/include/{armeabi-v7a,arm64-v8a,x86,x86_64}"
echo ""
echo "Optimizations applied:"
echo "  - Runtime CPU detection enabled"
echo "  - ARMv8.2+ dotprod/fp16 for arm64-v8a"
echo "  - LTO and loop unrolling"
echo "  - NEON/ASM enabled for ARM"
echo "  - All decoders preserved"
echo "========================================="
