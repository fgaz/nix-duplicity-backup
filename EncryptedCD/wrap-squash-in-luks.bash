#!/usr/bin/env bash

STAGES=()

set -e

atexit ()
{
    while (( ${#STAGES[@]} )); do
        case ${STAGES[0]} in
            "luksOpen"):
                    cryptsetup luksClose cryptbackup
                ;;
        esac
        STAGES=( "${STAGES[@]:1}" )
    done
}

trap atexit EXIT

SQUASHFS=$(nix-build -E '((import <nixpkgs/nixos> {}).config.system.build.squashfsStore)' -I nixos-config=./iso.nix)
BLOCKS=$(du -B 512 $(realpath $SQUASHFS) | cut -d $'\t' -f1)

fallocate -x -l $(( 512 * ($BLOCKS + 8192) )) ./cryptbackup.squashfs.luks

cryptsetup luksFormat ./cryptbackup.squashfs.luks
cryptsetup luksOpen ./cryptbackup.squashfs.luks cryptbackup
STAGES=( "luksOpen" "${STAGES[@]}" )

dd if=$SQUASHFS of=/dev/mapper/cryptbackup bs=512
