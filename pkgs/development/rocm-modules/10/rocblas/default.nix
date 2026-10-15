{
  lib,
  clr,
  rocblas_base,
  buildTensile ? true,
  buildTests ? true,
  buildBenchmarks ? true,
  tensileSepArch ? true,
  tensileLazyLib ? true,
  withHipBlasLt ? true,
  gpuTargets ? (clr.localGpuTargets or clr.gpuTargets),
  ...
}@args:

let
  base = rocblas_base.override (
    builtins.removeAttrs args [ "rocblas_base" ]
    // {
      inherit
        buildTensile
        buildTests
        buildBenchmarks
        tensileSepArch
        tensileLazyLib
        withHipBlasLt
        gpuTargets
        ;
    }
  );
  archList = gpuTargets;
  headArch = lib.head archList;
  tailArchs = lib.drop 1 archList;
  shardTensile = buildTensile && tensileSepArch && tensileLazyLib && lib.length archList > 1;

  # Each shard supplies a self-contained lazy Tensile library for one architecture.
  # Shared build dependencies can still invalidate shards for unchanged targets.
  mkTensileShard =
    arch:
    (base.override {
      gpuTargets = [ arch ];
      buildTests = false;
      buildBenchmarks = false;
    }).overrideAttrs
      (old: {
        pname = "rocblas-tensile-${arch}";
        meta = (unbreak old).meta;
        outputs = [ "out" ];
        doCheck = false;
        postInstall = (old.postInstall or "") + ''
          keep="$(mktemp -d)"
          cp -r "$out/lib/rocblas/library" "$keep/library"
          rm -rf "$out"/*
          mkdir -p "$out/lib/rocblas"
          mv "$keep/library" "$out/lib/rocblas/library"
          rm -rf "$keep"
        '';
      });

  tensileShards = map mkTensileShard tailArchs;

  # The base is hidden from Hydra; the configured public builds are usable.
  unbreak = old: {
    meta = old.meta // {
      broken = false;
    };
  };
in

# Other Tensile layouts cannot be merged by copying architecture directories.
if !shardTensile then
  base.overrideAttrs unbreak
else
  (base.override {
    gpuTargets = [ headArch ];
  }).overrideAttrs
    (old: {
      pname = "rocblas${clr.gpuArchSuffix}";
      meta = (unbreak old).meta;

      inherit tensileShards;
      disallowedReferences = tensileShards;

      # Merge the lazy libraries and remove embedded shard paths from ELF metadata.
      # disallowedReferences prevents private shards from entering the runtime closure.
      postInstall = (old.postInstall or "") + ''
        for shard in $tensileShards; do
          cp -r --no-preserve=mode "$shard/lib/rocblas/library/"* "$out/lib/rocblas/library/"
        done
        for shard in $tensileShards; do
          find "$out/lib/rocblas/library" -type f -exec remove-references-to -t "$shard" {} +
        done
      '';

      passthru = (old.passthru or { }) // {
        amdgpu_targets = lib.concatStringsSep ";" archList;
        inherit tensileShards;
      };
    })
