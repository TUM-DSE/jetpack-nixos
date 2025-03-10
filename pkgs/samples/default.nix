{ stdenv
, lib
, fetchurl
, dpkg
, pkg-config
, autoAddDriverRunpath
, cmake
, opencv
, libX11
, libdrm
, libglvnd
, python3
, coreutils
, gnused
, libGL
, libXau
, wayland
, libxkbcommon
, libffi
, vulkan-headers
, vulkan-loader
, writeShellApplication
, l4t-cuda
, l4t-multimedia
, l4t-camera
, cudaPackages
, cudaVersion
, debs
}:
let
  cudaVersionDashes = lib.replaceStrings [ "." ] [ "-" ] cudaVersion;

  # This package is unfortunately not identical to the upstream cuda-samples
  # published at https://github.com/NVIDIA/cuda-samples, so we can't use
  # nixpkgs's pkgs/tests/cuda packages
  cuda-samples = stdenv.mkDerivation {
    pname = "cuda-samples";
    version = debs.common."cuda-samples-${cudaVersionDashes}".version;
    src = debs.common."cuda-samples-${cudaVersionDashes}".src;

    unpackCmd = "dpkg -x $src source";
    sourceRoot = "source/usr/local/cuda-${cudaVersion}/samples";

    patches = [ ./cuda-samples.patch ];

    nativeBuildInputs = [ dpkg pkg-config autoAddDriverRunpath ];
    buildInputs = [ cudaPackages.cudatoolkit ];

    preConfigure = ''
      export CUDA_PATH=${cudaPackages.cudatoolkit}
      export CUDA_SEARCH_PATH=${cudaPackages.cudatoolkit}/lib/stubs
    '';

    enableParallelBuilding = true;

    installPhase = ''
      runHook preInstall

      install -Dm755 -t $out/bin bin/${stdenv.hostPlatform.parsed.cpu.name}/${stdenv.hostPlatform.parsed.kernel.name}/release/*

      # *_nvrtc samples require your current working directory contains the corresponding .cu file
      find -ipath "*_nvrtc/*.cu" -exec install -Dt $out/data {} \;

      runHook postInstall
    '';
  };
  cuda-test = writeShellApplication {
    name = "cuda-test";
    text = ''
      BINARIES=(
        deviceQuery deviceQueryDrv bandwidthTest clock clock_nvrtc
        matrixMul matrixMulCUBLAS matrixMulDrv matrixMulDynlinkJIT
      )
      # clock_nvrtc expects .cu files under $PWD/data
      cd ${cuda-samples}/bin
      for binary in "''${BINARIES[@]}"; do
        echo " * Running $binary"
        ./"$binary"
        echo
        echo
      done
    '';
  };

  cudnn-samples = stdenv.mkDerivation {
    pname = "cudnn-samples";
    version = debs.common.libcudnn9-samples.version;
    src = debs.common.libcudnn9-samples.src;

    unpackCmd = "dpkg -x $src source";
    sourceRoot = "source/usr/src/cudnn_samples_v8";

    nativeBuildInputs = [ dpkg autoAddDriverRunpath ];
    buildInputs = with cudaPackages; [ cudatoolkit cudnn ];

    buildFlags = [
      "CUDA_PATH=${cudaPackages.cudatoolkit}"
      "CUDNN_INCLUDE_PATH=${cudaPackages.cudnn}/include"
      "CUDNN_LIB_PATH=${cudaPackages.cudnn}/lib"
    ];

    enableParallelBuilding = true;

    # Disabled mnistCUDNN since it requires freeimage which is marked vulnerable in upstream as of 24.05
    buildPhase = ''
      runHook preBuild

      for dirname in conv_sample multiHeadAttention RNN_v8.0; do
        pushd "$dirname"
        make $buildFlags
        popd 2>/dev/null
      done

      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall

      install -Dm755 -t $out/bin \
        conv_sample/conv_sample \
        multiHeadAttention/multiHeadAttention \
        RNN_v8.0/RNN

      runHook postInstall
    '';
  };
  cudnn-test = writeShellApplication {
    name = "cudnn-test";
    text = ''
      echo " * Running conv_sample"
      ${cudnn-samples}/bin/conv_sample
    '';
  };

  cupti-samples = stdenv.mkDerivation {
    pname = "cupti-samples";
    version = debs.common."cuda-cupti-dev-${cudaVersionDashes}".version;
    src = debs.common."cuda-cupti-dev-${cudaVersionDashes}".src;

    unpackCmd = "dpkg -x $src source";
    sourceRoot = "source/usr/local/cuda-${cudaVersion}/extras/CUPTI/samples";

    nativeBuildInputs = [ dpkg pkg-config autoAddDriverRunpath ];
    buildInputs = [ cudaPackages.cudatoolkit ];

    preConfigure = ''
      export CUDA_INSTALL_PATH=${cudaPackages.cudatoolkit}
    '';

    enableParallelBuilding = true;

    buildPhase = ''
      runHook preBuild

      # Some samples depend on this being built first
      make $buildFlags -C extensions/src/profilerhost_util

      for sample in *; do
        if [[ "$sample" != "extensions" ]]; then
          make $buildFlags -C "$sample"
        fi
      done

      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall

      for sample in *; do
        if [[ "$sample" != "extensions" && "$sample" != "autorange_profiling" && "$sample" != "userrange_profiling" ]]; then
          install -Dm755 -t $out/bin $sample/$sample
        fi
      done

      # These samples aren't named the same as their containing directory
      install -Dm755 -t $out/bin autorange_profiling/auto_range_profiling
      install -Dm755 -t $out/bin userrange_profiling/user_range_profiling

      runHook postInstall
    '';
  };
  cupti-test = writeShellApplication {
    name = "cupti-test";
    text = ''
      # Not entirely sure which utilities are relevant here, I'll just pick a few
      # See: https://docs.nvidia.com/cupti/main/main.html?highlight=samples#samples
      #
      for binary in auto_range_profiling callback_timestamp pc_sampling; do
        echo " * Running $binary"
        ${cupti-samples}/bin/"$binary"
        echo
        echo
      done

      # cupti_query fails on Orin with the following message:
      # "Error CUPTI_ERROR_LEGACY_PROFILER_NOT_SUPPORTED for CUPTI API function 'cuptiDeviceEnumEventDomains'."
      #
      # https://forums.developer.nvidia.com/t/whether-cuda-supports-gpu-devices-with-8-6-compute-capability/274884/4
      # Orin doesn't support the "legacy profile"
      if ! grep -q -E "tegra234" /proc/device-tree/compatible; then
        echo " * Running cupti_query"
        ${cupti-samples}/bin/cupti_query
        echo
        echo
      fi
    '';
  };

  graphics-demos = stdenv.mkDerivation {
    pname = "graphics-demos";
    version = debs.t234.nvidia-l4t-graphics-demos.version;
    src = debs.t234.nvidia-l4t-graphics-demos.src;

    unpackCmd = "dpkg -x $src source";
    sourceRoot = "source/usr/src/nvidia/graphics_demos";

    nativeBuildInputs = [ dpkg ];
    buildInputs = [ libX11 libGL libXau libdrm wayland libxkbcommon libffi ];

    postPatch = ''
      substituteInPlace Makefile.l4tsdkdefs \
        --replace /bin/cat ${coreutils}/bin/cat \
        --replace /bin/sed ${gnused}/bin/sed \
        --replace libffi.so.7 libffi.so
    '';

    buildPhase = ''
      runHook preBuild

      # TODO: Also do winsys=egldevice
      for winsys in wayland x11; do
        for demo in bubble ctree eglstreamcube gears-basic gears-cube gears-lib; do
          pushd "$demo"
          make NV_WINSYS=$winsys NV_PLATFORM_LDFLAGS= $buildFlags
          popd 2>/dev/null
        done
      done

      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall

      for winsys in wayland x11; do
        for demo in bubble ctree eglstreamcube; do
          install -Dm 755 "$demo/$winsys/$demo" "$out/bin/$winsys-$demo"
        done
        install -Dm 755 "gears-basic/$winsys/gears" "$out/bin/$winsys-gears"
        install -Dm 755 "gears-cube/$winsys/gearscube" "$out/bin/$winsys-gearscube"
      done

      runHook postInstall
    '';

    enableParallelBuilding = true;
  };
  # TODO: Add wayland and x11 tests for graphics demos....

  # Contains a bunch of tests for tensorrt, for example:
  # ./result/bin/sample_mnist --datadir=result/data/mnist
  libnvinfer-samples = stdenv.mkDerivation {
    pname = "libnvinfer-samples";
    version = debs.common.libnvinfer-samples.version;
    src = debs.common.libnvinfer-samples.src;

    unpackCmd = "dpkg -x $src source";
    sourceRoot = "source/usr/src/tensorrt/samples";

    nativeBuildInputs = [ dpkg autoAddDriverRunpath ];
    buildInputs = with cudaPackages; [ tensorrt cuda_profiler_api cudnn ];

    # These environment variables are required by the /usr/src/tensorrt/samples/README.md
    CUDA_INSTALL_DIR = cudaPackages.cudatoolkit;
    CUDNN_INSTALL_DIR = cudaPackages.cudnn;

    enableParallelBuilding = true;

    installPhase = ''
      runHook preInstall

      mkdir -p $out

      rm -rf ../bin/chobj
      rm -rf ../bin/dchobj
      cp -r ../bin $out/
      cp -r ../data $out/

      runHook postInstall
    '';
  };
  libnvinfer-test = writeShellApplication {
    name = "libnvinfer-test";
    text = ''
      echo " * Running sample_onnx_mnist"
      ${libnvinfer-samples}/bin/sample_onnx_mnist --datadir ${libnvinfer-samples}/data/mnist
      echo
      echo
    '';
  };

  # https://docs.nvidia.com/jetson/l4t-multimedia/group__l4t__mm__test__group.html
  multimedia-samples = stdenv.mkDerivation {
    pname = "multimedia-samples";
    src = debs.common.nvidia-l4t-jetson-multimedia-api.src;
    version = debs.common.nvidia-l4t-jetson-multimedia-api.version;

    unpackCmd = "dpkg -x $src source";
    sourceRoot = "source/usr/src/jetson_multimedia_api";

    nativeBuildInputs = [ dpkg python3 ];
    buildInputs = [ libX11 libdrm libglvnd opencv vulkan-headers vulkan-loader ]
      ++ ([ l4t-cuda l4t-multimedia l4t-camera ])
      ++ (with cudaPackages; [ cudatoolkit tensorrt ]);

    # Usually provided by pkg-config, but the samples don't use it.
    NIX_CFLAGS_COMPILE = [
      "-I${lib.getDev libdrm}/include/libdrm"
      "-I${lib.getDev opencv}/include/opencv4"
    ];

    # TODO: Unify this with headers in l4t-jetson-multimedia-api
    patches = [
      (fetchurl {
        url = "https://raw.githubusercontent.com/OE4T/meta-tegra/af0a93313c13e9eac4e80082d8a8e8ac5f7ad6e8/recipes-multimedia/argus/files/0005-Remove-DO-NOT-USE-declarations-from-v4l2_nv_extensio.patch";
        sha256 = "sha256-IJ1teGEUxYDEPYSvYZbqdmUYg9tOORN7WGYpDaUUnHY=";
      })
      (fetchurl {
        url = "https://raw.githubusercontent.com/OE4T/meta-tegra/4f825ddeb2e9a1b5fbff623955123c20b82c8274/recipes-multimedia/argus/tegra-mmapi-samples/0004-samples-classes-fix-a-data-race-in-shutting-down-deq.patch";
        sha256 = "sha256-mkS2eKuDvXDhHkIglUGcYbEWGxCP5gRSdmEvuVw/chI=";
      })
    ];

    postPatch = ''
      substituteInPlace samples/Rules.mk \
        --replace /usr/local/cuda "${cudaPackages.cudatoolkit}"

      substituteInPlace samples/08_video_dec_drm/Makefile \
        --replace /usr/bin/python "${python3}/bin/python"
    '';

    installPhase = ''
      runHook preInstall

      install -Dm 755 -t $out/bin $(find samples -type f -perm 755)
      rm -f $out/bin/*.h

      cp -r data $out/

      runHook postInstall
    '';
  };
  # ./result/bin/video_decode H264 /nix/store/zry377bb5vkz560ra31ds8r485jsizip-multimedia-samples-35.1.0-20220825113828/data/Video/sample_outdoor_car_1080p_10fps.h26
  # (Requires X11)
  #
  # Doing example here: https://docs.nvidia.com/jetson/l4t-multimedia/l4t_mm_07_video_convert.html
  multimedia-test = writeShellApplication {
    name = "multimedia-test";
    text = ''
      WORKDIR=$(mktemp -d)
      on_exit() {
        rm -rf "$WORKDIR"
      }
      trap on_exit EXIT

      echo " * Running jpeg_decode"
      ${multimedia-samples}/bin/jpeg_decode num_files 1 ${multimedia-samples}/data/Picture/nvidia-logo.jpg "$WORKDIR"/nvidia-logo.yuv
      echo
      echo " * Running video_decode"
      ${multimedia-samples}/bin/video_decode H264 --disable-rendering ${multimedia-samples}/data/Video/sample_outdoor_car_1080p_10fps.h264
      echo
      echo " * Running video_cuda_enc"
      if ! grep -q -E "p3767-000[345]" /proc/device-tree/compatible; then
        ${multimedia-samples}/bin/video_cuda_enc ${multimedia-samples}/data/Video/sample_outdoor_car_1080p_10fps.h264 1920 1080 H264 "$WORKDIR"/test.h264
      else
        echo "Orin Nano does not support hardware video encoding--skipping test"
      fi
      echo
      echo " * Running video_convert"
      ${multimedia-samples}/bin/video_convert "$WORKDIR"/nvidia-logo.yuv 1920 1080 YUV420 "$WORKDIR"/test.yuv 1920 1080 YUYV
      echo
    '';
  };

  # Tested via "./result/bin/vpi_sample_05_benchmark <cpu|pva|cuda>" (Try pva especially)
  # Getting a bunch of "pva 16000000.pva0: failed to get firmware" messages, so unsure if its working.
  vpi2-samples = stdenv.mkDerivation {
    pname = "vpi2-samples";
    version = debs.common.vpi2-samples.version;
    src = debs.common.vpi2-samples.src;

    unpackCmd = "dpkg -x $src source";
    sourceRoot = "source/opt/nvidia/vpi2/samples";

    nativeBuildInputs = [ dpkg cmake ];
    buildInputs = [ opencv ] ++ (with cudaPackages; [ vpi2 ]);

    configurePhase = ''
      runHook preBuild

      for dirname in $(find . -type d | sort); do
        if [[ -e "$dirname/CMakeLists.txt" ]]; then
          echo "Configuring $dirname"
          pushd $dirname
          cmake .
          popd 2>/dev/null
        fi
      done

      runHook postBuild
    '';

    buildPhase = ''
      runHook preBuild

      for dirname in $(find . -type d | sort); do
        if [[ -e "$dirname/CMakeLists.txt" ]]; then
          echo "Building $dirname"
          pushd $dirname
          make $buildFlags
          popd 2>/dev/null
        fi
      done

      runHook postBuild
    '';

    enableParallelBuilding = true;

    installPhase = ''
      runHook preInstall

      install -Dm 755 -t $out/bin $(find . -type f -maxdepth 2 -perm 755)

      runHook postInstall
    '';
  };
  vpi2-test = writeShellApplication {
    name = "vpi2-test";
    text = ''
      echo " * Running vpi_sample_05_benchmark cuda"
      ${vpi2-samples}/bin/vpi_sample_05_benchmark cuda
      echo

      echo " * Running vpi_sample_05_benchmark cpu"
      ${vpi2-samples}/bin/vpi_sample_05_benchmark cpu
      echo

      CHIP="$(tr -d '\0' < /proc/device-tree/compatible)"
      if [[ "''${CHIP}" =~ "tegra194" ]]; then
        echo " * Running vpi_sample_05_benchmark pva"
        ${vpi2-samples}/bin/vpi_sample_05_benchmark pva
        echo
      fi
    '';
    # PVA is only available on Xaviers. If the Jetpack version of the
    # firmware doesnt match the vpi2 version, it might fail with the
    # following:
    # [  435.318277] pva 16800000.pva1: invalid symbol id in descriptor for dst2 VMEM
    # [  435.318467] pva 16800000.pva1: failed to map DMA desc info
  };

  combined-test = writeShellApplication {
    name = "combined-test";
    text = ''
      echo "====="
      echo "Running CUDA test"
      echo "====="
      ${cuda-test}/bin/cuda-test

      echo "====="
      echo "Running CUDNN test"
      echo "====="
      ${cudnn-test}/bin/cudnn-test

      echo "====="
      echo "Running CUPTI test"
      echo "====="
      ${cupti-test}/bin/cupti-test

      echo "====="
      echo "Running TensorRT test"
      echo "====="
      ${libnvinfer-test}/bin/libnvinfer-test

      echo "====="
      echo "Running Multimedia test"
      echo "====="
      ${multimedia-test}/bin/multimedia-test

      echo "====="
      echo "Running VPI2 test"
      echo "====="
      ${vpi2-test}/bin/vpi2-test
    '';
  };
in
{
  inherit
    cuda-samples
    cuda-test
    cudnn-samples
    cudnn-test
    cupti-samples
    cupti-test
    graphics-demos
    libnvinfer-samples
    libnvinfer-test
    multimedia-samples
    multimedia-test
    vpi2-samples
    vpi2-test;

  inherit combined-test;
}
