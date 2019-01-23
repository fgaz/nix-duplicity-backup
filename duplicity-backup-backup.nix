{ pkgs, config, lib, ... }:

with lib;

let
  gcfg = config.services.duplicity-backup;
in
{
  imports = [ ./duplicity-backup-common.nix ];

  config = mkIf gcfg.enable {
    systemd.services =
      mapAttrs' (name: cfg: nameValuePair "duplicity-${name}" {
        description = "Duplicity archive '${name}'";
        requires    = [ "network-online.target" ];
        after       = [ "network-online.target" ];

        path = with pkgs; [ gnupg ];

        # make sure that the backup server is reachable
        #preStart = ''
        #  while ! ping -q -c 1 ${findawaytoextracttheaddressmaybe} &> /dev/null; do sleep 3; done
        #'';

        script = ''
          for i in ${gcfg.envDir}/*; do
             source $i
          done

          mkdir -p ${gcfg.cachedir}
          chmod 0700 ${gcfg.cachedir}

          ${concatStringsSep "\n" (map (directory: ''
            ${pkgs.duplicity}/bin/duplicity \
              --archive-dir ${gcfg.cachedir} \
              --name ${name}-${baseNameOf directory} \
              --gpg-options "--homedir=${gcfg.pgpDir}" \
            '' + optionalString (!gcfg.usePassphrase) ''--encrypt-key "Duplicity Backup" \'' +
            ''
              ${concatStringsSep " " (map (v: "--exclude ${v}") cfg.excludes)} \
              ${concatStringsSep " " (map (v: "--include ${v}") cfg.includes)} \
              ${directory} \
              ${cfg.destination}/${baseNameOf directory}
            '') cfg.directories)}
        '';

        serviceConfig = {
          Type = "oneshot";
          IOSchedulingClass = "idle";
          NoNewPrivileges = "true";
          CapabilityBoundingSet = [ "CAP_DAC_READ_SEARCH" ];
          PermissionsStartOnly = "true";
        };
      }) gcfg.archives;

    # Note: the timer must be Persistent=true, so that systemd will start it even
    # if e.g. your laptop was asleep while the latest interval occurred.
    systemd.timers = mapAttrs' (name: cfg: nameValuePair "duplicity-${name}"
      { timerConfig.OnCalendar = cfg.period;
        timerConfig.Persistent = "true";
        wantedBy = [ "timers.target" ];
      }) gcfg.archives;
  };
}
