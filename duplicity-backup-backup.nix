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
          # TODO: Merge these into a single service using service arguments
          backupService = mkOption {
            type = types.attrs;
          };
          fullService = mkOption {
            type = types.attrs;
          };
          cleanupService = mkOption {
            type = types.attrs;
          };
          destroyService = mkOption {
            type = types.attrs;
          };
        };

        config = let
          defaultService = description: script: {
            inherit description;
            requires    = [ "network-online.target" ];
            after       = [ "network-online.target" ];

            path = with pkgs; [ gnupg ];

            # make sure that the backup server is reachable
            #preStart = ''
            #  while ! ping -q -c 1 ${findawaytoextracttheaddressmaybe} &> /dev/null; do sleep 3; done
            #'';

            inherit script;

            serviceConfig = {
              Type = "oneshot";
              IOSchedulingClass = "idle";
              NoNewPrivileges = "true";
              CapabilityBoundingSet = [ "CAP_DAC_READ_SEARCH" ];
              PermissionsStartOnly = "true";
            };
          };
        in {
          backupService = defaultService "Duplicity archive '${name}'" ''
            for i in ${gcfg.envDir}/*; do
               source $i
            done

            mkdir -p ${gcfg.cacheDir}
            chmod 0700 ${gcfg.cacheDir}

            ${concatStringsSep "\n" (map (directory: let
              excludes = [];
              includes = [];
            in ''
              ${pkgs.duplicity}/bin/duplicity \
                --archive-dir ${gcfg.cacheDir} \
                --name ${name}-${baseNameOf directory} \
                --gpg-options "--homedir=${gcfg.pgpDir}" \
                --full-if-older-than 1M \
              '' + optionalString (config.allowSourceMismatch) ''--allow-source-mismatch \
              '' + optionalString (!gcfg.usePassphrase) ''--encrypt-key "Duplicity Backup" \
              '' + ''
                ${concatStringsSep " " (map (v: "--exclude ${v}") excludes)} \
                ${concatStringsSep " " (map (v: "--include ${v}") includes)} \
                ${directory} \
                ${config.destination}/${baseNameOf directory}
              '') config.directories)}
          '';

          fullService = defaultService "Duplicity archive '${name}' full" ''
            for i in ${gcfg.envDir}/*; do
               source $i
            done

            mkdir -p ${gcfg.cacheDir}
            chmod 0700 ${gcfg.cacheDir}

            ${concatStringsSep "\n" (map (directory: let
              excludes = [];
              includes = [];
            in ''
              ${pkgs.duplicity}/bin/duplicity full \
                --archive-dir ${gcfg.cacheDir} \
                --name ${name}-${baseNameOf directory} \
                --gpg-options "--homedir=${gcfg.pgpDir}" \
              '' + optionalString (config.allowSourceMismatch) ''--allow-source-mismatch \
              '' + optionalString (!gcfg.usePassphrase) ''--encrypt-key "Duplicity Backup" \
              '' + ''
                ${concatStringsSep " " (map (v: "--exclude ${v}") excludes)} \
                ${concatStringsSep " " (map (v: "--include ${v}") includes)} \
                ${directory} \
                ${config.destination}/${baseNameOf directory}
              '') config.directories)}
          '';

          cleanupService = defaultService "Duplicity archive '${name}' cleanup" ''
            for i in ${gcfg.envDir}/*; do
               source $i
            done

            mkdir -p ${gcfg.cacheDir}
            chmod 0700 ${gcfg.cacheDir}

            ${concatStringsSep "\n" (map (directory: ''
              ${pkgs.duplicity}/bin/duplicity cleanup \
                --force \
                --archive-dir ${gcfg.cacheDir} \
                --name ${name}-${baseNameOf directory} \
                --gpg-options "--homedir=${gcfg.pgpDir}" \
              '' + optionalString (!gcfg.usePassphrase) ''--encrypt-key "Duplicity Backup" \
              '' + ''
                ${config.destination}/${baseNameOf directory}
              '') config.directories)}
          '';

          destroyService = defaultService "Duplicity archive '${name}' destroy" ''
            for i in ${gcfg.envDir}/*; do
               source $i
            done

            mkdir -p ${gcfg.cacheDir}
            chmod 0700 ${gcfg.cacheDir}

            ${concatStringsSep "\n" (map (directory: ''
              ${pkgs.duplicity}/bin/duplicity remove-older-than now \
                --force \
                --archive-dir ${gcfg.cacheDir} \
                --name ${name}-${baseNameOf directory} \
                --gpg-options "--homedir=${gcfg.pgpDir}" \
              '' + optionalString (!gcfg.usePassphrase) ''--encrypt-key "Duplicity Backup" \
              '' + ''
                ${config.destination}/${baseNameOf directory}
              '') config.directories)}
          '';
        };
      }));
    };
  };

  config = mkIf (gcfg.enable && gcfg.enableBackup) {
    systemd.services =
      listToAttrs (builtins.concatMap (name:
        [(nameValuePair "duplicity-${name}"         gcfg.archives.${name}.backupService)
         (nameValuePair "duplicity-${name}-full"    gcfg.archives.${name}.fullService)
         (nameValuePair "duplicity-${name}-cleanup" gcfg.archives.${name}.cleanupService)
         (nameValuePair "duplicity-${name}-destroy" gcfg.archives.${name}.destroyService)
        ]
      ) (builtins.attrNames gcfg.archives));

    # Note: the timer must be Persistent=true, so that systemd will start it even
    # if e.g. your laptop was asleep while the latest interval occurred.
    systemd.timers = mapAttrs' (name: cfg: nameValuePair "duplicity-${name}"
      { timerConfig.OnCalendar = cfg.period;
        timerConfig.Persistent = "true";
        wantedBy = [ "timers.target" ];
      }) gcfg.archives;
  };
}
