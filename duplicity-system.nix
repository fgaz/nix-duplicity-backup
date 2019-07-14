{ pkgs
, lib
, options
, config
, ...
}:

with lib;
let
  cfg = config.services.duplicity-system;

  missing_imports = let
    inherit (config.services.duplicity-backup.archives.system) directories;
  in lib.unique
    (lib.filter (file: !(lib.any (pfx: lib.hasPrefix (toString pfx) file) ([ <nixpkgs/lib/modules.nix> <nixpkgs/nixos> ] ++ directories) ||
                         lib.any (sfx: lib.hasSuffix (toString sfx) file) ["system-specific.nix" "hardware-configuration.nix"]))
      (builtins.map (x: toString x.file) options._definedNames));
in
{
  imports = [ ./duplicity-backup.nix ];

  options.services.duplicity-system = {
    destination = lib.mkOption {
      type = with types; string;
    };
    extraFiles = lib.mkOption {
      type = with types; listOf path;
    };
  };

  config = {
    assertions =
      [ { assertion = missing_imports == [];
          message = "Missing imports in system archive: ${toString missing_imports}";
        }
      ];

    services.duplicity-backup = {
      enable = true;
      usePassphrase = true;

      archives.system = {
        inherit (cfg) destination;
        allowSourceMismatch = true;

        directories = [
          # Backup credentials
          /etc/wpa_supplicant.conf
          /etc/passwd
          /etc/shadow
          /etc/group

          # Backup base configuration
          /etc/nixos/configuration.nix

          # Backup duplicity itself
          ./.
        ] ++ config.services.duplicity-system.extraFiles;
      };
    };
  };
}
