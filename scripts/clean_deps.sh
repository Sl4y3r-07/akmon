#!/usr/bin/env bash
# clean_deps.sh — remove UI npm tree and Akmon build toolchain (apt/snap)
# Invoked by: make clean-deps
#
# Removes the same apt/snap packages that check_deps.sh can install, not only
# packages logged during a prior install (pre-existing installs are removed too).

set -euo pipefail

SCRIPT="${BASH_SOURCE[0]:-$0}"
SDIR="$(cd "$(dirname "$SCRIPT")" && pwd)"
ROOT="$(cd "$SDIR/.." && pwd)"
cd "$ROOT"

# shellcheck source=bpftool_resolve.sh
source "$SDIR/bpftool_resolve.sh"

APT_LIST="$ROOT/.akmon-deps-apt.list"
SNAP_LIST="$ROOT/.akmon-deps-snap.list"

apt_pkg_installed() {
    local p="$1" st
    st=$(dpkg-query -W -f='${Status}' "$p" 2>/dev/null || true)
    [[ "$st" == install\ ok\ installed* ]]
}

collect_akmon_build_apt_pkgs() {
    local p
    # Omit `make`: after clean-deps you still need `make` to run `make deps` / `make build`.
    printf '%s\n' \
        clang llvm golang-go libbpf-dev nodejs npm \
        linux-tools-common bpftool \
        "linux-tools-$(uname -r)"
    while read -r p; do
        [[ -n "$p" ]] && printf '%s\n' "$p"
    done < <(bpftool_apt_pkg_candidates | awk '!seen[$0]++')
    if [[ -f "$APT_LIST" ]] && [[ -s "$APT_LIST" ]]; then
        cat "$APT_LIST"
    fi
}

echo "==> Removing UI npm dependencies (ui/node_modules)..."
rm -rf ui/node_modules

if command -v apt-get &>/dev/null; then
    mapfile -t candidates < <(collect_akmon_build_apt_pkgs | sort -u)
    to_remove=()
    for p in "${candidates[@]}"; do
        [[ -n "$p" ]] || continue
        [[ "$p" == make ]] && continue
        if apt_pkg_installed "$p"; then
            to_remove+=("$p")
        fi
    done
    if ((${#to_remove[@]} > 0)); then
        echo "==> Removing Akmon build apt packages (${#to_remove[@]} installed)..."
        sudo apt-get remove -y "${to_remove[@]}" || true
    else
        echo "==> No tracked apt build packages are currently installed."
    fi
else
    echo "[~] apt-get not found; skipping apt package removal."
fi

rm -f "$APT_LIST"

if command -v snap &>/dev/null; then
    if [[ -f "$SNAP_LIST" ]] && [[ -s "$SNAP_LIST" ]]; then
        while read -r s; do
            [[ -z "$s" ]] && continue
            echo "==> Removing snap (recorded): $s"
            sudo snap remove "$s" || true
        done < <(sort -u "$SNAP_LIST")
    fi
    # Same snaps check_deps may suggest for Go / Node.
    for s in node go; do
        if snap list "$s" &>/dev/null; then
            echo "==> Removing snap (Akmon build-related): $s"
            sudo snap remove "$s" || true
        fi
    done
else
    [[ -f "$SNAP_LIST" ]] && [[ -s "$SNAP_LIST" ]] && echo "[~] snap not found; deleting snap list only."
fi

rm -f "$SNAP_LIST"

echo "==> clean-deps complete."
