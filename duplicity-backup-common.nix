{ pkgs, config, lib, ... }:
with lib;
let
  gcfg = config.services.duplicity-backup;

  duplicityGenKeys = pkgs.writeScriptBin "duplicity-gen-keys" (''
    [ -x ${gcfg.envDir} ] && echo "WARNING: The environment directory(${gcfg.envDir}) exists." && exit 1
    [ -x ${gcfg.pgpDir} ] && echo "WARNING: The PGP home directory(${gcfg.pgpDir}) exists." && exit 1

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
  '' + (if gcfg.usePassphrase
  then ''
    stty -echo
    printf "PASSPHRASE="; read PASSPHRASE; echo
    echo "export PASSPHRASE=\"$PASSPHRASE\""         >  ${gcfg.envDir}/20-passphrase.sh
    stty echo
  ''
  else ''
    ${pkgs.expect}/bin/expect << EOF
      set timeout 10

      spawn ${pkgs.gnupg}/bin/gpg --homedir ${gcfg.pgpDir} --generate-key --passphrase "" --pinentry-mode loopback

      expect "Real name: " { send "Duplicity Backup\r" }
      expect "Email address: " { send "\r" }
      expect "Change (N)ame, (E)mail, or (O)kay/(Q)uit? " { send "O\r" }

      expect "pub" # Required to flush the last command

      interact
    EOF
  ''));

  mkSecurePathsOption =
    { description
    , default
    }:
    mkOption {
      inherit description default;

      type = with types; listOf (either path string);
      apply = xs: map (x: if builtins.typeOf x == "path" then toString x else x) xs;
    };

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
  options = {
    services.duplicity-backup = {
      enable = mkEnableOption "periodic duplicity backups";

      usePassphrase = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Use passphrase instead of keys
        '';
      };

      rootDir = mkSecurePathOption {
        default = /var/keys/duplicity;
        description = ''
          Directory of bash scripts to `source`,
          currently used for declaring AWS keys and secrets
        '';
      };

      envDir = mkSecurePathOption {
        default = gcfg.rootDir + "/env";
        description = ''
          Directory of bash scripts to `source`,
          currently used for declaring AWS keys and secrets
        '';
      };

      pgpDir = mkSecurePathOption {
        default = gcfg.rootDir + "/gnupg";
        description = ''
          Directory of bash scripts to `source`,
          currently used for declaring AWS keys and secrets
        '';
      };

      cachedir = mkSecurePathOption {
        default = /var/cache/duplicity;
        description = ''
          The cache allows duplicity to identify previously stored data
          blocks, reducing archival time and bandwidth usage.
        '';
      };

      archives = mkOption {
        type = types.attrsOf (types.submodule ({ ... }:
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

              directories = mkSecurePathsOption {
                default = [];
                description = "List of filesystem paths to archive.";
              };

              excludes = mkSecurePathsOption {
                default = [];
                description = ''
                  Exclude files and directories matching these patterns.
                '';
              };

              includes = mkSecurePathsOption {
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
    warnings = concatLists (mapAttrsToList (name: cfg:
        lib.optional (length cfg.directories > 1) "Multiple directories is currently beta"
      ) gcfg.archives);

    assertions =
      (mapAttrsToList (name: cfg:
        { assertion = cfg.directories != [];
          message = "Must specify paths for duplicity to back up";
        }) gcfg.archives);

    environment.systemPackages = [ duplicityGenKeys ];
  };
}