#!/bin/bash
# shellcheck shell=bash
# bin/lib/mc/load.sh — BH-5240 C1: loads the mc modules through the module map.
# No "# module:" header: this is the bootstrap, not a module. It lives in mc/
# beside a symlink to ../module-map.sh, so a scratch copy of mc/*.sh carries
# the loader too. Order: mc/MODULES, or the module headers when MODULES is absent.
# shellcheck source=bin/lib/module-map.sh
. "${BASH_SOURCE[0]%/*}/module-map.sh" || return 1
mm_load "${BASH_SOURCE[0]%/*}"
