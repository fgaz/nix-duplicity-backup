#!/usr/bin/env bash

bash ./wrap-squash-in-luks.bash
nix-build -E '((import <nixpkgs/nixos> {}).config.system.build.isoImage)' -I nixos-config=./iso.nix --option cores 4 --substituters ''
