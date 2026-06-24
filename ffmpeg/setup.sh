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

  for ABI in $ANDROID_ABIS; do
    echo "Building libvpx for $ABI..."
    
    # 彻底清理
    make distclean 2>/dev/null || true
    rm -rf .config.mk config.log 2>/dev/null || true
    
    case $ABI in
    armeabi-v7a)
      EXTRA_BUILD_FLAGS="--target=armv7-android-gcc --disable-runtime-cpu-detect"
      TOOLCHAIN_NAME=armv7a-linux-androideabi21
      BUILD_CFLAGS="-O3 -march=armv7-a -mfpu=neon -mfloat-abi=softfp"
      USE_YASM=false
      ;;
    arm64-v8a)
      EXTRA_BUILD_FLAGS="--target=armv8-android-gcc --disable-runtime-cpu-detect"
      TOOLCHAIN_NAME=aarch64-linux-android21
      BUILD_CFLAGS="-O3 -march=armv8-a"
      USE_YASM=false
      ;;
    x86)
      EXTRA_BUILD_FLAGS="--target=x86-android-gcc --disable-sse4_1 --disable-avx --disable-avx2"
      TOOLCHAIN_NAME=i686-linux-android21
      BUILD_CFLAGS="-O3 -march=i686"
      USE_YASM=true
      ;;
    x86_64)
      EXTRA_BUILD_FLAGS="--target=x86_64-android-gcc"
      TOOLCHAIN_NAME=x86_64-linux-android21
      BUILD_CFLAGS="-O3 -march=x86-64"
      USE_YASM=true
      ;;
    *)
      echo "Unsupported architecture: $ABI"
      exit 1
      ;;
    esac

    # 设置编译器路径
    export CC="${TOOLCHAIN_PREFIX}/bin/${TOOLCHAIN_NAME}-clang"
    export CXX="${TOOLCHAIN_PREFIX}/bin/${TOOLCHAIN_NAME}-clang++"
    export AR="${TOOLCHAIN_PREFIX}/bin/llvm-ar"
    export LD="${TOOLCHAIN_PREFIX}/bin/${TOOLCHAIN_NAME}-clang"
    export STRIP="${TOOLCHAIN_PREFIX}/bin/llvm-strip"
    export NM="${TOOLCHAIN_PREFIX}/bin/llvm-nm"
    
    # 为 x86/x86_64 使用 yasm，为 ARM 使用 clang
    if [ "$USE_YASM" = true ]; then
      export AS="${TOOLCHAIN_PREFIX}/bin/yasm"
      export ASFLAGS=""
    else
      export AS="${CC}"
      export ASFLAGS="-c"
    fi
    
    export CFLAGS="${BUILD_CFLAGS}"
    export CXXFLAGS="${BUILD_CFLAGS}"
    export LDFLAGS="-Wl,-z,max-page-size=16384"

    ./configure \
      --prefix="${BUILD_DIR}/external/${ABI}" \
      --libc="${TOOLCHAIN_PREFIX}/sysroot" \
      ${EXTRA_BUILD_FLAGS} \
      --enable-vp8 \
      --enable-vp9 \
      --enable-static \
      --disable-shared \
      --disable-examples \
      --disable-tools \
      --disable-docs \
      --disable-unit-tests \
      --enable-pic \
      --enable-realtime-only \
      --enable-multithread \
      --disable-install-bins \
      --disable-install-docs \
      --enable-install-libs \
      --disable-webm-io \
      --disable-libyuv

    if [ $? -ne 0 ]; then
      echo "libvpx configure failed for $ABI"
      [ -f config.log ] && cat config.log
      exit 1
    fi

    make clean
    
    # 为 x86 构建时显示详细输出以便调试
    if [ "$USE_YASM" = true ]; then
      make -j$JOBS V=1
    else
      make -j$JOBS
    fi
    
    if [ $? -ne 0 ]; then
      echo "libvpx build failed for $ABI"
      exit 1
    fi
    
    make install
    
    # 清理环境变量
    unset CC CXX AR LD STRIP NM AS ASFLAGS CFLAGS CXXFLAGS LDFLAGS
    
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
    
    # 清理之前的配置
    make distclean 2>/dev/null || true
    
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
    
    # 配置 FFmpeg
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

# 主构建流程
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
  echo "Target ABIs: $ANDROID_ABIS"
  echo "Jobs: $JOBS"
  echo "========================================"
  echo ""
  
  # Building libraries in order
  echo "[1/3] Building mbedTLS..."
  buildMbedTLS
  echo ""
  
  echo "[2/3] Building libvpx..."
  buildLibVpx
  echo ""
  
  echo "[3/3] Building FFmpeg..."
  buildFfmpeg
  
  echo ""
  echo "========================================"
  echo "✓ Build completed successfully!"
  echo "========================================"
  echo "Output directory: $OUTPUT_DIR"
  echo "Libraries: $OUTPUT_DIR/lib/{armeabi-v7a,arm64-v8a,x86,x86_64}"
  echo "Headers: $OUTPUT_DIR/include/{armeabi-v7a,arm64-v8a,x86,x86_64}"
  echo ""
  echo "Optimizations applied:"
  echo "  - ARMv7: NEON SIMD + vectorization"
  echo "  - ARMv8: Advanced SIMD"
  echo "  - x86: SSE3/SSSE3"
  echo "  - x86_64: SSE4.2 + POPCNT"
  echo "  - FFmpeg: Runtime CPU detection, hardcoded tables, optimized DSP"
  echo "========================================"
fi
