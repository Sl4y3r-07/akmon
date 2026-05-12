#!/usr/bin/env bash
# check_deps.sh — verify all build and runtime dependencies
#
# Run this before attempting to build or deploy the monitor.
# Exits 0 if all deps are satisfied, 1 if any are missing.
#
# INSTALL_DEPS=1  (set by `make deps`): on Debian/Ubuntu, missing build
# dependencies that map to apt packages are installed with
#   sudo apt-get update && sudo apt-get install -y …
# Installed package names are appended to .akmon-deps-apt.list / .akmon-deps-snap.list
# in the repo root for `make clean-deps`.

set -euo pipefail

# Path for exec re-invocation (works when run as `bash scripts/check_deps.sh`).
SCRIPT="${BASH_SOURCE[0]:-$0}"
SCRIPTS_DIR="$(cd "$(dirname "$SCRIPT")" && pwd)"
AKMON_REPO_ROOT="$(cd "$SCRIPTS_DIR/.." && pwd)"
AKMON_APT_DEPS_LIST="$AKMON_REPO_ROOT/.akmon-deps-apt.list"
AKMON_SNAP_DEPS_LIST="$AKMON_REPO_ROOT/.akmon-deps-snap.list"

akmon_record_apt_packages() {
    local p f="$AKMON_APT_DEPS_LIST"
    for p in "$@"; do
        [[ -n "$p" ]] || continue
        printf '%s\n' "$p" >> "$f"
    done
    [[ -f "$f" ]] || return 0
    sort -u "$f" -o "${f}.tmp.$$" && mv "${f}.tmp.$$" "$f"
}

akmon_record_snap_pkg() {
    local n="${1:-}" f="$AKMON_SNAP_DEPS_LIST"
    [[ -n "$n" ]] || return 0
    printf '%s\n' "$n" >> "$f"
    sort -u "$f" -o "${f}.tmp.$$" && mv "${f}.tmp.$$" "$f"
}

source "$SCRIPTS_DIR/bpftool_resolve.sh"

# Default on: auto-install via apt when unset or empty (Make may pass INSTALL_DEPS=).
# Set INSTALL_DEPS=0 to check only.
INSTALL_DEPS="${INSTALL_DEPS:-1}"
[[ -n "${INSTALL_DEPS// /}" ]] || INSTALL_DEPS=1

ERRORS=0
WARNINGS=0
APT_TO_INSTALL=()

echo "[*] INSTALL_DEPS=$INSTALL_DEPS  (apt auto-install: $([[ "$INSTALL_DEPS" == "1" ]] && echo on || echo off))"

if [[ "$INSTALL_DEPS" == "1" ]] && ! command -v apt-get &>/dev/null; then
    echo "[!] INSTALL_DEPS=1 but apt-get not found — only printing hints (not a Debian/Ubuntu system?)."
    INSTALL_DEPS=0
fi

queue_apt() {
    local p
    for p in "$@"; do
        [[ -n "$p" ]] || continue
        APT_TO_INSTALL+=("$p")
    done
}

dedupe_apt_list() {
    if ((${#APT_TO_INSTALL[@]} == 0)); then
        return
    fi
    readarray -t APT_TO_INSTALL < <(printf '%s\n' "${APT_TO_INSTALL[@]}" | sort -u)
}

# Vite 7 engines: ^20.19.0 || >=22.12.0 (see npm view vite engines).
_node_version_ok_for_vite() {
    command -v node &>/dev/null || return 1
    node -e '
    const p = process.version.slice(1).split(".");
    const maj = +p[0], min = +(p[1] || 0), pat = +(p[2] || 0);
    if (maj >= 23) process.exit(0);
    if (maj === 22 && (min > 12 || (min === 12 && pat >= 0))) process.exit(0);
    if (maj === 20 && (min > 19 || (min === 19 && pat >= 0))) process.exit(0);
    process.exit(1);
    ' 2>/dev/null
}

_npm_node_ok_for_vite() {
    command -v npm &>/dev/null || return 1
    _node_version_ok_for_vite
}

# Snap / NodeSource when distro nodejs is too old for Vite 7.
ensure_node_for_vite() {
    if _npm_node_ok_for_vite; then
        return 0
    fi
    [[ "$INSTALL_DEPS" == "1" ]] || return 0

    echo ""
    echo "[*] UI build needs Node.js ^20.19.0 or >=22.12.0 (Vite 7). Attempting install…"
    set +e
    if command -v snap &>/dev/null; then
        echo "    sudo snap install node --classic --channel=22/stable"
        if sudo snap install node --classic --channel=22/stable; then
            akmon_record_snap_pkg node
        fi
    fi
    if _npm_node_ok_for_vite; then
        set -e
        echo "  [+] node + npm satisfy Vite 7 (after snap)."
        return 0
    fi
    if command -v curl &>/dev/null && command -v apt-get &>/dev/null; then
        echo "    curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -"
        curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -
        if sudo apt-get install -y nodejs; then
            akmon_record_apt_packages nodejs
        fi
    fi
    set -e
    if _npm_node_ok_for_vite; then
        echo "  [+] node + npm satisfy Vite 7 (after NodeSource)."
    else
        echo "[!] Node.js still missing or too old. Install Node ^20.19 or >=22.12, then re-run make build."
    fi
    return 0
}

check() {
    local name="$1"
    local cmd="$2"
    local hint="$3"
    shift 3
    local apt_pkgs=("$@")

    if eval "$cmd" &>/dev/null 2>&1; then
        echo "  [+] $name"
    else
        echo "  [!] MISSING: $name"
        if [[ "$INSTALL_DEPS" == "1" ]] && ((${#apt_pkgs[@]} > 0)); then
            echo "      Will install via apt: ${apt_pkgs[*]}"
            queue_apt "${apt_pkgs[@]}"
        else
            echo "      Install: $hint"
        fi
        ERRORS=$((ERRORS + 1))
    fi
}

warn() {
    local name="$1"
    local cmd="$2"
    local msg="$3"

    if eval "$cmd" &>/dev/null 2>&1; then
        echo "  [+] $name"
    else
        echo "  [~] WARNING: $name"
        echo "      $msg"
        WARNINGS=$((WARNINGS + 1))
    fi
}

run_all_checks() {
    ERRORS=0
    WARNINGS=0
    APT_TO_INSTALL=()

    echo "=== Build Dependencies ==="
    check "clang >= 12"   "clang --version | grep -E 'version (1[2-9]|[2-9][0-9])'" \
          "sudo apt-get install -y clang" \
          clang

    check "llvm-strip"    "llvm-strip --version" \
          "sudo apt-get install -y llvm" \
          llvm

    check "go >= 1.22"    "go version | grep -E 'go1\.(2[2-9]|[3-9][0-9])'" \
          "https://go.dev/dl/ or: sudo snap install go --classic" \
          golang-go

    check "make"          "make --version" \
          "sudo apt-get install -y make" \
          make

    check "bpftool"       "bpftool_find_path >/dev/null" \
          "run: make deps   (or see scripts/bpftool_resolve.sh for apt/dnf hints)" \
          "linux-tools-$(uname -r)" linux-tools-common

    check "libbpf headers" "test -f /usr/include/bpf/bpf_helpers.h" \
          "sudo apt-get install -y libbpf-dev" \
          libbpf-dev

    check "node + npm (Vite 7 / UI)" "_npm_node_ok_for_vite" \
          "Node ^20.19 or >=22.12: https://nodejs.org/  or: sudo snap install node --classic --channel=22/stable" \
          nodejs npm

    echo ""
    echo "=== Runtime / Kernel Requirements ==="

    check "kernel BTF"    "test -f /sys/kernel/btf/vmlinux" \
          "Kernel needs CONFIG_DEBUG_INFO_BTF=y (Ubuntu 22.04+ stock kernels: yes)"

    check "kernel >= 5.15" \
          "awk -F'.' '{if(\$1>5 || (\$1==5 && \$2>=15)) exit 0; exit 1}' <<< \$(uname -r | cut -d- -f1)" \
          "Upgrade to Ubuntu 22.04 (5.15) or 24.04 (6.x)"

    check "ring buffer support (>= 5.8)" \
          "awk -F'.' '{if(\$1>5 || (\$1==5 && \$2>=8)) exit 0; exit 1}' <<< \$(uname -r | cut -d- -f1)" \
          "Kernel 5.8+ required for BPF ring buffer"

    warn  "debugfs mounted" \
          "mountpoint -q /sys/kernel/debug" \
          "Mount with: sudo mount -t debugfs none /sys/kernel/debug"

    warn  "perf_event_paranoid <= 2" \
          "test \$(cat /proc/sys/kernel/perf_event_paranoid) -le 2" \
          "Lower with: sudo sysctl -w kernel.perf_event_paranoid=2"

    echo ""
    echo "=== Privilege Check ==="
    if [ "$(id -u)" -eq 0 ]; then
        echo "  [+] Running as root (required for loading eBPF programs)"
    else
        warn "CAP_BPF + CAP_PERFMON" \
             "capsh --print 2>/dev/null | grep -q cap_bpf" \
             "Run as root or grant: setcap cap_bpf,cap_perfmon+eip ./monitor"
    fi
}

maybe_install_and_recheck() {
    if [[ "$INSTALL_DEPS" != "1" ]]; then
        return 0
    fi
    dedupe_apt_list
    if ((${#APT_TO_INSTALL[@]} == 0)); then
        return 0
    fi

    echo ""
    echo "==> Installing missing apt packages (requires sudo)..."
    if ! sudo -n true 2>/dev/null; then
        echo "    (enter your password if prompted for sudo)"
    fi
    sudo apt-get update -qq
    bpftool_merge_apt_queue APT_TO_INSTALL
    dedupe_apt_list
    if ((${#APT_TO_INSTALL[@]} == 0)); then
        echo "[!] No installable apt packages left for the missing tools — install manually."
        return 0
    fi
    echo "    Packages: ${APT_TO_INSTALL[*]}"
    local apt_ok=0
    if sudo apt-get install -y "${APT_TO_INSTALL[@]}"; then
        apt_ok=1
        akmon_record_apt_packages "${APT_TO_INSTALL[@]}"
    else
        echo ""
        echo "[!] apt-get install reported errors — trying kernel/cloud/generic bpftool packages…"
        bpftool_try_apt_install_fallbacks || true
    fi

    ensure_node_for_vite

    echo ""
    echo "==> Re-checking dependencies after apt install..."
    if (( apt_ok )); then
        exec env INSTALL_DEPS=0 bash "$SCRIPT"
    elif [[ "${AKMON_DEPS_REENTRY:-0}" != "1" ]]; then
        echo "[!] Bulk apt install failed; retrying full dependency check with auto-install once…"
        exec env INSTALL_DEPS=1 AKMON_DEPS_REENTRY=1 bash "$SCRIPT"
    else
        echo "[!] apt install still failing after retry — final check (install missing packages manually)."
        exec env INSTALL_DEPS=0 bash "$SCRIPT"
    fi
}

# ── Main ────────────────────────────────────────────────────────────────────

run_all_checks

if [[ "$INSTALL_DEPS" == "1" ]] && ((${#APT_TO_INSTALL[@]} > 0)); then
    maybe_install_and_recheck
fi

# maybe_install can return early (e.g. no installable apt names); still try Node for UI.
if [[ "$INSTALL_DEPS" == "1" ]] && ! _npm_node_ok_for_vite; then
    ensure_node_for_vite
    exec env INSTALL_DEPS=0 bash "$SCRIPT"
fi

echo ""
echo "=== Summary ==="
if [ "$ERRORS" -eq 0 ] && [ "$WARNINGS" -eq 0 ]; then
    echo "  All checks passed. Ready to build."
    exit 0
elif [ "$ERRORS" -eq 0 ]; then
    echo "  $WARNINGS warning(s). Build should succeed. Review warnings above."
    exit 0
else
    echo "  $ERRORS error(s), $WARNINGS warning(s). Fix errors before building."
    if [[ "$INSTALL_DEPS" == "1" ]] && ((${#APT_TO_INSTALL[@]} == 0)); then
        echo "  (Nothing left to auto-install via apt — fix the items above manually.)"
    fi
    exit 1
fi
