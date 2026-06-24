#!/bin/bash

# Versions
VPX_VERSION=1.13.0
MBEDTLS_VERSION=3.4.1
FFMPEG_VERSION=6.0

# Directories
BASE_DIR=$(cd "$(dirname "\$0")" && pwd)
BUILD_DIR=$BASE_DIR/build
OUTPUT_DIR=$BASE_DIR/output
SOURCES_DIR=$BASE_DIR/sources
FFMPEG_DIR=$SOURCES_DIR/ffmpeg-$FFMPEG_VERSION
VPX_DIR=$SOURCES_DIR/libvpx-$VPX_VERSION
MBEDTLS_DIR=$SOURCES_DIR/mbedtls-$MBEDTLS_VERSION

# Configuration
ANDROID_ABIS="x86 x86_64 armeabi-v7a arm64-v8a"
ANDROID_PLATFORM=21
ENABLED_DECODERS="vorbis opus flac alac pcm_mulaw pcm_alaw mp3 amrnb amrwb aac ac3 eac3 dca mlp truehd h264 hevc mpeg2video mpegvideo libvpx_vp8 libvpx_vp9"
JOBS=$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || sysctl -n hw.physicalcpu || echo 4)

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
  echo "Downloading FFmpeg source code of version $FFMPEG_VERSION..."
  FFMPEG_FILE=ffmpeg-$FFMPEG_VERSION.tar.gz
  curl -L "https://ffmpeg.org/releases/ffmpeg-${FFMPEG_VERSION}.tar.gz" -o $FFMPEG_FILE
  [ -e $FFMPEG_FILE ] || { echo "$FFMPEG_FILE does not exist. Exiting..."; exit 1; }
  tar -zxf $FFMPEG_FILE
  rm $FFMPEG_FILE
  popd
}

function buildLibVpx() {
  pushd $VPX_DIR

  VPX_AS=${TOOLCHAIN_PREFIX}/bin/llvm-as
  
  for ABI in $ANDROID_ABIS; do
    echo "Building libvpx for $ABI..."
    
    case $ABI in
    armeabi-v7a)
      EXTRA_BUILD_FLAGS="--force-target=armv7-android-gcc"
      TOOLCHAIN=armv7a-linux-androideabi21-
      # 添加 cpu-features 支持
      EXTRA_CFLAGS="-I${ANDROID_NDK_HOME}/sources/android/cpufeatures"
      ;;
    arm64-v8a)
      EXTRA_BUILD_FLAGS="--force-target=armv8-android-gcc"
      TOOLCHAIN=aarch64-linux-android21-
      EXTRA_CFLAGS="-I${ANDROID_NDK_HOME}/sources/android/cpufeatures"
      ;;
    x86)
      EXTRA_BUILD_FLAGS="--force-target=x86-android-gcc --disable-sse4_1 --disable-avx --disable-avx2 --enable-pic"
      VPX_AS=${TOOLCHAIN_PREFIX}/bin/yasm
      TOOLCHAIN=i686-linux-android21-
      EXTRA_CFLAGS=""
      ;;
    x86_64)
      EXTRA_BUILD_FLAGS="--force-target=x86_64-android-gcc --enable-pic"
      VPX_AS=${TOOLCHAIN_PREFIX}/bin/yasm
      TOOLCHAIN=x86_64-linux-android21-
      EXTRA_CFLAGS=""
      ;;
    *)
      echo "Unsupported architecture: $ABI"
      exit 1
      ;;
    esac

    CC=${TOOLCHAIN_PREFIX}/bin/${TOOLCHAIN}clang \
      CXX=${CC}++ \
      LD=${CC} \
      AR=${TOOLCHAIN_PREFIX}/bin/llvm-ar \
      AS=${VPX_AS} \
      STRIP=${TOOLCHAIN_PREFIX}/bin/llvm-strip \
      NM=${TOOLCHAIN_PREFIX}/bin/llvm-nm \
      CFLAGS="$EXTRA_CFLAGS" \
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
      --enable-runtime-cpu-detect \
      ${EXTRA_BUILD_FLAGS}

    if [ $? -ne 0 ]; then
      echo "libvpx configure failed for $ABI"
      exit 1
    fi

    make clean
    make -j$JOBS
    
    if [ $? -ne 0 ]; then
      echo "libvpx build failed for $ABI"
      exit 1
    fi
    
    make install
    echo "✓ libvpx built successfully for $ABI"
  done
  
  popd
}

function buildMbedTLS() {
    pushd $MBEDTLS_DIR

    for ABI in $ANDROID_ABIS; do
      echo "Building mbedTLS for $ABI..."

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
        echo "mbedTLS configure failed for $ABI"
        exit 1
      fi

      make -j$JOBS
      
      if [ $? -ne 0 ]; then
        echo "mbedTLS build failed for $ABI"
        exit 1
      fi
      
      make install
      echo "✓ mbedTLS built successfully for $ABI"
    done
    
    popd
}

function buildFfmpeg() {
  pushd $FFMPEG_DIR

  COMMON_OPTIONS=""

  # 添加音频解码器
  for decoder in $ENABLED_DECODERS; do
    COMMON_OPTIONS="${COMMON_OPTIONS} --enable-decoder=${decoder}"
  done

  for ABI in $ANDROID_ABIS; do
    echo "Building FFmpeg for $ABI..."
    
    EXTRA_BUILD_CONFIGURATION_FLAGS=""
    EXTRA_CFLAGS=""

    # 针对不同架构优化 CFLAGS
    case $ABI in
    armeabi-v7a)
      TOOLCHAIN=armv7a-linux-androideabi21-
      CPU=armv7-a
      ARCH=arm
      # ARMv7 + NEON 优化
      EXTRA_CFLAGS="-O3 -fPIC -march=armv7-a -mfpu=neon -mfloat-abi=softfp -ftree-vectorize -fomit-frame-pointer"
      ;;
    arm64-v8a)
      TOOLCHAIN=aarch64-linux-android21-
      CPU=armv8-a
      ARCH=aarch64
      # ARMv8 优化
      EXTRA_CFLAGS="-O3 -fPIC -march=armv8-a -ftree-vectorize -fomit-frame-pointer"
      ;;
    x86)
      TOOLCHAIN=i686-linux-android21-
      CPU=i686
      ARCH=i686
      # x86 优化
      EXTRA_CFLAGS="-O3 -fPIC -march=i686 -msse3 -mssse3 -mfpmath=sse -ftree-vectorize"
      EXTRA_BUILD_CONFIGURATION_FLAGS="--disable-asm"
      ;;
    x86_64)
      TOOLCHAIN=x86_64-linux-android21-
      CPU=x86_64
      ARCH=x86_64
      # x86_64 优化
      EXTRA_CFLAGS="-O3 -fPIC -march=x86-64 -msse4.2 -mpopcnt -mfpmath=sse -ftree-vectorize -fomit-frame-pointer"
      ;;
    *)
      echo "Unsupported architecture: $ABI"
      exit 1
      ;;
    esac

    # 依赖库路径
    DEP_CFLAGS="-I$BUILD_DIR/external/$ABI/include"
    DEP_LD_FLAGS="-L$BUILD_DIR/external/$ABI/lib"

    echo "Configuring FFmpeg for $ABI with audio performance optimizations..."
    
    # 配置 FFmpeg（移除 --disable-aacps，FFmpeg 6.0 不支持此选项）
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
      --extra-ldflags="$DEP_LD_FLAGS -Wl,-z,max-page-size=16384" \
      --pkg-config="$(which pkg-config)" \
      --target-os=android \
      --enable-shared \
      --disable-static \
      --disable-doc \
      --disable-programs \
      --disable-everything \
      --disable-vulkan \
      --disable-avdevice \
      --disable-postproc \
      --disable-avfilter \
      --disable-symver \
      --enable-parsers \
      --enable-demuxers \
      --enable-swresample \
      --enable-avformat \
      --enable-libvpx \
      --enable-pthreads \
      --enable-protocol=file,http,https,mmsh,mmst,pipe,rtmp,rtmps,rtmpt,rtmpts,rtp,tls \
      --enable-version3 \
      --enable-mbedtls \
      --enable-optimizations \
      --enable-runtime-cpudetect \
      --enable-fft \
      --enable-mdct \
      --enable-rdft \
      --enable-dct \
      --enable-hardcoded-tables \
      --enable-pic \
      --disable-debug \
      --disable-stripping \
      --extra-ldexeflags=-pie \
      ${EXTRA_BUILD_CONFIGURATION_FLAGS} \
      ${COMMON_OPTIONS}

    if [ $? -ne 0 ]; then
      echo "FFmpeg configure failed for $ABI"
      cat ffbuild/config.log
      exit 1
    fi

    echo "Building FFmpeg for $ABI..."
    make clean
    make -j$JOBS
    
    if [ $? -ne 0 ]; then
      echo "FFmpeg build failed for $ABI"
      exit 1
    fi
    
    make install

    # 复制库文件
    OUTPUT_LIB=${OUTPUT_DIR}/lib/${ABI}
    mkdir -p "${OUTPUT_LIB}"
    
    # 手动 strip 库文件以减小体积
    for so in "${BUILD_DIR}"/"${ABI}"/lib/*.so; do
      if [ -f "$so" ]; then
        ${TOOLCHAIN_PREFIX}/bin/llvm-strip --strip-unneeded "$so"
        cp "$so" "${OUTPUT_LIB}/"
      fi
    done

    # 复制头文件
    OUTPUT_HEADERS=${OUTPUT_DIR}/include/${ABI}
    mkdir -p "${OUTPUT_HEADERS}"
    cp -r "${BUILD_DIR}"/"${ABI}"/include/* "${OUTPUT_HEADERS}"
    
    echo "✓ FFmpeg built successfully for $ABI with audio optimizations"
  done
  
  popd
}

if [[ ! -d "$OUTPUT_DIR" && ! -d "$BUILD_DIR" ]]; then
  # Download MbedTLS source code if it doesn't exist
  if [[ ! -d "$MBEDTLS_DIR" ]]; then
    downloadMbedTLS
  fi

  # Download Vpx source code if it doesn't exist
  if [[ ! -d "$VPX_DIR" ]]; then
    downloadLibVpx
  fi

  # Download Ffmpeg source code if it doesn't exist
  if [[ ! -d "$FFMPEG_DIR" ]]; then
    downloadFfmpeg
  fi

  echo "========================================"
  echo "Building dependencies with optimizations"
  echo "========================================"
  
  # Building library
  buildMbedTLS
  buildLibVpx
  buildFfmpeg
  
  echo ""
  echo "========================================"
  echo "✓ Build completed successfully!"
  echo "========================================"
  echo "Output directory: $OUTPUT_DIR"
  echo "Libraries: $OUTPUT_DIR/lib/"
  echo "Headers: $OUTPUT_DIR/include/"
fi
