{ pkgs
, lib
, options
, config
, ...
}:

with lib;
let
  dcfg = config.services.duplicity-backup;
  cfg = config.services.duplicity-system;

  missing_imports = let
    inherit (config.services.duplicity-backup.archives.system) includes;
  in lib.unique
    (lib.filter (file: !(lib.any (pfx: lib.hasPrefix (toString pfx) file) ([ <nixpkgs/lib/modules.nix> <nixpkgs/nixos> ] ++ includes) ||
                         lib.any (sfx: lib.hasSuffix (toString sfx) file) [ "<unknown-file>" "system-specific.nix" "hardware-configuration.nix" ]))
      (builtins.map (x: toString x.file) options._definedNames));
in
{
  imports = [ ./duplicity-backup.nix ];

  options.services.duplicity-system = {
    restorationImage = lib.mkOption {
      type = with types; bool;
      default = false;
    };

    destination = lib.mkOption {
      type = with types; string;
    };

    includes = lib.mkOption {
      type = with types; listOf path;
      default = [];
    };

    extraExcludes = lib.mkOption {
      type = with types; listOf path;
    };
  };

  config = {
    # assertions =
    #   [ { assertion = !cfg.restorationImage -> missing_imports == [];
    #       message = "Missing imports in system archive: ${toString missing_imports}";
    #     }
    #   ];

    services.duplicity-backup = {
      enable = true;
      usePassphrase = true;

      archives.system = {
        inherit (cfg) destination;
        allowSourceMismatch = true;

        directory = /.;

        includes = cfg.includes;

        excludes = [
          /boot
          /dev
          /lost+found
          /nix
          /proc
          /run
          /sys
          /tmp
          /usr
          /etc/nixos/system-specific.nix
          /etc/nixos/hardware-configuration.nix
          dcfg.cacheDir
          dcfg.envDir
        ] ++ cfg.extraExcludes;
      };
    };
  };
}
