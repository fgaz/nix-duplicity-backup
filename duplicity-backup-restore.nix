{ config, lib, pkgs, utils, ... }:

with lib;

let
  gcfg = config.services.duplicity-backup;
in
{
  config = mkIf gcfg.enable {
    environment.systemPackages = mapAttrsToList (name: cfg: pkgs.writeScriptBin "duplicity-restore-${name}" ''
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
  };
}
