{
  lib,
  stdenv,
  # LLVM version closest to ROCm fork to override.
  # ROCm therock-10.1's llvm-project is LLVM 24; nixpkgs has no released
  # llvmPackages_24, so we use the 24.0.0-git snapshot (llvmPackages_git).
  llvmPackages_git,
  overrideCC,
  lndir,
  rocm-device-libs,
  fetchFromGitHub,
  runCommand,
  symlinkJoin,
  rdfind,
  zstd,
  gcc-unwrapped,
  glibc,
  libffi,
  libxml2,
  removeReferencesTo,
  # Build compilers and stdenv suitable for profiling
  # leaving compressed line tables (-g1 -gz) unstripped
  # TODO: Should also apply to downstream packages which use rocmClangStdenv?
  profilableStdenv ? false,
  # FIXME: proper two-stage bootstrap & PGO/BOLT/LTO
  # LTO currently disabled due to bitcode mismatch between the nixpkgs
  # llvmPackages_git and ROCm LLVM (24.0.0git). Uses new bitcode attr
  # 105 nocreateundeforpoison fails to link hipify.
  # Whether to use LTO when building the ROCm toolchain
  # Slows down this toolchain's build, for typical ROCm usecase
  # time saved building composable_kernel and other heavy packages
  # will outweight that. ~3-4% speedup multiplied by thousands
  # of corehours.
  withLto ? false,
  # whether rocm stdenv uses libcxx (clang c++ stdlib) instead of gcc stdlibc++
  withLibcxx ? false,
}:

let
  version = "10.1.0";
  # ROCm/TheRock two-component tag (therock-<major>.<minor>) for all monorepo/llvm sources
  srcTag = "therock-${lib.versions.majorMinor version}";
  # major version of this should be the clang version ROCm forked from
  rocmLlvmVersion = "24.0.0-rocm";
  # llvmPackages_base version should match rocmLlvmVersion
  # so libllvm's bitcode is compatible with the built toolchain
  # NOTE(rocm-10.1): llvmPackages_git is the 24.0.0-git snapshot (no released
  # llvmPackages_24 exists). Its check-all runs the PowerPC gold-plugin test
  # tools/gold/PowerPC/mtriple.ll, which needs host binutils with elf32ppc
  # emulation; stock nixpkgs x86_64 binutils is single-target, so that one test
  # fails (`unrecognised emulation mode: elf32ppc`). It is irrelevant to this
  # bootstrap scaffolding (used only to compile ROCm's own LLVM), so drop it —
  # mirrors the existing isAarch32 gold-test removals in common/llvm. Applied via
  # overrideScope so every base derivation on the ROCm build path (libllvm, and
  # lld/bintools which link against it) uses the fixed libllvm rather than the
  # check-failing one.
  skipPpcGoldTest = _final: prev: {
    libllvm = prev.libllvm.overrideAttrs (old: {
      postPatch = (old.postPatch or "") + ''
        rm -f test/tools/gold/PowerPC/mtriple.ll
      '';
    });
  };
  # Unfiltered base: keeps `.override` for llvmPackagesRocm (which rebuilds libllvm
  # from ROCm's own therock source, so never hits the base's check-failing libllvm).
  llvmPackages_base = llvmPackages_git;
  # Filtered variant for the bootstrap bintools below (its lld links against the
  # base libllvm, so it must be the fixed one or the check-failing drv is pulled in).
  llvmPackages_baseFiltered = llvmPackages_git.overrideScope skipPpcGoldTest;
  llvmPackagesNoBintools =
    (llvmPackages_git.override {
      bootBintools = null;
      bootBintoolsNoLibc = null;
    }).overrideScope
      skipPpcGoldTest;

  stdenvToBuildRocmLlvm =
    if withLibcxx then
      overrideCC llvmPackagesNoBintools.libcxxStdenv llvmPackagesNoBintools.clangUseLLVM
    else
      # oddly fuse-ld=lld fails without this override
      overrideCC llvmPackagesNoBintools.stdenv (
        llvmPackagesNoBintools.libstdcxxClang.override {
          inherit (llvmPackages_baseFiltered) bintools;
        }
      );

  gcc-include = runCommand "gcc-include" { } ''
    mkdir -p $out
    ln -s ${gcc-unwrapped}/include/ $out/
    ln -s ${gcc-unwrapped}/lib/ $out/
  '';

  disallowedRefsForToolchain = [
    stdenv.cc
    stdenv.cc.cc
    stdenv.cc.bintools
    gcc-unwrapped
    stdenvToBuildRocmLlvm
    stdenvToBuildRocmLlvm.cc
    stdenvToBuildRocmLlvm.cc.cc
  ];
  # A prefix for use as the GCC prefix when building rocm-toolchain
  gcc-prefix-headers = symlinkJoin {
    name = "gcc-prefix-headers";
    paths = [
      glibc.dev
      gcc-unwrapped.out
    ];
    disallowedRequisites = [
      glibc.dev
      gcc-unwrapped.out
    ];
    postBuild = ''
      rm -rf $out/{bin,libexec,nix-support,lib64,share,etc}
      rm $out/lib/gcc/x86_64-unknown-linux-gnu/*/plugin/include/auto-host.h

      mkdir /build/tmpout
      mv $out/* /build/tmpout
      cp -Lr --no-preserve=mode /build/tmpout/* $out/
      set -x
      versionedIncludePath="$(echo $out/include/c++/*/)"
      mv $versionedIncludePath/* $out/include/c++/
      rm -rf $versionedIncludePath/
    '';
  };
  gcc-prefix = symlinkJoin {
    name = "gcc-prefix";
    paths = [
      gcc-prefix-headers
      glibc
      gcc-unwrapped.lib
    ];
    disallowedRequisites = [
      glibc.dev
      gcc-unwrapped.out
    ];
    postBuild = ''
      rm -rf $out/{bin,libexec,nix-support,lib64,share,etc}
      rm $out/lib/ld-linux-x86-64.so.2
      ln -s $out $out/x86_64-unknown-linux-gnu
    '';
  };
  llvmSrc = fetchFromGitHub {
    owner = "ROCm";
    repo = "llvm-project";
    tag = srcTag;
    hash = "sha256-WkgJF0D4XsrWKbJO+vKow9CrNIKL/PqOXRwrB3ECsQE=";
  };
  llvmMajorVersion = lib.versions.major rocmLlvmVersion;
  # An llvmPackages (pkgs/development/compilers/llvm/) built from ROCm LLVM's source tree
  llvmPackagesRocm = llvmPackages_base.override (_old: {
    stdenv = stdenvToBuildRocmLlvm;

    # The base is now llvmPackages_git (a gitRelease). Null it out and set an empty
    # officialRelease instead: ROCm LLVM tracks official releases closely, so we want
    # the official (not git) patch-selection path, and common/default.nix asserts
    # exactly one of gitRelease/officialRelease is set. We override src/version below.
    gitRelease = null;
    officialRelease = { }; # Set but empty because we're overriding everything from it.
    # this version determines which patches are applied
    version = rocmLlvmVersion;
    src = llvmSrc;
    monorepoSrc = llvmSrc;
    doCheck = false;
  });
  refsToRemove = builtins.concatStringsSep " -t " [
    stdenvToBuildRocmLlvm
    stdenvToBuildRocmLlvm.cc
    stdenvToBuildRocmLlvm.cc.cc
    stdenv.cc
    stdenv.cc.cc
    stdenv.cc.bintools
  ];
  # Hacky way to avoid nixfmt indenting the entire scope body suggested by @emilazy
  overrideLlvmPackagesRocm =
    f:
    let
      overridenScope = llvmPackagesRocm.overrideScope (final: prev: f { inherit final prev; });
    in
    {
      inherit (overridenScope)
        # Expose only a limited set of packages that we care about for ROCm
        bintools
        compiler-rt
        compiler-rt-libc
        clang
        clang-unwrapped
        libcxx
        lld
        llvm
        rocm-toolchain
        rocmClangStdenv
        openmp
        ;
    };
  sysrootCompiler =
    {
      cc,
      name,
      paths,
      linkPaths,
    }:
    let
      linked = symlinkJoin { inherit name paths; };
    in
    runCommand name
      {
        pname = name;
        # If this is erroring, try why-depends --precise on the symlinkJoin of inputs to look for the problem
        # nix why-depends --precise .#rocmPackages.llvm.rocm-toolchain.linked /store/path/its/not/allowed
        outputChecks.out.disallowedRequisites = disallowedRefsForToolchain;
        passthru.linked = linked;
        inherit linkPaths;
        __structuredAttrs = true;
        # TODO(@LunNova): Try to use --sysroot with clang in its original location instead of
        # relying on copying the binary?
        # $clang/bin/clang++ --sysroot=$rocm-toolchain is not equivalent
        # to a clang copied to $rocm-toolchain/bin here, have not yet figured out why
      }
      ''
        mkdir -p $out/
        cp --reflink=auto -rL ${linked}/* $out/
        chmod -R +rw $out
        mkdir -p $out/usr
        ln -s $out/ $out/usr/local
        # we don't need mixed 32 bit, the presence of lib64 is used by LLVM to decide it's a multilib sysroot
        rm -rf $out/lib64
        rm -rf $out/lib/cmake $out/lib/lib*.a
        mkdir -p $out/lib/clang/${llvmMajorVersion}/lib/linux/
        ln -s $out/lib/linux/libclang_rt.* $out/lib/clang/${llvmMajorVersion}/lib/linux/
        mkdir -p $out/lib/clang/${llvmMajorVersion}/lib/${stdenv.hostPlatform.config}/
        for f in $out/lib/linux/*-${stdenv.hostPlatform.parsed.cpu.name}.*; do
          [ -e "$f" ] || continue
          base="$(basename "$f" | sed 's/-${stdenv.hostPlatform.parsed.cpu.name}\././')"
          ln -sf "$f" "$out/lib/clang/${llvmMajorVersion}/lib/${stdenv.hostPlatform.config}/$base"
        done

        find $out -type f -exec sed -i "s|${cc.out}|$out|g" {} +
        find $out -type f -exec sed -i "s|${cc.dev}|$out|g" {} +

        # Clang config file: redirect resource dir to the sysroot (where compiler-rt
        # lives) and set GCC install prefix for header/library search
        #
        # NOTE(rocm-10.1): LLVM 24's clang-linker-wrapper links libzstd when it
        # combines offloaded device images with compression (clang defaults
        # --offload-compress on, which rocBLAS/CK/etc. also request via
        # BUILD_OFFLOAD_COMPRESS). Under the LLVM-23 base the wrapper did not, so
        # nothing provided -lzstd and the sandboxed link (e.g. rocm-cmake's
        # `rocm_check_target_ids` HIP probe, `clang++ -xhip --offload-arch=… --hip-link`)
        # failed with "clang-linker-wrapper: error: unable to find library -lzstd",
        # breaking the whole library fleet (rocblas → hipblas → …). Put zstd's lib dir
        # on the toolchain's default link path so every rocmClangStdenv consumer finds
        # it, matching the zstd the toolchain's own LLVM was linked against.
        cat > $out/bin/${stdenv.hostPlatform.config}.cfg <<CFG
        -resource-dir=$out/lib/clang/${llvmMajorVersion}
        -L${zstd.out}/lib
        ${lib.optionalString (!withLibcxx) "--gcc-toolchain=${gcc-prefix}"}
        CFG

        ${lib.getExe rdfind} -makesymlinks true ${
          builtins.concatStringsSep " " (map (x: "${x}/lib") paths)
        } $out/ # create links *within* the sysroot to save space

        for i in "''${linkPaths[@]}"; do
          ${lib.getExe lndir} -silent $i $out
        done

        echo 'export CC=clang' >> $out/nix-support/setup-hook
        echo 'export CXX=clang++' >> $out/nix-support/setup-hook
      '';
  tablegenUsage = x: !(lib.strings.hasInfix "llvm-tblgen" x);
  llvmTargetsFlag = "-DLLVM_TARGETS_TO_BUILD=AMDGPU;${
    {
      "x86_64" = "X86";
      "aarch64" = "AArch64";
    }
    .${stdenv.targetPlatform.parsed.cpu.name}
      or (throw "Unsupported CPU architecture: ${stdenv.targetPlatform.parsed.cpu.name}")
  }";
  llvmMeta = {
    # TODO(@LunNova): it would be nice to support aarch64 for rocmPackages
    platforms = [ "x86_64-linux" ];
  };
  # TODO(@LunNova): Some of this might be worth supporting in llvmPackages, dropping from here
  commonCmakeFlags = [
    llvmTargetsFlag
    # Compression support is required for compressed offload kernels
    # Set FORCE_ON so that failure to find the compression lib will be a build error
    (lib.cmakeFeature "LLVM_ENABLE_ZSTD" "FORCE_ON")
    # required for threaded ThinLTO to work
    (lib.cmakeBool "LLVM_ENABLE_THREADS" true)
    # third-party/benchmark is broken in rocm-7.2.0
    # error: '__COUNTER__' is a C2y extension [-Werror,-Wc2y-extensions]
    (lib.cmakeBool "LLVM_INCLUDE_BENCHMARKS" false)
    # LLVM tries to call git to embed VCS info if FORCE_VC_ aren't set
    (lib.cmakeFeature "LLVM_FORCE_VC_REVISION" srcTag)
    (lib.cmakeFeature "LLVM_FORCE_VC_REPOSITORY" "https://github.com/ROCm/llvm-project")
    (lib.cmakeFeature "LLVM_VERSION_SUFFIX" "")
    (lib.cmakeBool "LLVM_ENABLE_LIBCXX" withLibcxx)
    (lib.cmakeFeature "CLANG_DEFAULT_CXX_STDLIB" (if withLibcxx then "libc++" else "libstdc++"))
    (lib.cmakeFeature "CLANG_VENDOR" "nixpkgs-AMD")
    (lib.cmakeFeature "CLANG_REPOSITORY_STRING" "https://github.com/ROCm/llvm-project/tree/${srcTag}")
  ]
  ++ lib.optionals withLibcxx [
    (lib.cmakeFeature "CLANG_DEFAULT_RTLIB" "compiler-rt")
  ]
  ++ lib.optionals withLto [
    (lib.cmakeBool "CMAKE_INTERPROCEDURAL_OPTIMIZATION" true)
    (lib.cmakeBool "LLVM_ENABLE_FATLTO" false)
  ]
  ++ lib.optionals (withLto && stdenvToBuildRocmLlvm.cc.isClang) [
    (lib.cmakeFeature "LLVM_ENABLE_LTO" "FULL")
    (lib.cmakeFeature "LLVM_USE_LINKER" "lld")
  ];

  llvmExtraCflags = lib.concatStringsSep " " (
    lib.optionals (stdenv.hostPlatform.system == "x86_64-linux") [
      # Unprincipled decision to build x86_64 ROCm clang for at least skylake and tune for zen3+
      # In practice building the ROCm package set with anything earlier than zen3 is annoying
      # and earlier than skylake is implausible due to too few cores and too little RAM
      # Speeds up composable_kernel builds by ~4%
      # If this causes trouble in practice we can drop this. Set since 2025-03-24.
      "-march=skylake"
      "-mtune=znver3"
    ]
    ++ lib.optionals profilableStdenv [
      # compressed line only debug info for profiling
      "-gz"
      "-g1"
    ]
  );
  inherit (llvmPackagesRocm) libcxx;
in
overrideLlvmPackagesRocm (s: {
  libllvm = (s.prev.libllvm.override { }).overrideAttrs (old: {
    patches = [
      # NOTE(rocm-10): dropped 3 select-ptr-combine backports (llvm ac27b24 / d3c3c6b /
      # 0e1cb2d) — already upstream in LLVM 23+, they no longer apply and are unneeded.
      # NOTE(rocm-10.1): this ROCm LLVM is now 24-based (therock-10.1, built on the
      # nixpkgs llvmPackages_git 24.0.0-git snapshot). `++ old.patches` below inherits
      # llvmPackages_git's libllvm patch set rather than llvmPackages_23's; the
      # arm64e_x1 bridge group (nixpkgs#564039, "can be removed when upgrading to rocm
      # 10") is already gone from the 24 base, so nothing to drop there anymore.
    ]
    ++ old.patches
    ++ [
      ./perf-increase-namestring-size.patch
      # NOTE(rocm-10): dropped 3 v64i8 VBMI shuffle backports (llvm PRs 182832/182852/183109,
      # nixpkgs#497745) — the codegen fix is already upstream in LLVM 23 (patch applies reversed).
      # TODO: consider reapplying "Don't include aliases in RegisterClassInfo::IgnoreCSRForAllocOrder"
      # it was reverted as it's a pessimization for non-GPU archs, but this compiler
      # is used mostly for amdgpu
    ];
    dontStrip = profilableStdenv;
    hardeningDisable = [ "all" ];
    nativeBuildInputs = old.nativeBuildInputs ++ [ removeReferencesTo ];
    buildInputs = old.buildInputs ++ [
      zstd
    ];
    preFixup = ''
      moveToOutput "lib/lib*.a" "$dev"
      moveToOutput "lib/cmake" "$dev"
      sed -Ei "s|$lib/lib/(lib[^/]*)\.a|$dev/lib/\1.a|g" $dev/lib/cmake/llvm/*.cmake
    '';
    env = (old.env or { }) // {
      NIX_CFLAGS_COMPILE = "${(old.env or { }).NIX_CFLAGS_COMPILE or ""} ${llvmExtraCflags}";
    };
    cmakeFlags = (builtins.filter tablegenUsage old.cmakeFlags) ++ commonCmakeFlags;
    # Ensure we don't leak refs to compiler that was used to bootstrap this LLVM
    disallowedReferences = (old.disallowedReferences or [ ]) ++ disallowedRefsForToolchain;
    postFixup = ''
      ${old.postFixup or ""}
      find $lib -type f -exec remove-references-to -t ${refsToRemove} {} +
    '';
    meta = old.meta // llvmMeta;
  });
  lld =
    (s.prev.lld.override {
    }).overrideAttrs
      (old: {
        dontStrip = profilableStdenv;
        hardeningDisable = [ "all" ];
        nativeBuildInputs = old.nativeBuildInputs ++ [
          removeReferencesTo
        ];
        buildInputs = old.buildInputs ++ [
          zstd
        ];
        env = (old.env or { }) // {
          NIX_CFLAGS_COMPILE = "${(old.env or { }).NIX_CFLAGS_COMPILE or ""} ${llvmExtraCflags}";
        };
        cmakeFlags = (builtins.filter tablegenUsage old.cmakeFlags) ++ commonCmakeFlags;
        # Ensure we don't leak refs to compiler that was used to bootstrap this LLVM
        disallowedReferences = (old.disallowedReferences or [ ]) ++ disallowedRefsForToolchain;
        postFixup = ''
          ${old.postFixup or ""}
          find $lib -type f -exec remove-references-to -t ${refsToRemove} {} +
        '';
        meta = old.meta // llvmMeta;
      });
  clang-unwrapped = (
    (s.prev.clang-unwrapped.override {
      enableClangToolsExtra = false;
    }).overrideAttrs
      (old: {
        passthru = old.passthru // {
          inherit gcc-prefix;
        };
        # NOTE(rocm-10): dropped clang-scan-build-py-configurable.patch (llvm PR
        # #172727) — the scan-build-py install option is upstream in LLVM 23.
        # NOTE(rocm-10.1): rebased the GZGavinZhao GetBundleIDsInFile patch as a
        # local diff (clang-add-getbundleidsinfile.diff). The rocm-comgr ISA-compat
        # patch (GZGavinZhao 2c1e44fc) calls the 3-arg set-returning
        # OffloadBundler::GetBundleIDsInFile; therock-10.1 provides only the 2-arg
        # print-only ListBundleIDsInFile, so comgr still needs this public wrapper.
        # LLVM 24 rewrote ListBundleIDsInFile (multi-bundle/compressed loop) and
        # dropped the <vector> include the upstream fetchpatch anchored hunk #1 on,
        # so that fetchpatch no longer applied. The functionality is intact —
        # therock-10.1 keeps FileHandler::getBundleIDs(MemoryBuffer&,
        # std::set<StringRef>&) — so the rebase just re-anchors the three additive
        # hunks and uses 24's raw_ostream* decompress() form (which is why the
        # separate decompress postPatch below is no longer needed).
        # NOTE(rocm-10.1): dropped clang-log-jobs.diff. It inserted per-job
        # "Job completed" logging into Compilation::ExecuteJobs to keep terminal
        # output flowing during long multi-arch offload compiles. LLVM 24 rewrote
        # ExecuteJobs around native parallel offload job groups
        # (tryExecuteParallelOffloadJobGroup, indexed `for (size_t I …)` over
        # getJobs()), so the old range-for loop body the patch targeted no longer
        # exists (2/3 hunks fail). The patch is cosmetic (CI-progress only) and the
        # new parallel-offload execution partly supersedes it, so drop rather than
        # speculatively rebase into the restructured loop.
        patches = old.patches ++ [
          # Never add FHS include paths
          ./clang-bodge-ignore-systemwide-incls.diff
          ./opt-offload-compress-on-by-default.patch
          ./perf-shorten-gcclib-include-paths.patch
          # Adds the 3-arg set-returning OffloadBundler::GetBundleIDsInFile that the
          # rocm-comgr ISA-compat patch depends on (see NOTE above).
          ./clang-add-getbundleidsinfile.diff
        ];
        # NOTE(rocm-10.1): dropped the CompressedOffloadBundle::decompress postPatch.
        # It only fixed the call site added by the now-removed GetBundleIDsInFile
        # patch; therock-10.1's own call sites already pass the raw_ostream* form
        # (`decompress(**CodeOrErr, Verbose ? &llvm::errs() : nullptr)`), so the old
        # `--replace-fail` on the bool form would hard-fail the build.
        # NOTE(rocm-10.1): dropped the EmissaryIds postUnpack symlink. It worked
        # around CGEmitEmissaryExec.cpp including ../../openmp/device/include/
        # EmissaryIds.h, but therock-10.1 removed both that file and the header
        # (upstream llvm/llvm-project#175265 restructured the Emissary APIs), so the
        # standalone-clang-build breakage it patched no longer exists.
        hardeningDisable = [ "all" ];
        nativeBuildInputs = old.nativeBuildInputs ++ [
          removeReferencesTo
        ];
        buildInputs = old.buildInputs ++ [
          zstd
        ];
        env = (old.env or { }) // {
          NIX_CFLAGS_COMPILE = "${(old.env or { }).NIX_CFLAGS_COMPILE or ""} ${llvmExtraCflags}";
        };
        dontStrip = profilableStdenv;
        # Ensure we don't leak refs to compiler that was used to bootstrap this LLVM
        disallowedReferences = (old.disallowedReferences or [ ]) ++ disallowedRefsForToolchain;
        # Enable structured attrs for separateDebugInfo, because it is required with disallowedReferences set
        __structuredAttrs = true;
        # https://github.com/llvm/llvm-project/blob/6976deebafa8e7de993ce159aa6b82c0e7089313/clang/cmake/caches/DistributionExample-stage2.cmake#L9-L11
        cmakeFlags =
          # TODO: Remove in followup, tblgen now works correctly but would rebuild
          (builtins.filter tablegenUsage old.cmakeFlags) ++ commonCmakeFlags;
        preFixup = ''
          ${toString old.preFixup or ""}
          moveToOutput "lib/lib*.a" "$dev"
          moveToOutput "lib/cmake" "$dev"
          mkdir -p $dev/lib/clang/
          ln -s $lib/lib/clang/${llvmMajorVersion} $dev/lib/clang/
          sed -Ei "s|$lib/lib/(lib[^/]*)\.a|$dev/lib/\1.a|g" $dev/lib/cmake/clang/*.cmake
        '';
        postFixup = ''
          ${toString old.postFixup or ""}
          find $lib -type f -exec remove-references-to -t ${refsToRemove} {} +
          find $dev -type f -exec remove-references-to -t ${refsToRemove} {} +
        '';
        meta = old.meta // llvmMeta;
      })
  );
  # A clang that understands standard include searching in a GNU sysroot and will put GPU libs in include path
  # in the right order
  # and expects its libc to be in the sysroot
  rocm-toolchain =
    with s.final;
    (sysrootCompiler {
      cc = clang-unwrapped;
      name = "rocm-toolchain";
      paths = [
        clang-unwrapped.out
        clang-unwrapped.lib
        bintools.out
        compiler-rt.out
        openmp.out
        openmp.dev
      ]
      ++ lib.optionals withLibcxx [
        libcxx
      ]
      ++ lib.optionals (!withLibcxx) [
        glibc
        glibc.dev
      ];
      linkPaths = [
        bintools.bintools.out
      ]
      ++ lib.optionals (!withLibcxx) [
        gcc-include.out
      ];
    })
    // {
      version = llvmMajorVersion;
      cc = rocm-toolchain;
      libllvm = llvm;
      isClang = true;
      isGNU = false;
    };
  compiler-rt-libc = s.prev.compiler-rt-libc.overrideAttrs (old: {
    meta = old.meta // llvmMeta;
  });
  compiler-rt = s.final.compiler-rt-libc;
  clang = s.final.rocm-toolchain;

  rocmClangStdenv = with s.final; overrideCC (if withLibcxx then libcxxStdenv else stdenv) clang;

  # Projects
  openmp =
    with s.final;
    (llvmPackagesRocm.openmp.override {
      llvm = llvm;
      clang-unwrapped = clang-unwrapped;
    }).overrideAttrs
      (old: {
        disallowedReferences = (old.disallowedReferences or [ ]) ++ disallowedRefsForToolchain;
        nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [
          removeReferencesTo
        ];
        cmakeFlags =
          old.cmakeFlags
          ++ commonCmakeFlags
          ++ [
            "-DDEVICELIBS_ROOT=${rocm-device-libs.src}"
            # OMPD support is broken in ROCm 6.3+ Haven't investigated why.
            "-DLIBOMP_OMPD_SUPPORT:BOOL=FALSE"
            "-DLIBOMP_OMPD_GDB_SUPPORT:BOOL=FALSE"
          ];
        buildInputs = old.buildInputs ++ [
          clang-unwrapped
          zstd
          libxml2
          libffi
        ];
        postFixup = ''
          ${old.postFixup or ""}
          ln -s $out/lib/libomp.so $dev/lib/libomp.so
        '';
      });
  # AMD has a separate MLIR impl which we package under rocmPackages.rocmlir
  # It would be an error to rely on the original mlir package from this scope
  mlir = null;
})
