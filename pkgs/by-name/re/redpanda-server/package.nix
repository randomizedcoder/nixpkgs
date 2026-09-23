{
  lib,
  stdenv,
  fetchFromGitHub,
  applyPatches,
  callPackage,
  bash,
  bazel_9,
  # Matches the clang major upstream ships with this release; nixpkgs'
  # llvmPackages_23 miscompiled the broker (cluster bootstrap aborts).
  llvmPackages_22,
  python3,
  go,
  perl,
  autoconf,
  automake,
  libtool,
  m4,
  pkg-config,
  cmake,
  ninja,
  which,
  openssl,
  krb5,
  c-ares,
  valgrind,
  xfsprogs,
  versionCheckHook,
  nix-update-script,
  nixosTests,
}:

let
  version = "26.2.2";

  # Pinned Bazel Central Registry snapshot so module resolution is
  # reproducible and works offline. Must contain every module version
  # referenced by MODULE.bazel.
  registry = fetchFromGitHub {
    owner = "bazelbuild";
    repo = "bazel-central-registry";
    rev = "3f8851eb6c2b42e1aa6addd32dfea14662202f3a";
    hash = "sha256-PpfV5+cHvuWX6gi2zsK9YBPP2G6JziNU3UD8Y1cYxew=";
  };

  wasmtime-c-api = callPackage ./wasmtime-c-api.nix { };

  # Upstream links with -fuse-ld=lld. Bazel runs actions with a minimal
  # PATH, and the cc-wrapper only puts its own bintools on PATH, so pair the
  # clang wrapper with LLVM's bintools to make ld.lld reachable.
  clang = llvmPackages_22.libcxxClang.override {
    bintools = llvmPackages_22.bintools;
  };

  # Code generators (kafka schemata, rpc compiler) run under this interpreter.
  python = python3.withPackages (ps: [
    ps.jinja2
    ps.jsonschema
  ]);

  # Libraries taken from nixpkgs instead of upstream's rules_foreign_cc
  # builds. nix-local-repositories.patch points Bazel at nix_deps/<name>.
  systemLibs = {
    inherit openssl krb5 c-ares;
  };

  # nix_deps/<name>/{include,lib} is the layout the *-nix.BUILD files in the
  # patch expect.
  linkSystemLib = name: pkg: ''
    mkdir -p nix_deps/${name}
    ln -s ${lib.getDev pkg}/include nix_deps/${name}/include
    ln -s ${lib.getLib pkg}/lib nix_deps/${name}/lib
  '';

  # Shared libraries the installed binary loads. Bazel's cc_import records no
  # rpath for prebuilt libraries and its own $ORIGIN/_solib_* entries dangle
  # once the binary leaves bazel-bin, so the rpath is set outright in
  # postFixup.
  runtimeLibs = lib.attrValues systemLibs ++ [
    llvmPackages_22.libcxx
    stdenv.cc.cc.lib
    stdenv.cc.libc
  ];

  src = applyPatches {
    name = "redpanda-${version}-source";
    src = fetchFromGitHub {
      owner = "redpanda-data";
      repo = "redpanda";
      tag = "v${version}";
      hash = "sha256-07jGQv07TlnxhBmMOiP8rFgviDTVx0tcACqvvfKl8Fg=";
    };

    patches = [
      ./nix-toolchains.patch
      ./nix-local-repositories.patch
    ];

    postPatch = ''
      # Wrapper that Bazel runs automatically; it only insists on bazelisk.
      rm tools/bazel

      substituteInPlace MODULE.bazel \
        --replace-fail "@nixPython@" "${python}" \
        --replace-fail "@nixBash@" "${lib.getExe bash}"

      # Stamp the release version without needing git metadata
      # (--config=stamp reads it from .git).
      substituteInPlace src/v/version/BUILD \
        --replace-fail "STABLE_GIT_LATEST_TAG v0.0.0-dev" "STABLE_GIT_LATEST_TAG v${version}"

      ${lib.concatStrings (lib.mapAttrsToList linkSystemLib systemLibs)}
      # The in-tree openssl-fips build also runs the openssl binary and reads
      # its configuration.
      ln -s ${lib.getBin openssl}/bin nix_deps/openssl/bin
      ln -s ${lib.getLib openssl}/etc nix_deps/openssl/etc
      mkdir -p nix_deps/wasmtime
      ln -s ${wasmtime-c-api.dev}/include nix_deps/wasmtime/include
      ln -s ${wasmtime-c-api}/lib nix_deps/wasmtime/lib
    '';
  };
in
bazel_9.buildBazelPackage {
  pname = "redpanda-server";
  # The builder takes name rather than deriving it from pname and version.
  name = "redpanda-server-${version}";
  inherit version src registry;

  strictDeps = true;
  __structuredAttrs = true;

  nativeBuildInputs = [
    clang
    python
    go
    perl
    autoconf
    automake
    libtool
    m4
    pkg-config
    cmake
    ninja
    which
  ];

  buildInputs = lib.attrValues systemLibs ++ [
    llvmPackages_22.libcxx
    # Seastar's reactor includes the valgrind client-request and XFS ioctl
    # headers unconditionally; only the headers are used.
    valgrind
    xfsprogs
  ];

  # Bazel

  bazel = bazel_9;
  targets = [ "//src/v/redpanda:redpanda" ];

  commandArgs = [
    # Autodetected host toolchain: the clang wrapper from nativeBuildInputs.
    # The stdenv setup hook exports CC=gcc after `env` is applied, so tell
    # the toolchain autoconfiguration directly which compiler to use.
    "--config=system-clang"
    "--repo_env=CC=clang"
    "--repo_env=CXX=clang++"
    # Bazel's linux-sandbox remounts /sys whenever an action blocks network
    # access (rules_foreign_cc always does), and the Nix sandbox has no
    # /sys. The process-wrapper sandbox keeps actions hermetic without
    # namespaces; the Nix sandbox already has no network.
    "--spawn_strategy=processwrapper-sandbox"
    # Upstream's shipped configuration: -c opt plus hardening, seastar
    # stack guards off.
    "--config=release"
    "--host_linkopt=-stdlib=libc++"
    "--host_linkopt=--unwindlib=libgcc"
    "--verbose_failures"
  ]
  # Bazel strips the environment of every action. Pass through PATH, so
  # actions find the tools from nativeBuildInputs, and the variables the
  # nixpkgs compiler wrappers read, so the -L/-isystem flags of buildInputs
  # and the hardening flags apply as in any other nixpkgs build.
  ++
    lib.concatMap
      (v: [
        "--action_env=${v}"
        "--host_action_env=${v}"
      ])
      [
        "PATH"
        "NIX_CFLAGS_COMPILE"
        "NIX_LDFLAGS"
        "NIX_HARDENING_ENABLE"
        "NIX_CC_WRAPPER_TARGET_HOST_${clang.suffixSalt}"
        "NIX_BINTOOLS_WRAPPER_TARGET_HOST_${clang.suffixSalt}"
      ];

  # The final build must resolve everything from the repository cache; fail
  # loudly on a cache miss instead of relying on the sandbox having no
  # network.
  buildCommandArgs = [ "--repository_disable_download" ];

  bazelRepoCacheFOD = {
    # The repository cache differs per system: rules_buf downloads prebuilt
    # buf and protoc-gen-buf-* binaries for the host architecture.
    outputHash =
      {
        x86_64-linux = "sha256-E0L7/YfiUina/ndr6G+i+fe7r/PjAscFbb+pGADZWeo=";
        aarch64-linux = "sha256-Rx2q7XLRAdfsW4Pk8q8Ve/Q2Z0DO23wkZl9lzx5lxNQ=";
      }
      .${stdenv.hostPlatform.system}
        or (throw "redpanda-server: no repository cache hash for ${stdenv.hostPlatform.system}");
    outputHashAlgo = "sha256";
  };

  # The bazel wrapper script runs the release named in the tree's
  # .bazelversion (9.1.0); point it at the nixpkgs release instead.
  env.USE_BAZEL_VERSION = bazel_9.version;

  # cmake is only needed on PATH for rules_foreign_cc; there is no top-level
  # CMakeLists.txt for the nixpkgs hook to configure.
  dontUseCmakeConfigure = true;

  # Upstream sets the libc++ hardening mode itself; the wrapper's predefine
  # would only trigger -Wmacro-redefined under -Werror.
  hardeningDisable = [ "libcxxhardeningfast" ];

  # Install and checks

  installPhase = ''
    runHook preInstall

    install -Dm755 bazel-bin/src/v/redpanda/redpanda $out/bin/redpanda
    install -Dm644 conf/redpanda.yaml $out/etc/redpanda/redpanda.yaml

    runHook postInstall
  '';

  postFixup = ''
    patchelf --set-rpath "${lib.makeLibraryPath runtimeLibs}" $out/bin/redpanda
  '';

  nativeInstallCheckInputs = [ versionCheckHook ];
  doInstallCheck = true;

  # Guard against the compiler wrapper leaking into the closure through the
  # action environment passthrough above.
  disallowedRequisites = [ clang ];

  # ~8,600 Bazel actions, 3,400 of them clang; 45 min on 24 cores.
  requiredSystemFeatures = [ "big-parallel" ];

  passthru = {
    inherit wasmtime-c-api;
    tests.nixos = nixosTests.redpanda-server;
    # The repository cache hash and the BCR pin must be refreshed by hand
    # after a version bump.
    updateScript = nix-update-script {
      extraArgs = [
        "--version-regex"
        "^v(\\d+\\.\\d+\\.\\d+)$"
      ];
    };
  };

  meta = {
    description = "Kafka-compatible streaming data platform";
    homepage = "https://redpanda.com/";
    changelog = "https://github.com/redpanda-data/redpanda/releases/tag/v${version}";
    # Core is BSL 1.1 (converts to Apache-2.0 after four years); parts of the
    # tree are Apache-2.0. Enterprise features (cloud topics, iceberg, tiered
    # storage, ...) are under the Redpanda Community License; they are
    # compiled into the binary and need a license key at runtime.
    license = with lib.licenses; [
      bsl11
      rcl
      asl20
    ];
    maintainers = with lib.maintainers; [ randomizedcoder ];
    # aarch64-linux builds and passes the NixOS test as well, but needs
    # llvmPackages_22.compiler-rt-no-libc fixed first (submitted separately);
    # it is enabled once that fix has landed.
    platforms = [ "x86_64-linux" ];
    mainProgram = "redpanda";
  };
}
