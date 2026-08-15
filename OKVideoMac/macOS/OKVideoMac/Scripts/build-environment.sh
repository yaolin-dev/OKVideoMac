#!/usr/bin/env bash

# Shared, deterministic build environment. MacPorts is the only native
# dependency provider; Homebrew paths are deliberately excluded from
# pkg-config discovery.
export PATH="/opt/local/bin:/opt/local/sbin:$PATH"
export LANG=C
export LC_ALL=C
unset PKG_CONFIG_PATH
export PKG_CONFIG_LIBDIR="/opt/local/lib/pkgconfig:/opt/local/share/pkgconfig"
export PKG_CONFIG="/opt/local/bin/pkg-config"
export CMAKE_PREFIX_PATH="/opt/local"

if [[ -z "${OKVIDEOMAC_BUILD_ROOT:-}" ]]; then
  _okvideomac_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  _okvideomac_project_dir="$(cd "$_okvideomac_script_dir/.." && pwd)"
  export OKVIDEOMAC_BUILD_ROOT="$_okvideomac_project_dir/Vendor/Build"
  unset _okvideomac_project_dir
  unset _okvideomac_script_dir
fi
