#!/bin/bash
# Build this port with the shared pinned-kernel recipe; see ../sfp-sgmiiplus/build.sh.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
exec bash "$HERE/../sfp-sgmiiplus/build.sh" "${1:?usage: build.sh CONFIG}" eth5
