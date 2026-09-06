#!/usr/bin/env sh
# Build script for odin-player.
#
# The system `vendor` collection is read-only and ships miniaudio WITHOUT a
# prebuilt `lib/miniaudio.a` on Linux. We keep a local copy of the package and
# a locally compiled `miniaudio.a`, then point the compiler at it via a
# project-local ODIN_ROOT (`odinhome/`) whose `vendor` entry is our local copy.
#
# `base`, `core` and `shared` are symlinked from the system Odin install so the
# standard libraries still resolve normally.
set -eu

# Use the system Odin root (ignore any ODIN_ROOT already in the environment).
unset ODIN_ROOT
SYS_ROOT="$(odin root)"
HERE="$(cd "$(dirname "$0")" && pwd)"

mkdir -p "$HERE/odinhome"
ln -sfn "$SYS_ROOT/base"   "$HERE/odinhome/base"
ln -sfn "$SYS_ROOT/core"   "$HERE/odinhome/core"
ln -sfn "$SYS_ROOT/shared" "$HERE/odinhome/shared"
ln -sfn "$HERE/vendor"     "$HERE/odinhome/vendor"

ODIN_ROOT="$HERE/odinhome" odin build . -out:odin-player "$@"
