{ config, lib, pkgs, utils, ... }:

with lib;

let
  gcfg = config.services.duplicity-backup;

  duplicityGenKeys = pkgs.writeScriptBin "duplicity-gen-keys" ''
    [ -x ${gcfg.envDir} ] && echo "The environment directory exists." && exit 1
    [ -x ${gcfg.pgpDir} ] && echo "The PGP home directory exists." && exit 1

    umask u=rwx,g=,o=
    mkdir -p ${gcfg.envDir}
    mkdir -p ${gcfg.pgpDir}
    umask 0022

    stty -echo
    printf "AWS_ACCESS_KEY_ID="; read AWS_ACCESS_KEY_ID; echo
    printf "AWS_SECRET_ACCESS_KEY="; read AWS_SECRET_ACCESS_KEY; echo
    stty echo

    echo "export AWS_ACCESS_KEY_ID=\"$AWS_ACCESS_KEY_ID\""         >  ${gcfg.envDir}/10-aws.sh
    echo "export AWS_SECRET_ACCESS_KEY=\"$AWS_SECRET_ACCESS_KEY\"" >> ${gcfg.envDir}/10-aws.sh

    ${pkgs.expect}/bin/expect << EOF
      set timeout 10

      spawn ${pkgs.gnupg}/bin/gpg --homedir ${gcfg.pgpDir} --generate-key --passphrase "" --pinentry-mode loopback

      expect "Real name: " { send "Duplicity Backup\r" }
      expect "Email address: " { send "\r" }
      expect "Change (N)ame, (E)mail, or (O)kay/(Q)uit? " { send "O\r" }

      expect "pub" # Required to flush the last command

      interact
    EOF
  '';

  restoreScripts = mapAttrsToList (name: cfg: pkgs.writeScriptBin "duplicity-restore-${name}" ''
    export PASSPHRASE=""
    for i in ${gcfg.envDir}/*; do
       source $i
    done

    ${pkgs.duplicity}/bin/duplicity \
      --archive-dir ${gcfg.cachedir} \
      --name ${name} \
      --gpg-options "--homedir=${gcfg.pgpDir}" \
      --encrypt-key "Duplicity Backup" \
      ${concatStringsSep " " (map (v: "--exclude ${v}") cfg.excludes)} \
      ${concatStringsSep " " (map (v: "--include ${v}") cfg.includes)} \
      ${cfg.destination} \
      ${concatStringsSep " " cfg.directories}
  '') gcfg.archives;
in
{
  options = {
    services.duplicity-backup = {
      enable = mkEnableOption "periodic duplicity backups";

      rootDir = mkOption {
        type = types.string;
        default = "/var/keys/duplicity";
        description = ''
          Directory of bash scripts to `source`,
          currently used for declaring AWS keys and secrets
        '';
      };

      envDir = mkOption {
        type = types.string;
        default = "${gcfg.rootDir}/env";
        description = ''
          Directory of bash scripts to `source`,
          currently used for declaring AWS keys and secrets
        '';
      };

      pgpDir = mkOption {
        type = types.string;
        default = "${gcfg.rootDir}/gnupg";
        description = ''
          Directory of bash scripts to `source`,
          currently used for declaring AWS keys and secrets
        '';
      };

      pgpKeyFile = mkOption {
        type = types.string;
        default = "/var/empty";
        description = ''
        '';
      };

      cachedir = mkOption {
        type = types.string;
        default = "/var/cache/duplicity/";
        description = ''
          The cache allows duplicity to identify previously stored data
          blocks, reducing archival time and bandwidth usage.
        '';
      };

      archives = mkOption {
        type = types.attrsOf (types.submodule ({ config, ... }:
          {
            options = {
              destination = mkOption {
                type = types.string;
                default = "";
                example = "rsync://user@example.com:/home/user";
                description = ''
                '';
              };

              period = mkOption {
                type = types.str;
                default = "01:15";
                example = "hourly";
                description = ''
                  Create archive at this interval.

                  The format is described in
                  <citerefentry><refentrytitle>systemd.time</refentrytitle>
                  <manvolnum>7</manvolnum></citerefentry>.
                '';
              };

              directories = mkOption {
                type = types.listOf types.string;
                default = [];
                description = "List of filesystem paths to archive.";
              };

              excludes = mkOption {
                type = types.listOf types.str;
                default = [];
                description = ''
                  Exclude files and directories matching these patterns.
                '';
              };

              includes = mkOption {
                type = types.listOf types.str;
                default = [];
                description = ''
                  Include only files and directories matching these
                  patterns (the empty list includes everything).

                  Exclusions have precedence over inclusions.
                '';
              };

              maxbw = mkOption {
                type = types.nullOr types.int;
                default = null;
                description = ''
                  Abort archival if upstream bandwidth usage in bytes
                  exceeds this threshold.
                '';
              };

              maxbwRateUp = mkOption {
                type = types.nullOr types.int;
                default = null;
                example = literalExample "25 * 1000";
                description = ''
                  Upload bandwidth rate limit in bytes.
                '';
              };

              maxbwRateDown = mkOption {
                type = types.nullOr types.int;
                default = null;
                example = literalExample "50 * 1000";
                description = ''
                  Download bandwidth rate limit in bytes.
                '';
              };
            };
          }
        ));

        default = {};

        example = literalExample ''
          {
            nixos =
              { directories = [ "/home" "/root/ssl" ];
              };

            gamedata =
              { directories = [ "/var/lib/virtualMail" ];
                period      = "*:30";
              };
          }
        '';

        description = ''
          Duplicity backup configurations. Each attribute names a backup
          to be created at a given time interval, according to the options
          associated with it.

          For each member of the set is created a timer which triggers the
          instanced <literal>duplicity-backup-name</literal> service unit. You may use
          <command>systemctl start duplicity-backup-name</command> to
          manually trigger creation of <literal>backup-name</literal> at
          any time.
        '';
      };
    };
  };

  config = mkIf gcfg.enable {
    assertions =
      (mapAttrsToList (name: cfg:
        { assertion = cfg.directories != [];
          message = "Must specify paths for duplicity to back up";
        }) gcfg.archives);

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
          export PASSPHRASE=""

          for i in ${gcfg.envDir}/*; do
             source $i
          done

          mkdir -p ${gcfg.cachedir}
          chmod 0700 ${gcfg.cachedir}

          ${pkgs.duplicity}/bin/duplicity \
            --archive-dir ${gcfg.cachedir} \
            --name ${name} \
            --gpg-options "--homedir=${gcfg.pgpDir}" \
            --encrypt-key "Duplicity Backup" \
            ${concatStringsSep " " (map (v: "--exclude ${v}") cfg.excludes)} \
            ${concatStringsSep " " (map (v: "--include ${v}") cfg.includes)} \
            ${concatStringsSep " " cfg.directories} \
            ${cfg.destination}
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

    environment.systemPackages = [ pkgs.duplicity duplicityGenKeys ] ++ restoreScripts;
  };
}
