{ config, pkgs, lib ? pkgs.lib, ... }:
# Construct nvidia-jetpack packages without using nixpkgs overlays
let
  cfg = config.hardware.nvidia-jetpack;

  # The overlay needs a real fixpoint these days (final._cuda is extended
  # and the versioned cudaPackages_* sets reference each other through
  # final), so instantiate it with pkgs.extend instead of calling it as a
  # plain function. This stays local: the user's nixpkgs is untouched.

  # Target platform (aarch64) nvidia-jetpack
  jetpackPkgs = pkgs.extend (import ./overlay.nix);
  nvidia-jetpack-base = jetpackPkgs."nvidia-jetpack${cfg.majorVersion}";

  # Build platform (x86_64) nvidia-jetpack for flash-tools
  buildPkgs = pkgs.pkgsBuildBuild.extend (import ./overlay.nix);
  nvidia-jetpack-build = buildPkgs."nvidia-jetpack${cfg.majorVersion}";

  overlay2 =
    (import ./overlay-with-config.nix) config nvidia-jetpack-base nvidia-jetpack-build jetpackPkgs
      jetpackPkgs;
in
overlay2.nvidia-jetpack
