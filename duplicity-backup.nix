{ config, lib, pkgs, utils, ... }:

with lib;

{
  imports = [ ./duplicity-backup-common.nix
              ./duplicity-backup-backup.nix
              ./duplicity-backup-restore.nix ];
}
