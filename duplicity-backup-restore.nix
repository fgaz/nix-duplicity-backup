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
    services.duplicity-backup.enableRestore = mkEnableOption "periodic duplicity backups restore tools";

    services.duplicity-backup.target = mkSecurePathOption {
      description = ''
        The restoration target directory,
        useful for restoring a target directory to /mnt
      '';
      default = "";
    };

    services.duplicity-backup.archives = mkOption {
      type = types.attrsOf (types.submodule ({ name, config, ... }:
        {
          options = {
            target = mkSecurePathOption {
              description = ''
                The restoration target directory,
                useful for restoring a target directory to /mnt
              '';
              default = gcfg.target;
            };

            enableForce = mkOption {
              type = types.bool;
              default = false;
            };

            script = mkOption {
              type = types.path;
              readOnly = true;
            };
          };

          config.script = pkgs.writeScriptBin "duplicity-restore-${name}" (''
            for i in ${gcfg.envDir}/*; do
               source $i
            done

            mkdir -p ${config.target + dirOf config.directory}

            ${pkgs.duplicity}/bin/duplicity \
              --archive-dir ${gcfg.cacheDir} \
              --name ${name} \
              --gpg-options "--homedir=${gcfg.pgpDir}" \
          '' + optionalString (config.enableForce) ''--force \
          '' + optionalString (!gcfg.usePassphrase) ''--encrypt-key "Duplicity Backup" \'' + ''
              ${config.destination} \
              ${config.target + config.directory}
          '');
        }
      ));
    };
  };

  config = mkIf (gcfg.enable && gcfg.enableRestore) {
    environment.systemPackages = mapAttrsToList (name: value: value.script) gcfg.archives;
  };
}
