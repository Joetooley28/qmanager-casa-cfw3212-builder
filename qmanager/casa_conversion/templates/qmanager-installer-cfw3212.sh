#!/bin/sh
set -e

TARBALL="${1:-/tmp/qmanager.tar.gz}"
[ -f "$TARBALL" ] || { echo "Missing tarball: $TARBALL" >&2; exit 1; }
rm -rf /tmp/qmanager_install
tar xzf "$TARBALL" -C /tmp
exec sh /tmp/qmanager_install/install_cfw3212.sh
