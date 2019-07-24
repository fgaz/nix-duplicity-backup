{ pkgs, config, lib, ... }:
with lib;
let
  gcfg = config.services.duplicity-backup;

  duplicityGenKeys = pkgs.writeScriptBin "duplicity-gen-keys" (''
    #!${pkgs.stdenv.shell}

    usage()
    {
        cat <<EOF
    duplicity-gen-keys [--help] [--no-aws | --aws profile] [--update]

    where:
        --help   show this help text
        --no-aws do not use AWS auto-detection
        --aws    auto-detect AWS credentials from ~/.aws/credentials
        --update add new keys to the system and archive the past keys
    EOF
    }

    while [ "$#" -gt 0 ]; do
      case "$1" in
        --help)
            usage
            exit
            ;;
        --update)
            UPDATE=
            ;;
        --no-aws | --aws)
            [ -n "''${AWS_PROFILE+SET}" ] && printf 'Multiple [ --aws | --no-aws ] flags.\n' 1>&2 && exit 4
            PROFILE=
            [ "$1" == "--aws" ] && shift && PROFILE="$1"
            AWS_PROFILE="$PROFILE"
      esac
      shift
    done

    writeVar() {
      VAR="$1"
      FILE="$2"

      touch "$FILE"
      printf 'export %s=%q\n' "$VAR" "''${!VAR}" >> "$FILE"
    }

    prompt() {
      VAR="$1"

      [ "$2" = "SECRET" ] && stty -echo
      printf '%s=' "$VAR" 1>&2
      IFS= read -r "$VAR"
      [ "$2" = "SECRET" ] && stty echo
      [ "$2" = "SECRET" ] && printf '\n' 1>&2
    }

    if [ -z "''${UPDATE+SET}" ]; then
      if [ -e ${escapeShellArg gcfg.envDir} ]; then
        printf "The environment directory(%s) exists. Use --update to archive it." ${escapeShellArg gcfg.envDir} 1>&2
        exit 1
      elif [ -e ${escapeShellArg gcfg.pgpDir} ]; then
        printf "The PGP home directory(%s) exists. Use --update to archive it." ${escapeShellArg gcfg.pgpDir} 1>&2
        exit 1
      fi
    fi

    NEW_ENV=${escapeShellArg (gcfg.envDir + ".d")}
    NEW_ENV="$NEW_ENV/$(date -Iseconds)"
    NEW_PGP=${escapeShellArg (gcfg.pgpDir + ".d")}
    NEW_PGP="$NEW_PGP/$(date -Iseconds)"

    umask u=rwx,g=,o=
    mkdir -p "$NEW_ENV"
    mkdir -p "$NEW_PGP"
    umask 0022

    cleanup () {
      rm -fr "$NEW_ENV"
      rm -fr "$NEW_PGP"
    }
    trap cleanup EXIT

    AWS_FILE=$(eval echo "~$SUDO_USER/.aws/credentials")
    if [ -e "$AWS_FILE" -a -z "''${AWS_PROFILE+SET}" ]; then
      printf 'AWS credentials file(%s) exists. Use [ --no-aws | --aws profile ].\n' "$AWS_FILE" 1>&2
      exit 2
    fi

    if [ -e "$AWS_FILE" -a -n "$AWS_PROFILE" ]; then
      { read -r AWS_ACCESS_KEY_ID;
        read -r AWS_SECRET_ACCESS_KEY;
      } < <(sed -n '/^\['"$AWS_PROFILE"'\]/,/^\[.\+\]/{ # Get section that starts with $AWS_PROFILE
              /^aws_access_key_id *= */    s//0 /p;     # Extract AWS_ACCESS_KEY_ID
              /^aws_secret_access_key *= */s//1 /p;     # Extract AWS_SECRET_ACCESS_KEY
            }' < "$AWS_FILE" | sort | cut -d' ' -f2-)
    else
      prompt AWS_ACCESS_KEY_ID
      prompt AWS_SECRET_ACCESS_KEY SECRET
    fi

    writeVar AWS_ACCESS_KEY_ID     "$NEW_ENV/10-aws.sh"
    writeVar AWS_SECRET_ACCESS_KEY "$NEW_ENV/10-aws.sh"
  '' + (if gcfg.usePassphrase
  then ''
    prompt PASSPHRASE SECRET
    writeVar PASSPHRASE "$NEW_ENV/20-passphrase.sh"
  ''
  else ''
    ${pkgs.expect}/bin/expect << EOF
      set timeout 10

      spawn ${pkgs.gnupg}/bin/gpg --homedir "$NEW_PGP" --generate-key --passphrase "" --pinentry-mode loopback

      expect "Real name: " { send "Duplicity Backup\r" }
      expect "Email address: " { send "\r" }
      expect "Change (N)ame, (E)mail, or (O)kay/(Q)uit? " { send "O\r" }

      expect "pub" # Required to flush the last command

      interact
    EOF
  '') + ''
    trap EXIT

    rm ${escapeShellArg gcfg.envDir}
    rm ${escapeShellArg gcfg.pgpDir}

    ln -s "$NEW_ENV" ${escapeShellArg gcfg.envDir}
    ln -s "$NEW_PGP" ${escapeShellArg gcfg.pgpDir}
  '');

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
    , ...
    }@args:
    mkOption ({
      inherit description;

      type = with types; either path string;
      apply = x: if builtins.typeOf x == "path" then toString x else x;
    } // lib.optionalAttrs (args ? default) {
      inherit (args) default;
    });
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

      cacheDir = mkSecurePathOption {
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

              removeAllButNFull = mkOption {
                type = types.nullOr types.int;
                default = null;
                example = 2;
                description = ''
                  Only keep the given amount of full backups,
                  useful for pruning old full backups
                  which are too outdated to be useful.
                '';
              };

              fullIfOlderThan = mkOption {
                type = types.str;
                default = "1M";
                example = "1D";
                description = ''
                  Use full backup when fullIfOlderThan time has passed.

                  The format is described in
                  <citerefentry><refentrytitle>duplicity</refentrytitle>
                  <manvolnum>1</manvolnum></citerefentry>.
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

              directory = mkSecurePathOption {
                description = "File system path to archive.";
              };

              allowSourceMismatch = mkOption {
                type = types.bool;
                default = false;
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
              { directory = /home;
              };

            gamedata =
              { directory = /var/lib/virtualMail;
                period    = "*:30";
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
    assertions = concatLists (mapAttrsToList (name: cfg:
      let
        protocols = [ "s3" "sftp" ];
      in
      [{ assertion = any (protocol: hasPrefix (protocol + "://") cfg.destination) protocols;
         message = "Currently supported protocols are: " + concatStringsSep " " protocols;
       }
      ]) gcfg.archives);

    environment.systemPackages = [ duplicityGenKeys ];
  };
}
