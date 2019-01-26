{ config, lib, pkgs, utils, ... }:

with lib;

let
  gcfg = config.services.duplicity-backup;

  mkSecurePathOption =
    { description
    , default
    }:
    mkOption {
      inherit description default;

      type = with types; either path string;
      apply = x: if builtins.typeOf x == "path" then toString x else x;
    };
in
{
  imports = [ ./duplicity-backup-common.nix ];

  options = {
    services.duplicity-backup.archives = mkOption {
      type = types.attrsOf (types.submodule ({ ... }:
        {
          options.target = mkSecurePathOption {
            description = ''
              The restoration target directory,
              useful for restoring a target directory to /mnt
            '';
            default = "";
          };
        }
      ));
    };
  };

  config = mkIf gcfg.enable {
    environment.systemPackages = mapAttrsToList (name: cfg: pkgs.writeScriptBin "duplicity-restore-${name}" ''
    for i in ${gcfg.envDir}/*; do
       source $i
    done

    ${concatStringsSep "\n" (map (directory: ''
      mkdir -p ${cfg.target + dirOf directory}

      ${pkgs.duplicity}/bin/duplicity \
        --archive-dir ${gcfg.cachedir} \
        --name ${name}-${baseNameOf directory} \
        --gpg-options "--homedir=${gcfg.pgpDir}" \
      '' + optionalString (!gcfg.usePassphrase) ''--encrypt-key "Duplicity Backup" \'' +
      ''
        ${concatStringsSep " " (map (v: "--exclude ${v}") cfg.excludes)} \
        ${concatStringsSep " " (map (v: "--include ${v}") cfg.includes)} \
        ${cfg.destination}/${baseNameOf directory} \
        ${cfg.target + directory}
      '') cfg.directories)}
  '') gcfg.archives;
  };
}
