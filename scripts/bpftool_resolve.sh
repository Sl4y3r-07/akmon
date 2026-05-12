#!/usr/bin/env bash
#
# Handles:
#   - bpftool on PATH, /usr/sbin/bpftool
#   - /usr/lib/linux-tools/<kernel-release>/bpftool (Ubuntu/Debian layout)
#   - Cloud kernels: 6.x.y-NNN-azure / -gcp / -aws → linux-tools-* meta packages
#   - Fallback: linux-tools-generic, linux-cloud-tools-*, standalone bpftool

bpftool_kernel_release() {
    uname -r
}

bpftool_kernel_flavor() {
    bpftool_kernel_release | awk -F- '{print $NF}'
}

bpftool_find_path() {
    local kver c f best dir
    kver=$(bpftool_kernel_release)

    if command -v bpftool &>/dev/null; then
        c=$(type -P bpftool 2>/dev/null || true)
        if [[ -n "$c" && -x "$c" ]] && "$c" version &>/dev/null; then
            echo "$c"
            return 0
        fi
    fi

    if [[ -x /usr/sbin/bpftool ]] && /usr/sbin/bpftool version &>/dev/null; then
        echo /usr/sbin/bpftool
        return 0
    fi

    f="/usr/lib/linux-tools/${kver}/bpftool"
    if [[ -x "$f" ]] && "$f" version &>/dev/null; then
        echo "$f"
        return 0
    fi

    best=""
    shopt -s nullglob
    for f in /usr/lib/linux-tools/*/bpftool; do
        [[ -x "$f" ]] || continue
        "$f" version &>/dev/null || continue
        dir=$(basename "$(dirname "$f")")
        if [[ "$dir" == "$kver" ]]; then
            echo "$f"
            shopt -u nullglob
            return 0
        fi
        best="$f"
    done
    shopt -u nullglob

    if [[ -n "$best" ]]; then
        echo "$best"
        return 0
    fi
    return 1
}

bpftool_apt_pkg_candidates() {
    local kver flavor
    kver=$(bpftool_kernel_release)
    flavor=$(bpftool_kernel_flavor)

    echo "linux-tools-${kver}"
    echo "linux-cloud-tools-${kver}"

    case "$flavor" in
        azure|gcp|aws|oracle|ibm|kvm|oem|raspi)
            echo "linux-tools-${flavor}"
            echo "linux-cloud-tools-${flavor}"
            ;;
    esac

    echo "linux-tools-generic"
    echo "linux-cloud-tools-generic"
    echo "bpftool"
}

# Space-separated packages that apt-cache knows about (Debian/Ubuntu).
bpftool_apt_pkgs_available_space() {
    command -v apt-cache &>/dev/null || return 1
    local p out=()
    while read -r p; do
        [[ -z "$p" ]] && continue
        apt-cache show --no-all-versions "$p" &>/dev/null || continue
        out+=("$p")
    done < <(bpftool_apt_pkg_candidates | awk '!seen[$0]++')
    ((${#out[@]} == 0)) && return 1
    printf '%s ' "${out[@]}" | sed 's/[[:space:]]*$//'
    return 0
}

bpftool_print_install_hint() {
    echo "[!] bpftool not found (need a build that matches kernel $(bpftool_kernel_release))."
    if command -v apt-get &>/dev/null && command -v apt-cache &>/dev/null; then
        local pk
        if pk=$(bpftool_apt_pkgs_available_space 2>/dev/null); then
            echo "    Debian/Ubuntu — install one of these (first match is usually best):"
            echo "      sudo apt-get update && sudo apt-get install -y linux-tools-common $pk"
        else
            echo "    Debian/Ubuntu — try (enable universe/restricted if needed):"
            echo "      sudo apt-get update && sudo apt-get install -y linux-tools-common \\"
            while read -r line; do
                echo "          $line \\"
            done < <(bpftool_apt_pkg_candidates | awk '!seen[$0]++')
            echo "          bpftool"
        fi
    else
        echo "    RHEL/Fedora-style: sudo dnf install bpftool   (or: yum install bpftool)"
        echo "    Arch: sudo pacman -S bpftool"
    fi
}

bpftool_merge_apt_queue() {
    local -n _apt_ref="$1"
    (( ${#_apt_ref[@]} > 0 )) || return 0
    local kver dt found i p fb
    kver=$(bpftool_kernel_release)
    dt="linux-tools-${kver}"
    found=0
    for p in "${_apt_ref[@]}"; do
        [[ "$p" == "$dt" ]] && found=1 && break
    done
    ((found)) || return 0
    command -v apt-cache &>/dev/null || return 0
    if apt-cache show --no-all-versions "$dt" &>/dev/null; then
        return 0
    fi

    echo "[*] $dt is not in apt — adding kernel/cloud/generic bpftool packages (if available)."
    local new=()
    for p in "${_apt_ref[@]}"; do
        [[ "$p" == "$dt" ]] && continue
        new+=("$p")
    done
    _apt_ref=("${new[@]}")

    while read -r fb; do
        [[ -z "$fb" ]] && continue
        apt-cache show --no-all-versions "$fb" &>/dev/null || continue
        _apt_ref+=("$fb")
    done < <(bpftool_apt_pkg_candidates | awk '!seen[$0]++')
}

bpftool_try_apt_install_fallbacks() {
    bpftool_find_path &>/dev/null && return 0
    command -v apt-get &>/dev/null || return 1
    command -v apt-cache &>/dev/null || return 1

    local p
    while read -r p; do
        [[ -z "$p" ]] && continue
        apt-cache show --no-all-versions "$p" &>/dev/null || continue
        if sudo apt-get install -y "$p" linux-tools-common 2>/dev/null; then
            declare -F akmon_record_apt_packages &>/dev/null && akmon_record_apt_packages "$p" linux-tools-common
        fi
        bpftool_find_path &>/dev/null && return 0
    done < <(bpftool_apt_pkg_candidates | awk '!seen[$0]++')

    if sudo apt-get install -y bpftool linux-tools-common 2>/dev/null; then
        declare -F akmon_record_apt_packages &>/dev/null && akmon_record_apt_packages bpftool linux-tools-common
    fi
    bpftool_find_path &>/dev/null
}
