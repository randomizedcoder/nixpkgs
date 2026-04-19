{
  lts ? false,
  version,
  rev,
  hash,
}:

{
  lib,
  stdenv,
  buildPackages,
  llvmPackages_19,
  llvmPackages_21,
  fetchFromGitHub,
  fetchpatch,
  cmake,
  ninja,
  python3,
  perl,
  nasm,
  yasm,
  nixosTests,
  darwin,
  findutils,
  libiconv,
  removeReferencesTo,
  rustSupport ? true,
  rustc,
  cargo,
  rustPlatform,
  nix-update-script,
  versionCheckHook,
}:
let
  llvmPackages = if lib.versionAtLeast version "26" then llvmPackages_21 else llvmPackages_19;
  llvmStdenv = llvmPackages.stdenv;
  # For cross-compilation, the native build sub-cmake needs a build-platform
  # clang (one that runs on the build machine, not the target).
  nativeClang = if lib.versionAtLeast version "26"
    then buildPackages.llvmPackages_21.clang-unwrapped
    else buildPackages.llvmPackages_19.clang-unwrapped;
in
llvmStdenv.mkDerivation (finalAttrs: {
  pname = "clickhouse";
  inherit version;
  inherit rev;

  src = fetchFromGitHub rec {
    owner = "ClickHouse";
    repo = "ClickHouse";
    tag = "v${finalAttrs.version}";
    fetchSubmodules = true;
    name = "clickhouse-${tag}.tar.gz";
    inherit hash;
    postFetch = ''
      # Delete files that make the source too big
      rm -rf $out/contrib/arrow/docs/
      rm -rf $out/contrib/arrow/testing/
      rm -rf $out/contrib/aws/generated/protocol-tests/
      rm -rf $out/contrib/aws/generated/smoke-tests/
      rm -rf $out/contrib/aws/generated/tests/
      rm -rf $out/contrib/aws/tools/
      rm -rf $out/contrib/cld2/internal/test_shuffle_1000_48_666.utf8.gz
      rm -rf $out/contrib/croaring/benchmarks/
      rm -rf $out/contrib/boost/doc/
      rm -rf $out/contrib/boost/libs/*/bench/
      rm -rf $out/contrib/boost/libs/*/example/
      rm -rf $out/contrib/boost/libs/*/doc/
      rm -rf $out/contrib/boost/libs/*/test/
      rm -rf $out/contrib/google-cloud-cpp/ci/abi-dumps/
      rm -rf $out/contrib/icu/icu4c/source/test/
      rm -rf $out/contrib/icu/icu4j/main/core/src/test/
      rm -rf $out/contrib/icu/icu4j/perf-tests/
      rm -rf $out/contrib/llvm-project/*/docs/
      rm -rf $out/contrib/llvm-project/*/test/
      rm -rf $out/contrib/llvm-project/*/unittests/
      rm -rf $out/contrib/postgres/doc/

      # As long as we're not running tests, remove test files
      rm -rf $out/tests/

      # fix case insensitivity on macos https://github.com/NixOS/nixpkgs/issues/39308
      rm -rf $out/contrib/sysroot/linux-*
      rm -rf $out/contrib/liburing/man

      # Compress to not exceed the 2GB output limit
      echo "Creating deterministic source tarball..."

      tar -I 'gzip -n' \
        --sort=name \
        --mtime=1970-01-01 \
        --owner=0 --group=0 \
        --numeric-owner --mode=go=rX,u+rw,a-s \
        --transform='s@^@source/@S' \
        -cf temp  -C "$out" .

      echo "Finished creating deterministic source tarball!"

      rm -r "$out"
      mv temp "$out"
    '';
  };

  strictDeps = true;
  nativeBuildInputs = [
    cmake
    ninja
    python3
    perl
    llvmPackages.lld
    removeReferencesTo
  ]
  ++ lib.optionals stdenv.hostPlatform.isx86_64 [
    nasm
    yasm
  ]
  ++ lib.optionals (stdenv.hostPlatform.isDarwin || stdenv.buildPlatform != stdenv.hostPlatform) [
    llvmPackages.bintools
  ]
  ++ lib.optionals stdenv.hostPlatform.isDarwin [
    findutils
    darwin.bootstrap_cmds
  ]
  ++ lib.optionals rustSupport [
    rustc
    cargo
    rustPlatform.cargoSetupHook
  ];

  buildInputs = lib.optionals stdenv.hostPlatform.isDarwin [ libiconv ];

  dontCargoSetupPostUnpack = true;

  patches =
    lib.optional (lib.versions.majorMinor version == "25.8") (fetchpatch {
      # Disable building WASM lexer
      url = "https://github.com/ClickHouse/ClickHouse/commit/67a42b78cdf1c793e78c1adbcc34162f67044032.patch";
      hash = "sha256-7VF+JSztqTWD+aunCS3UVNxlRdwHc2W5fNqzDyeo3Fc=";
    })
    ++

      lib.optional (lib.versions.majorMinor version == "25.8" && stdenv.hostPlatform.isDarwin)
        (fetchpatch {
          # Do not intercept memalign on darwin
          url = "https://github.com/ClickHouse/ClickHouse/commit/0cfd2dbe981727fb650f3b9935f5e7e7e843180f.patch";
          hash = "sha256-1iNYZbugX2g2dxNR1ZiUthzPnhLUR8g118aG23yhgUo=";
        })
    ++ lib.optional (!lib.versionAtLeast version "25.11" && stdenv.hostPlatform.isDarwin) (fetchpatch {
      # Remove flaky macOS SDK version detection
      url = "https://github.com/ClickHouse/ClickHouse/commit/11e172a37bd0507d595d27007170090127273b33.patch";
      hash = "sha256-oI7MrjMgJpIPTsci2IqEOs05dUGEMnjI/WqGp2N+rps=";
    })
    ++ lib.optional stdenv.hostPlatform.isBigEndian
      # Fix column serialization endianness: serialize size fields as little-endian
      # to match readBinaryLittleEndian in deserialization. Without this, GROUP BY
      # on complex types (nullable, tuples, LowCardinality, Dynamic) causes 256 PiB
      # allocation attempts on big-endian systems (s390x).
      ./0100-fix-column-serialization-endianness.patch
    ++ lib.optional stdenv.hostPlatform.isBigEndian
      # Fix compression codec endianness: GCD uses native unalignedLoad/Store,
      # T64 has asymmetric load (LE) / store (native), FPC hardcodes little-endian.
      # Without this, GCD/T64 data is not cross-arch portable, and FPC produces
      # corrupted data (NaN, Inf) on big-endian systems (s390x).
      ./0101-fix-compression-codec-endianness.patch
    ++ lib.optional stdenv.hostPlatform.isBigEndian
      # Fix Parquet reader endianness: Parquet format stores all multi-byte
      # values in little-endian. The native V3 reader used memcpy/unalignedLoad
      # in native byte order, corrupting int/float columns and dict string
      # lengths on big-endian (s390x). Adds LE→native byteswap after reads in
      # Decoding.cpp (indexImpl, memcpyIntoColumn, string length prefixes) and
      # Reader.cpp (footer metadata size).
      ./0102-fix-parquet-reader-endianness.patch
    ++ lib.optional stdenv.hostPlatform.isBigEndian
      # Fix Parquet writer endianness: symmetric counterpart to 0102. Arrow's
      # PlainEncoder::Put, DictEncoder ByteArray length prefix, and UnsafePutByteArray
      # write column data and length fields in native byte order; ClickHouse's
      # Write.cpp writes footer size, RLE prefixes, statistics, and bloom filter
      # words the same way. Adds native→LE byteswap before each write so BE
      # produces spec-compliant Parquet files.
      ./0103-fix-parquet-writer-endianness.patch
    ++ lib.optional stdenv.hostPlatform.isBigEndian
      # Fix wide_integer tuple construction limb order. On big-endian the
      # canonical storage indexes limbs via little(i) = item_count - 1 - i, but
      # wide_integer_from_tuple_like stored tuple element i directly into
      # items[i], swapping low/high halves of Int128/UInt128 etc. built from
      # tuples or multi-element initializer lists.
      ./0104-fix-wide-integer-limb-order.patch;

  postPatch = ''
    patchShebangs src/ utils/
  ''
  + lib.optionalString stdenv.hostPlatform.isDarwin ''
    substituteInPlace cmake/tools.cmake \
      --replace-fail 'gfind' 'find' \
      --replace-fail 'ggrep' 'grep' \
      --replace-fail '--ld-path=''${LLD_PATH}' '-fuse-ld=lld'

    substituteInPlace utils/list-licenses/list-licenses.sh \
      --replace-fail 'gfind' 'find' \
      --replace-fail 'ggrep' 'grep'
  ''
  + lib.optionalString stdenv.hostPlatform.isBigEndian ''
    # ICU bundled data tables default to little-endian
    substituteInPlace contrib/icu/icu4c/source/common/unicode/platform.h \
      --replace-fail "U_IS_BIG_ENDIAN 0" "U_IS_BIG_ENDIAN 1" || true
  ''
  + lib.optionalString stdenv.hostPlatform.isS390x ''
    # Add s390x Rust target to corrosion-cmake. ClickHouse's cmake/target.cmake
    # auto-loads toolchain-s390x.cmake, but corrosion's set_rust_target() macro
    # doesn't know the s390x toolchain → Rust target triple mapping.
    # Insert before endif() in the toolchain-to-Rust-target mapping block.
    sed -i '/set(Rust_CARGO_TARGET "riscv64gc-unknown-linux-gnu"/a\
        elseif(CMAKE_TOOLCHAIN_FILE MATCHES "linux/toolchain-s390x")\
            set(Rust_CARGO_TARGET "s390x-unknown-linux-gnu" CACHE INTERNAL "Rust config")' \
      contrib/corrosion-cmake/CMakeLists.txt

    # Replace mold with lld in the s390x toolchain file. mold does not support
    # s390x (no big-endian ELF). The toolchain file sets -fuse-ld=mold which
    # overrides any -DLINKER_NAME=lld passed via cmakeFlags.
    sed -i 's/mold/lld/g' cmake/linux/toolchain-s390x.cmake
  ''
  + lib.optionalString (stdenv.buildPlatform != stdenv.hostPlatform) (
    let
      builtinsLib = "${stdenv.cc}/resource-root/lib/linux/libclang_rt.builtins-${stdenv.hostPlatform.parsed.cpu.name}.a";
    in ''
    # For cross-compilation, use the system compiler-rt builtins directly.
    # ClickHouse's embedded compiler-rt build fails because Nix's cc-wrapper
    # sets CMAKE_CXX_COMPILER_TARGET to the build platform, not the host.
    sed -i 's|include (cmake/build_clang_builtin.cmake)|# Patched: use system compiler-rt|' cmake/linux/default_libs.cmake
    sed -i "s|build_clang_builtin.*BUILTINS_LIBRARY.*|set(BUILTINS_LIBRARY \"${builtinsLib}\")|" cmake/linux/default_libs.cmake

    # The native build sub-cmake (for protoc etc.) doesn't inherit our cmake
    # cache variables. It needs -DCOMPILER_CACHE=disabled to avoid erroring
    # on missing ccache/sccache, and needs the native (build-platform) compiler
    # instead of the cross compiler.
    sed -i '/"-DCMAKE_C_COMPILER=''${CMAKE_C_COMPILER}"/{
      s|"-DCMAKE_C_COMPILER=''${CMAKE_C_COMPILER}"|"-DCMAKE_C_COMPILER=${nativeClang}/bin/clang"|
    }' CMakeLists.txt
    sed -i '/"-DCMAKE_CXX_COMPILER=''${CMAKE_CXX_COMPILER}"/{
      s|"-DCMAKE_CXX_COMPILER=''${CMAKE_CXX_COMPILER}"|"-DCMAKE_CXX_COMPILER=${nativeClang}/bin/clang++"|
    }' CMakeLists.txt
    sed -i '/"-DENABLE_RUST=OFF"/a\            "-DCOMPILER_CACHE=disabled"' CMakeLists.txt
  '')
  # Rust is handled by cmake
  + lib.optionalString rustSupport ''
    cargoSetupPostPatchHook() { true; }
  '';

  # Set the version the same way as ClickHouse CI does.
  #
  # https://github.com/clickhouse/clickhouse/blob/31127f21f8bb7ff21f737c4822de10ef5859c702/ci/jobs/scripts/clickhouse_version.py#L11-L20
  # https://github.com/clickhouse/clickhouse/blob/31127f21f8bb7ff21f737c4822de10ef5859c702/ci/jobs/build_clickhouse.py#L179
  preConfigure =
    let
      gitTagName = finalAttrs.version;
      versionStr = builtins.elemAt (lib.splitString "-" gitTagName) 0;

      parts = lib.splitVersion versionStr;

      major = builtins.elemAt parts 0;
      minor = builtins.elemAt parts 1;
      patch = builtins.elemAt parts 2;

      # The full commit hash is already available here:
      gitHash = rev;
    in
    ''
      cat <<'EOF' > cmake/autogenerated_versions.txt
      SET(VERSION_REVISION 0)
      SET(VERSION_MAJOR ${major})
      SET(VERSION_MINOR ${minor})
      SET(VERSION_PATCH ${patch})
      SET(VERSION_GITHASH ${gitHash})
      SET(VERSION_DESCRIBE ${gitTagName})
      SET(VERSION_STRING ${versionStr})
      EOF
    ''
    # ClickHouse's toolchain file launches sub-cmake processes via execute_process
    # during the configure phase. These sub-builds don't inherit cmake cache
    # variables like -DOBJCOPY_PATH and search for unprefixed "objcopy"/"strip"
    # which don't exist in Nix's cross environment (Nix provides e.g.
    # s390x-unknown-linux-gnu-objcopy). Creating unprefixed symlinks on PATH
    # before configure makes the tools discoverable by all sub-processes.
    + lib.optionalString (stdenv.buildPlatform != stdenv.hostPlatform) ''
      mkdir -p $TMPDIR/cross-tools
      ln -sf ${stdenv.cc.bintools.bintools}/bin/${stdenv.cc.targetPrefix}objcopy $TMPDIR/cross-tools/objcopy
      ln -sf ${stdenv.cc.bintools.bintools}/bin/${stdenv.cc.targetPrefix}strip $TMPDIR/cross-tools/strip
      ln -sf ${stdenv.cc.bintools.bintools}/bin/${stdenv.cc.targetPrefix}ar $TMPDIR/cross-tools/ar
      ln -sf ${stdenv.cc.bintools.bintools}/bin/${stdenv.cc.targetPrefix}ranlib $TMPDIR/cross-tools/ranlib
      export PATH="$TMPDIR/cross-tools:$PATH"
    '';

  cmakeFlags = [
    "-DENABLE_CHDIG=OFF"
    "-DENABLE_TESTS=OFF"
    "-DENABLE_DELTA_KERNEL_RS=0"
    "-DENABLE_XRAY=OFF"
    "-DCOMPILER_CACHE=disabled"
  ]
  ++ lib.optional (
    stdenv.hostPlatform.isLinux && stdenv.hostPlatform.isAarch64
  ) "-DNO_ARMV81_OR_HIGHER=1"
  ++ lib.optionals stdenv.hostPlatform.isS390x [
    "-DNO_SSE3_OR_HIGHER=1"
    "-DNO_AVX_OR_HIGHER=1"
    "-DNO_AVX256_OR_HIGHER=1"
    "-DNO_AVX512_OR_HIGHER=1"
    "-DENABLE_GRPC_USE_OPENSSL=1"
    "-DENABLE_ISAL_LIBRARY=OFF"
    "-DENABLE_HDFS=OFF"
  ]
  ++ lib.optionals (stdenv.buildPlatform != stdenv.hostPlatform) [
    "-DOBJCOPY_PATH=${stdenv.cc.bintools.bintools}/bin/${stdenv.cc.targetPrefix}objcopy"
    "-DSTRIP_PATH=${stdenv.cc.bintools.bintools}/bin/${stdenv.cc.targetPrefix}strip"
  ]
  # The toolchain file sets CMAKE_SYSROOT to ClickHouse's vendored sysroot and
  # is designed for cross-compilation. For native builds, the system compiler
  # and glibc are already correct — using the toolchain file would conflict.
  ++ lib.optionals (stdenv.hostPlatform.isS390x && stdenv.buildPlatform != stdenv.hostPlatform) [
    "-DCMAKE_TOOLCHAIN_FILE=cmake/linux/toolchain-s390x.cmake"
  ];

  env = {
    CARGO_HOME = "$PWD/../.cargo/";
    NIX_CFLAGS_COMPILE =
      # undefined reference to '__sync_val_compare_and_swap_16'
      lib.optionalString stdenv.hostPlatform.isx86_64 " -mcx16"
      +
        # Silence ``-Wimplicit-const-int-float-conversion` error in MemoryTracker.cpp and
        # ``-Wno-unneeded-internal-declaration` TreeOptimizer.cpp.
        lib.optionalString stdenv.hostPlatform.isDarwin
          " -Wno-implicit-const-int-float-conversion -Wno-unneeded-internal-declaration";
  };

  # https://github.com/ClickHouse/ClickHouse/issues/49988
  hardeningDisable = [
    "fortify"
    "libcxxhardeningfast"
  ];

  nativeInstallCheckInputs = [ versionCheckHook ];
  doInstallCheck = true;
  preVersionCheck = ''
    version=${builtins.head (lib.splitString "-" version)}
  '';

  postInstall = ''
    sed -i -e '\!<log>/var/log/clickhouse-server/clickhouse-server\.log</log>!d' \
      $out/etc/clickhouse-server/config.xml
    substituteInPlace $out/etc/clickhouse-server/config.xml \
      --replace-fail "<errorlog>/var/log/clickhouse-server/clickhouse-server.err.log</errorlog>" "<console>1</console>" \
      --replace-fail "<level>trace</level>" "<level>warning</level>"
    remove-references-to -t ${llvmStdenv.cc} $out/bin/clickhouse
  '';

  # canary for the remove-references-to hook failing
  disallowedReferences = [ llvmStdenv.cc ];

  # Basic smoke test
  doCheck = true;
  checkPhase = lib.optionalString (stdenv.buildPlatform.canExecute stdenv.hostPlatform) ''
    $NIX_BUILD_TOP/$sourceRoot/build/programs/clickhouse local --query 'SELECT 1' | grep 1
  '';

  # Builds in 7+h with 2 cores, and ~20m with a big-parallel builder.
  requiredSystemFeatures = [ "big-parallel" ];

  passthru = {
    tests = if lts then nixosTests.clickhouse-lts else nixosTests.clickhouse;

    updateScript = [
      ./update.sh

      (if lts then ./lts.nix else ./package.nix)
    ];
  };

  meta = {
    homepage = "https://clickhouse.com";
    description = "Column-oriented database management system";
    license = lib.licenses.asl20;
    changelog = "https://github.com/ClickHouse/ClickHouse/blob/v${version}/CHANGELOG.md";

    mainProgram = "clickhouse";

    # not supposed to work on 32-bit https://github.com/ClickHouse/ClickHouse/pull/23959#issuecomment-835343685
    platforms = lib.filter (x: (lib.systems.elaborate x).is64bit) (
      lib.platforms.linux ++ lib.platforms.darwin
    );
    broken = stdenv.buildPlatform != stdenv.hostPlatform
      && !stdenv.hostPlatform.isS390x;

    maintainers = with lib.maintainers; [
      thevar1able
    ];
  };
})
