{ pkgs, config, lib, options, ... }:

with lib;

let
  gcfg = config.services.duplicity-backup;
in
{
  imports = [ ./duplicity-backup-common.nix ];

  options = {
    services.duplicity-backup.enableBackup = mkEnableOption "periodic duplicity backups backup tools";
    services.duplicity-backup.archives = mkOption {
      type = types.attrsOf (types.submodule ({ name, config, ... }: {
        options = {
          backup-script = mkOption {
            type = types.path;
          };
        };

        config.backup-script = pkgs.writeScriptBin "duplicity-${name}" (''
          for i in ${gcfg.envDir}/*; do
              source $i
          done

          mkdir -p ${gcfg.cacheDir}
          chmod 0700 ${gcfg.cacheDir}

          ${pkgs.duplicity}/bin/duplicity \
            --archive-dir ${gcfg.cacheDir} \
            --name ${name} \
            --gpg-options "--homedir=${gcfg.pgpDir}" \
            --full-if-older-than 1M \
        '' + optionalString (config.allowSourceMismatch) ''--allow-source-mismatch \
        '' + optionalString (!gcfg.usePassphrase) ''--encrypt-key "Duplicity Backup" \
        '' + ''
            ${concatStringsSep " " (map (v: "--include '${v}'") config.includes)} \
            ${concatStringsSep " " (map (v: "--exclude '${v}'") config.excludes)} \
            ${config.directory} \
            ${config.destination}
        '');
      }));
    };
  };

  config = mkIf (gcfg.enable && gcfg.enableBackup) {
    systemd.services."duplicity@" = {
      description = "Duplicity archive '%i'";

      environment.ARCHIVE = "duplicity-%i";
      path = mapAttrsToList (_: cfg: cfg.backup-script) gcfg.archives;

      script = ''
        exec ''${ARCHIVE/:/ }
      '';

      requires    = [ "network-online.target" ];
      after       = [ "network-online.target" ];

      serviceConfig = {
        Type = "oneshot";
        IOSchedulingClass = "idle";
        NoNewPrivileges = "true";
        CapabilityBoundingSet = [ "CAP_DAC_READ_SEARCH" ];
        PermissionsStartOnly = "true";
      };
    };

    # Note: the timer must be Persistent=true, so that systemd will start it even
    # if e.g. your laptop was asleep while the latest interval occurred.
    systemd.timers = mapAttrs' (name: cfg: nameValuePair "duplicity@${name}"
      { timerConfig.OnCalendar = cfg.period;
        timerConfig.Persistent = "true";
        wantedBy = [ "timers.target" ];
      }) gcfg.archives;
  };
}
