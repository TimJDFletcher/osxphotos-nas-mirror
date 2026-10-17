#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# dock-connected.sh MAC_ADDRESS -- an example preflight check for
# osxphotos-nas-mirror.sh: the run goes ahead only while the Ethernet dock
# with this MAC address is connected. Find the address with `ifconfig -a`
# while docked.
#
# Exit 0: the address appears in `ifconfig -a`. Exit 1: it doesn't. Exit 2:
# no MAC address was given.
#
# In the conf:
#   PREFLIGHT_CHECKS=("preflight-checks/dock-connected.sh aa:bb:cc:dd:ee:ff")
#   (a relative path is relative to the script's directory)

if [ "$#" -ne 1 ] || [ -z "$1" ]; then
    echo "Usage: $0 MAC_ADDRESS" >&2
    exit 2
fi

# -F: a MAC address is text, not a pattern.
if ifconfig -a | grep -q -i -F -- "$1"; then
    exit 0
fi
exit 1
