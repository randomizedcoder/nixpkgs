{
  lib,
  stdenv,
  llvm_meta,
  release_version,
  monorepoSrc ? null,
  src ? null,
  runCommand,
  cmake,
  ninja,
  llvm,
  lit,
  clang-unwrapped,
  perl,
  pkg-config,
  python3,
  version,
  devExtraCmakeFlags ? [ ],
  ompdSupport ? true,
  ompdGdbSupport ? ompdSupport,
  getVersionFile,
  checkPhaseThreadLimitHook,
}:

assert lib.assertMsg (ompdGdbSupport -> ompdSupport) "OMPD GDB support requires OMPD support!";

let
  # LLVM 23 removed the standalone OpenMP build; use the runtimes entry point.
  # TODO: drop the version guards on staging; they keep LLVM < 23 unchanged.
  useRuntimesBuild = lib.versionAtLeast release_version "23";
in
stdenv.mkDerivation (finalAttrs: {
  pname = "openmp";
  inherit version;

  src =
    if monorepoSrc != null then
      runCommand "openmp-src-${version}"
        {
          inherit (monorepoSrc) passthru;
          strictDeps = true;
          __structuredAttrs = true;
        }
        ''
          mkdir -p "$out"
          cp -r ${monorepoSrc}/cmake "$out"
          cp -r ${monorepoSrc}/openmp "$out"
        ''
    else
      src;

  sourceRoot = "${finalAttrs.src.name}/openmp";

  # Configure from runtimes/; the build writes generated headers into openmp/.
  ${if useRuntimesBuild then "postUnpack" else null} = ''
    chmod u+w ${finalAttrs.src.name}
    cp -r --no-preserve=mode ${monorepoSrc}/runtimes ${monorepoSrc}/third-party ${finalAttrs.src.name}
    mkdir ${finalAttrs.src.name}/llvm
    cp -r --no-preserve=mode ${monorepoSrc}/llvm/cmake ${finalAttrs.src.name}/llvm
    sourceRoot=${finalAttrs.src.name}/runtimes
  '';

  outputs = [
    "out"
    "dev"
  ];

  patches =
    lib.optional (lib.versionOlder release_version "19") (getVersionFile "openmp/fix-find-tool.patch")
    ++ [
      (getVersionFile "openmp/run-lit-directly.patch")
    ];

  nativeBuildInputs = [
    cmake
    python3
    perl
    ninja
    pkg-config
    lit
  ];

  propagatedNativeBuildInputs = [
    checkPhaseThreadLimitHook
  ];

  buildInputs = [
    llvm
  ]
  ++ lib.optionals (ompdSupport && ompdGdbSupport) [
    python3
  ];

  strictDeps = true;

  cmakeFlags = [
    (lib.cmakeBool "LIBOMP_ENABLE_SHARED" (
      !stdenv.hostPlatform.isStatic && stdenv.hostPlatform.hasSharedLibraries
    ))
    (lib.cmakeBool "LIBOMP_OMPD_SUPPORT" ompdSupport)
    (lib.cmakeBool "LIBOMP_OMPD_GDB_SUPPORT" ompdGdbSupport)
    (lib.cmakeFeature "CLANG_TOOL" "${clang-unwrapped}/bin/clang")
    (lib.cmakeFeature "OPT_TOOL" "${llvm}/bin/opt")
    (lib.cmakeFeature "LINK_TOOL" "${llvm}/bin/llvm-link")
  ]
  ++ lib.optionals useRuntimesBuild [
    (lib.cmakeFeature "LLVM_ENABLE_RUNTIMES" "openmp")
    (lib.cmakeBool "LLVM_INCLUDE_TESTS" false)
  ]
  ++ devExtraCmakeFlags;

  doCheck = false;

  checkTarget = "check-openmp";

  preCheck = ''
    patchShebangs ${if useRuntimesBuild then "../../openmp" else ".."}/tools/archer/tests/deflake.bash
  '';

  __structuredAttrs = true;

  meta = llvm_meta // {
    homepage = "https://openmp.llvm.org/";
    description = "Support for the OpenMP language";
    longDescription = ''
      The OpenMP subproject of LLVM contains the components required to build an
      executable OpenMP program that are outside the compiler itself.
      Contains the code for the runtime library against which code compiled by
      "clang -fopenmp" must be linked before it can run and the library that
      supports offload to target devices.
    '';
    # "All of the code is dual licensed under the MIT license and the UIUC
    # License (a BSD-like license)":
    license = with lib.licenses; [
      mit
      ncsa
    ];
  };
})
