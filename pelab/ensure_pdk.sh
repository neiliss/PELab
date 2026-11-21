#!/usr/bin/env bash
set -euo pipefail

# ensure_pdk.sh – install Puppet Development Kit (PDK) on the master if absent.
# Works on Debian/Ubuntu (apt) and RHEL-family (dnf/yum).  puppet-tools only
# publishes repos for specific releases, so fall back to a supported one.
if /opt/puppetlabs/pdk/bin/pdk --version >/dev/null 2>&1; then
    echo "PDK already present: $(/opt/puppetlabs/pdk/bin/pdk --version)"
    exit 0
fi

. /etc/os-release 2>/dev/null || true

if command -v apt-get >/dev/null 2>&1; then
    CODENAME="${VERSION_CODENAME:-}"
    echo "Installing PDK via apt (codename: ${CODENAME:-unknown})..."
    install_pdk_deb() {
        local cn="$1" deb="/tmp/puppet-tools-release-${1}.deb"
        curl -kfs -o "$deb" "https://apt.puppet.com/puppet-tools-release-${1}.deb" || return 1
        dpkg-deb --info "$deb" >/dev/null 2>&1 || return 1
        dpkg -i "$deb" >/dev/null 2>&1
        apt-get update -qq
        apt-get install -y pdk
        /opt/puppetlabs/pdk/bin/pdk --version
    }
    for cn in "${CODENAME:-}" noble jammy; do
        [ -z "$cn" ] && continue
        echo "Trying puppet-tools repo for '${cn}'..."
        if install_pdk_deb "$cn"; then echo "PDK installed from the '${cn}' repo."; exit 0; fi
    done

elif command -v dnf >/dev/null 2>&1 || command -v yum >/dev/null 2>&1; then
    EL="${VERSION_ID%%.*}"
    PKG="$(command -v dnf >/dev/null 2>&1 && echo dnf || echo yum)"
    echo "Installing PDK via ${PKG} (el: ${EL:-unknown})..."
    install_pdk_rpm() {
        local el="$1" rpm="/tmp/puppet-tools-release-el-${1}.noarch.rpm"
        curl -kfs -o "$rpm" "https://yum.puppet.com/puppet-tools-release-el-${1}.noarch.rpm" || return 1
        rpm -qp "$rpm" >/dev/null 2>&1 || return 1
        $PKG install -y "$rpm" >/dev/null 2>&1
        $PKG install -y pdk
        /opt/puppetlabs/pdk/bin/pdk --version
    }
    for el in "${EL:-}" 9 8; do
        [ -z "$el" ] && continue
        echo "Trying puppet-tools repo for 'el-${el}'..."
        if install_pdk_rpm "$el"; then echo "PDK installed from the 'el-${el}' repo."; exit 0; fi
    done
fi

echo "ERROR: could not install PDK (no apt/dnf/yum, or no supported puppet-tools repo)" >&2
exit 1
