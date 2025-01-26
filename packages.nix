{ config, pkgs, ... }:
# hack to avoid using overlays
let
  overlay1 = import ./overlay.nix pkgs pkgs;
  overlay2 = (import ./overlay-with-config.nix) config overlay1.nvidia-jetpack pkgs pkgs;
in
overlay2.nvidia-jetpack
