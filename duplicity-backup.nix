{ config, lib, pkgs, utils, ... }:

with lib;

let
  gcfg = config.services.duplicity-backup;
in
{
  imports = [ ./duplicity-backup-common.nix
              ./duplicity-backup-backup.nix
              ./duplicity-backup-restore.nix ];

  config = mkIf gcfg.enable {
    warnings = concatLists (mapAttrsToList (name: cfg:
        lib.optional (length cfg.directories > 1) "Multiple directories is currently beta"
      ) gcfg.archives);

    assertions =
      (mapAttrsToList (name: cfg:
        { assertion = cfg.directories != [];
          message = "Must specify paths for duplicity to back up";
        }) gcfg.archives);
  };
}
