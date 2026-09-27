#!/bin/sh
set -e

TARBALL="${1:-/tmp/qmanager.tar.gz}"
[ -f "$TARBALL" ] || { echo "Missing tarball: $TARBALL" >&2; exit 1; }
[ "$TARBALL" = /tmp/qmanager.tar.gz ] || ln -sf "$TARBALL" /tmp/qmanager.tar.gz
rm -rf /tmp/qmanager_install
# Only the installer script comes out here; it unpacks the rest on /usrdata.
tar xzf /tmp/qmanager.tar.gz -C /tmp qmanager_install/install_cfw3212.sh
exec sh /tmp/qmanager_install/install_cfw3212.sh
