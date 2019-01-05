{ config, lib, pkgs, utils, ... }:

with lib;

let
  gcfg = config.services.duplicity-backup;

  restoreScripts = mapAttrsToList (name: cfg: pkgs.writeScriptBin "duplicity-restore-${name}" ''
    for i in ${gcfg.envDir}/*; do
       source $i
    done

    ${concatStringsSep "\n" (map (directory: ''
      ${pkgs.duplicity}/bin/duplicity \
        --archive-dir ${gcfg.cachedir} \
        --name ${name}-${baseNameOf directory} \
        --gpg-options "--homedir=${gcfg.pgpDir}" \
      '' + optionalString (!gcfg.usePassphrase) ''--encrypt-key "Duplicity Backup" \'' +
      ''
        ${concatStringsSep " " (map (v: "--exclude ${v}") cfg.excludes)} \
        ${concatStringsSep " " (map (v: "--include ${v}") cfg.includes)} \
        ${cfg.destination}/${baseNameOf directory} \
        ${directory}
      '') cfg.directories)}
  '') gcfg.archives;
in
{
  imports = [ ./duplicity-backup-common.nix ./duplicity-backup-backup.nix ];

  config = mkIf gcfg.enable {
    warnings = concatLists (mapAttrsToList (name: cfg:
        lib.optional (length cfg.directories > 1) "Multiple directories is currently beta"
      ) gcfg.archives);

    assertions =
      (mapAttrsToList (name: cfg:
        { assertion = cfg.directories != [];
          message = "Must specify paths for duplicity to back up";
        }) gcfg.archives);

    environment.systemPackages = restoreScripts;
  };
}
