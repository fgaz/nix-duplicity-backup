{ config, lib, pkgs, utils, ... }:

with lib;

let
  gcfg = config.services.duplicity-backup;
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

      keyring = mkOption {
        type = types.string;
        default = "/var/empty";
        description = ''
        '';
      };

      keyId = mkOption {
        type = types.string;
        default = "00000000";
        description = ''
        '';
      };

      pgpKeyFile = mkOption {
        type = types.string;
        default = "/var/empty";
        description = ''
        '';
      };

      archives = mkOption {
        type = types.attrsOf (types.submodule ({ config, ... }:
          {
            options = {
              keyring = mkOption {
                type = types.string;
                default = gcfg.keyring;
                description = ''
                  Set a specific ___ for this archive. This defaults to
                  if left unspecified.
                '';
              };

              pgpKeyFile = mkOption {
                type = types.string;
                default = gcfg.pgpKeyFile;
                description = ''
                  Set a specific ___ for this archive. This defaults to
                  if left unspecified.
                '';
              };

              keyId = mkOption {
                type = types.string;
                default = gcfg.keyId;
                description = ''
                  Set a specific ___ for this archive. This defaults to
                  if left unspecified.
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

        path = with pkgs; [ iputils duplicity openssh gnupg utillinux ];

        # make sure that the backup server is reachable
        #preStart = ''
        #  while ! ping -q -c 1 ${findawaytoextracttheaddressmaybe} &> /dev/null; do sleep 3; done
        #'';

        script = ''
          for i in ${gcfg.envDir}/*; do
             source $i
          done

          mkdir -p ${cfg.cachedir}
          mkdir -p ${gcfg.pgpDir}
          chmod 0700 ${cfg.cachedir}
          chmod 0700 ${gcfg.pgpDir}
          gpg --homedir ${gcfg.pgpDir} --import ${gcfg.rootDir}/test.pub

          ${pkgs.expect}/bin/expect << EOF
            set timeout 10

            spawn ${pkgs.gnupg}/bin/gpg --homedir ${gcfg.pgpDir} --edit-key ${cfg.keyId} '*' --yes trust quit

            expect "Your decision? " { send "5\r" }
            expect "Do you really want to set this key to ultimate trust? (y/N) " { send "y\r" }

            expect "pub" # Required to flush the last command

            interact
          EOF

          duplicity \
            --archive-dir ${cfg.cachedir} \
            --name ${name} \
            --gpg-options "--homedir=${gcfg.pgpDir}" \
            --encrypt-key ${cfg.keyId} \
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

  };
}
