{
  lib,
  stdenv,
  fetchFromGitHub,
  cmake,
  ninja,
  pkg-config,
  clr,
  rocm-cmake,
  rocm-runtime,
  rocprofiler-register,
  rocprof-trace-decoder,
  aqlprofile,
  rocm-comgr,
  rocmUpdateScript,
  rccl,
  python3,
  python3Packages,
  libdrm,
  elfutils,
  sqlite,
  otf2,
  zlib,
  zstd,
  xz,
  numactl,
  fmt,
  glog,
  gtest,
  yaml-cpp,
  elfio,
  nlohmann_json,
  makeWrapper,
  gpuTargets ? (clr.localGpuTargets or clr.gpuTargets),
  buildTests ? false,
  buildSamples ? false,
}:

# FIXME: devendor remaining git submodules:
#   external/cereal     -> https://github.com/jrmadsen/cereal
#   external/gotcha     -> https://github.com/jrmadsen/GOTCHA
#   external/perfetto   -> https://github.com/google/perfetto
#   external/ptl        -> https://github.com/jrmadsen/PTL

# rocprofiler-sdk is the home of rocprofv3
stdenv.mkDerivation (finalAttrs: {
  pname = "rocprofiler-sdk";
  version = "10.1.0";

  outputs = [
    "out"
    "dev"
  ];

  src = fetchFromGitHub {
    owner = "ROCm";
    repo = "rocm-systems";
    tag = "therock-${lib.versions.majorMinor finalAttrs.version}";
    hash = "sha256-UmYHC+87XIW+Z4WVd7k0MQ9baTvFlq/SgCt9Foy1mPI=";
    fetchSubmodules = true;
    sparseCheckout = [
      "projects/rocprofiler-sdk"
    ];
  };
  sourceRoot = "${finalAttrs.src.name}/projects/rocprofiler-sdk";

  strictDeps = true;

  nativeBuildInputs = [
    cmake
    ninja
    pkg-config
    clr
    python3
    makeWrapper
  ];

  buildInputs = [
    clr
    rocm-cmake
    rocm-runtime
    rocprofiler-register
    aqlprofile
    # therock-10.0: rocprofiler-sdk-tool now find_package(rocprof-trace-decoder
    # REQUIRED) at configure for the ATT quick-scan feature (was runtime-only).
    rocprof-trace-decoder
    rocm-comgr
    libdrm
    elfutils
    sqlite
    otf2
    zlib
    zstd
    xz
    numactl
    fmt
    glog
    gtest
    yaml-cpp
    elfio
    nlohmann_json
    rccl
    python3Packages.pybind11
  ];

  patches = [
    # NOTE(rocm-10): dropped fetchpatch 86ee7b2e (PR #2319 "[rocprofiler-sdk]
    # Improve build with system libraries") — fully merged upstream in
    # therock-10.0: the ROCPROFILER_BUILD_YAML_CPP option + system yaml-cpp
    # branch + CPackComponent are present (4/6 hunks reverse-apply), and the two
    # incidental include fixes it also carried (<fmt/ranges.h> in
    # sql_generator.hpp, <memory> in metrics.hpp) are already in the source too.
    # NOTE(rocm-10): dropped fetchpatches 36d9d33d (fmt "memory header" fix) and
    # 94a4595a (amd_comgr linkage in the pc-sampling integration test) — both are
    # already present in therock-10.0.
    # See https://github.com/ROCm/rocm-systems/pull/4721
    # NOTE(rocm-10): dropped 0001 (rename-consumer-test) and 0008
    # (stop-setting-warning-flags) — both only touch test/tests-bin CMakeLists,
    # and tests are off by default (buildTests ? false).
    # NOTE(rocm-10.1): dropped 0002, 0003, 0004, 0005, 0006 and 0007 — therock-10.1
    # merged all of them upstream, so they no longer apply:
    #   * 0002 (add-missing-stl-headers): the <array>/<memory>/<fstream> adds are
    #     already in att_lib_wrapper.hpp, rocpd/sql.cpp, counters/metrics.cpp,
    #     rocattach/auxv.cpp.
    #   * 0003 (amd-comgr dep): the rocpd python-bindings target already links
    #     rocprofiler-sdk-amd-comgr (source/lib/python/utilities.cmake:221).
    #   * 0004 (find_package GLOBAL scoping): CMakeLists already requires CMake
    #     3.24, and GTest/fmt/yaml-cpp find_package calls already pass GLOBAL.
    #   * 0005/0006/0007 (system elfio/otf2/json): the ROCPROFILER_BUILD_ELFIO/
    #     _OTF2/_JSON options + `else() find_package(... REQUIRED GLOBAL)` branches
    #     are present upstream (cmake/rocprofiler_options.cmake:72-76,
    #     external/CMakeLists.txt:211-261) — PR #2319 / #1243 landed in 10.1.
    # The -DROCPROFILER_BUILD_{ELFIO,OTF2,JSON}=false cmakeFlags below still drive
    # those now-upstream options to use our system elfio/otf2/nlohmann_json.
    # Prevent a segfault on `import torch` (and other consumers that link
    # librocprofiler-sdk for tracing) when OpenMP auto-discovers our
    # ompt_start_tool before glog is initialized. Upstream incidentally fixes
    # this by dropping glog in rocm-systems d80117889b3f
    # "[rocprofiler-sdk] Migrate from glog to Abseil Logging (#4668)", which
    # is too invasive (40 files + new abseil submodule) to backport.
    ./0009-rocprofiler-sdk-guard-ompt-auto-start.patch
  ];

  postPatch = ''
        # NixOS' ROCm distribution does not support libomptarget yet
        substituteInPlace samples/CMakeLists.txt \
          --replace-fail 'add_subdirectory(openmp_target)' '# add_subdirectory(openmp_target)'
        substituteInPlace tests/CMakeLists.txt \
          --replace-fail 'add_subdirectory(openmp-tools)' '# add_subdirectory(openmp-tools)'
        substituteInPlace tests/bin/CMakeLists.txt \
          --replace-fail 'add_subdirectory(openmp)' '# add_subdirectory(openmp)'

        # This requires building perfetto's trace-processor-shell via a weird external script
        substituteInPlace tests/CMakeLists.txt \
          --replace-fail 'add_subdirectory(pytest-packages)' ""

        # therock-10.0 has bare system includes (`<sqlite3.h>` in the output/sql +
        # python-binding sources, `<libdrm/amdgpu*.h>` in the vendored aqlprofile)
        # that assume a distro-style /usr/include. nixpkgs keeps those headers in the
        # packages' dev outputs, and the rocm-toolchain clang used here
        # (-DCMAKE_CXX_COMPILER=clang++, unwrapped) ignores NIX_CFLAGS_COMPILE, so add
        # them as a real CMake -isystem at the top of the tree. (A global
        # -DCMAKE_CXX_FLAGS instead would clobber abseil's C++-standard detection.)
        substituteInPlace CMakeLists.txt \
          --replace-fail 'add_subdirectory(external)' \
            'include_directories(SYSTEM ${lib.getDev sqlite}/include ${lib.getDev libdrm}/include)
    add_subdirectory(external)'

        patchShebangs source/libexec/rocprofiler-sdk/rocprofiler-sdk-launch-compiler/rocprofiler-sdk-launch-compiler.sh
  '';

  cmakeFlags = [
    (lib.cmakeBool "ROCPROFILER_BUILD_GHC_FS" false)
    (lib.cmakeBool "ROCPROFILER_BUILD_FMT" false)
    (lib.cmakeBool "ROCPROFILER_BUILD_GLOG" false)
    (lib.cmakeBool "ROCPROFILER_BUILD_GTEST" false)
    (lib.cmakeBool "ROCPROFILER_BUILD_PYBIND11" false)
    (lib.cmakeBool "ROCPROFILER_BUILD_YAML_CPP" false)
    (lib.cmakeBool "ROCPROFILER_BUILD_ELFIO" false)
    (lib.cmakeBool "ROCPROFILER_BUILD_OTF2" false)
    (lib.cmakeBool "ROCPROFILER_BUILD_JSON" false)
    (lib.cmakeBool "ROCPROFILER_BUILD_TESTS" buildTests)
    (lib.cmakeBool "ROCPROFILER_BUILD_SAMPLES" buildSamples)
    (lib.cmakeBool "ROCPROFILER_BUILD_BENCHMARK" false)
    (lib.cmakeBool "ROCPROFILER_BUILD_WERROR" false)
    # rocprofiler-sdk's CMake file doesn't add this dependency properly.
    "-DCMAKE_HIP_FLAGS=-I${rocm-runtime}/include"
    "-DCMAKE_INSTALL_BINDIR=bin"
    "-DCMAKE_INSTALL_LIBDIR=lib"
    "-DCMAKE_INSTALL_INCLUDEDIR=include"
    # Required for rocprofiler-sdk-launch-compiler.sh
    "-DCMAKE_INSTALL_LIBEXECDIR=libexec"
    "--debug-find-pkg=amd_comgr"
    "--trace-source=tests/pc_sampling/CMakeLists.txt"
    "--trace-expand"
  ]
  ++ lib.optionals (buildTests || buildSamples) [
    # rocprofiler-sdk normally doesn't depend on which GPU is in the system, only when
    # building tests or samples.
    (lib.cmakeFeature "GPU_TARGETS" (lib.concatStringsSep ";" gpuTargets))
  ];

  doCheck = false; # Requires GPU

  postFixup = ''
    patchelf $out/lib/*.so \
      --add-rpath ${aqlprofile}/lib \
      --add-needed libhsa-amd-aqlprofile64.so

    wrapProgram $out/bin/rocprofv3 --add-flags "--att-library-path ${
      lib.makeLibraryPath [ rocprof-trace-decoder ]
    }"
  '';

  postInstall = ''
    mkdir -p $dev/lib $dev/share/rocprofiler-sdk
    mv $out/lib/cmake $dev/lib/
    mv $out/share/rocprofiler-sdk/{samples,tests} $dev/share/rocprofiler-sdk/
  '';

  passthru.updateScript = rocmUpdateScript { inherit finalAttrs; };

  meta = {
    description = "ROCm GPU performance analysis SDK";
    homepage = "https://github.com/ROCm/rocprofiler-sdk";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
  };
})
