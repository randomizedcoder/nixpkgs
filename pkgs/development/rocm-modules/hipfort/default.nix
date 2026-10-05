{
  lib,
  stdenv,
  fetchFromGitHub,
  rocmUpdateScript,
  cmake,
  rocm-cmake,
  gfortran,
}:

stdenv.mkDerivation (finalAttrs: {
  pname = "hipfort";
  version = "10.0.0";

  src = fetchFromGitHub {
    owner = "ROCm";
    repo = "hipfort";
    tag = "rocm-${finalAttrs.version}";
    hash = "sha256-qyBz+zFwJOjjmKFKKw9Cxo7kDDXlMFhPhuJIYykPpDs=";
  };

  __structuredAttrs = true;
  strictDeps = true;

  nativeBuildInputs = [
    cmake
    gfortran
  ];

  buildInputs = [
    rocm-cmake
  ];

  cmakeFlags = [
    (lib.cmakeFeature "HIPFORT_COMPILER" "${gfortran}/bin/gfortran")
    (lib.cmakeFeature "HIPFORT_AR" "${gfortran.cc}/bin/gcc-ar")
    (lib.cmakeFeature "HIPFORT_RANLIB" "${gfortran.cc}/bin/gcc-ranlib")
    # Manually define CMAKE_INSTALL_<DIR>
    # See: https://github.com/NixOS/nixpkgs/pull/197838
    (lib.cmakeFeature "CMAKE_INSTALL_BINDIR" "bin")
    (lib.cmakeFeature "CMAKE_INSTALL_LIBDIR" "lib")
    (lib.cmakeFeature "CMAKE_INSTALL_INCLUDEDIR" "include")
  ];

  # NOTE(rocm-10): hipfort 10.0.0 dropped the bin/ wrapper scripts (hipfc,
  # mymcpu) entirely — it is now a pure Fortran interface library (lib/, cmake/,
  # include/), so the old bin/ postPatch is obsolete and no longer applies.

  passthru.updateScript = rocmUpdateScript { inherit finalAttrs; };

  meta = {
    description = "Fortran interfaces for ROCm libraries";
    homepage = "https://github.com/ROCm/hipfort";
    changelog = "https://github.com/ROCm/hipfort/releases/tag/${finalAttrs.src.tag}";
    license = lib.licenses.mit; # mitx11
    teams = [ lib.teams.rocm ];
    platforms = lib.platforms.linux;
  };
})
