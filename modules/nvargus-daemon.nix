{ pkgs, config, lib, ... }:

let
  inherit (lib) mkIf mkEnableOption;

  cfg = config.services.nvargus-daemon;
  nvidia-jetpack = pkgs.callPackage ../packages.nix {
    inherit config;
  };
in
{
  options.services.nvargus-daemon = {
    enable = mkEnableOption "Argus daemon";
  };

  config = lib.mkIf cfg.enable {
    systemd.services.nvargus-daemon = {
      enable = true;
      description = "Argus daemon";
      serviceConfig = {
        ExecStart = "${nvidia-jetpack.l4t-camera}/bin/nvargus-daemon";
        Restart = "on-failure";
        RestartSec = 4;
      };
      wantedBy = [ "multi-user.target" ];
    };
  };
}
