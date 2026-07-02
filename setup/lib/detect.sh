#!/usr/bin/env bash
# detect.sh — environment detection for the Exasol Personal Local Starter Kit.
#
# Sourced by install.sh and setup-*.sh. Pure read-only checks, no side effects.
# Compatible with bash 3.2 and POSIX sh.

# detect_os — prints: macos | linux | wsl | unsupported
detect_os() {
    case "$(uname -s)" in
        Darwin)
            echo "macos"
            ;;
        Linux)
            if grep -qi microsoft /proc/version 2>/dev/null; then
                echo "wsl"
            else
                echo "linux"
            fi
            ;;
        *)
            echo "unsupported"
            ;;
    esac
}

# detect_arch — prints: arm64 | x86_64 | unsupported
detect_arch() {
    case "$(uname -m)" in
        arm64|aarch64) echo "arm64" ;;
        x86_64|amd64)  echo "x86_64" ;;
        *)             echo "unsupported" ;;
    esac
}

# detect_ram_gb — total physical memory in whole GB
detect_ram_gb() {
    if [ "$(uname -s)" = "Darwin" ]; then
        echo $(( $(sysctl -n hw.memsize) / 1073741824 ))
    else
        awk '/MemTotal/ { printf "%d", $2 / 1048576 }' /proc/meminfo
    fi
}

# detect_free_disk_gb <path> — free space in whole GB at the given path
detect_free_disk_gb() {
    df -Pk "${1:-$HOME}" | awk 'NR == 2 { printf "%d", $4 / 1048576 }'
}

# detect_container_runtime — prints the first usable runtime:
#   docker | podman | none
# "Usable" means the CLI exists and the daemon/socket answers.
detect_container_runtime() {
    if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
        echo "docker"
        return
    fi
    if command -v podman >/dev/null 2>&1 && podman info >/dev/null 2>&1; then
        echo "podman"
        return
    fi
    echo "none"
}

# detect_container_runtime_detail — richer status for error messages:
#   docker | podman | docker-stopped | podman-stopped | none
detect_container_runtime_detail() {
    _usable="$(detect_container_runtime)"
    if [ "$_usable" != "none" ]; then
        echo "$_usable"
        return
    fi
    if command -v docker >/dev/null 2>&1; then
        echo "docker-stopped"
        return
    fi
    if command -v podman >/dev/null 2>&1; then
        echo "podman-stopped"
        return
    fi
    echo "none"
}

# podman_is_rootless — succeeds when podman runs rootless (affects ports/volumes)
podman_is_rootless() {
    [ "$(podman info --format '{{.Host.Security.Rootless}}' 2>/dev/null)" = "true" ]
}

# port_in_use <port> — succeeds when something already listens on the port.
port_in_use() {
    (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null && { exec 3>&- 3<&-; return 0; }
    return 1
}

# preflight_report — check every requirement for this machine and print a
# pass/fail line for each, with the remedy inline. Returns non-zero when a
# hard requirement is missing. Installs nothing; safe to run any time.
preflight_report() {
    _failures=0
    _pf_ok()   { printf '  \033[1;32m✓\033[0m %s\n' "$*"; }
    _pf_bad()  { printf '  \033[1;31m✗\033[0m %s\n' "$*"; _failures=$((_failures + 1)); }
    _pf_note() { printf '  \033[1;33m·\033[0m %s\n' "$*"; }

    _os="$(detect_os)"
    _arch="$(detect_arch)"

    printf 'Preflight check\n'

    # platform
    if [ "$_os" = "unsupported" ]; then
        _pf_bad "Operating system: $(uname -s) is not supported (macOS, Linux, WSL, or Windows via install.ps1)"
    else
        _pf_ok "Operating system: $_os"
    fi
    if [ "$_arch" = "unsupported" ]; then
        _pf_bad "CPU architecture: $(uname -m) is not supported (arm64 or x86_64 required)"
    else
        _pf_ok "CPU architecture: $_arch"
    fi

    # memory and disk, against the target runtime for this OS
    _ram="$(detect_ram_gb)"
    _disk="$(detect_free_disk_gb "$HOME")"
    if [ "$_os" = "macos" ]; then
        if [ "$_ram" -ge 8 ]; then _pf_ok "Memory: ${_ram} GB (Exasol Personal needs 8+)"
        else _pf_bad "Memory: ${_ram} GB — Exasol Personal needs at least 8 GB; this machine cannot run the kit's macOS path"; fi
        if [ "$_disk" -ge 20 ]; then _pf_ok "Free disk: ${_disk} GB (20+ recommended)"
        else _pf_bad "Free disk: ${_disk} GB — free up space (20 GB recommended for the local database)"; fi
    else
        if [ "$_ram" -ge 4 ]; then _pf_ok "Memory: ${_ram} GB (Exasol Nano needs 4+)"
        else _pf_bad "Memory: ${_ram} GB — Exasol Nano needs at least 4 GB"; fi
        if [ "$_disk" -ge 10 ]; then _pf_ok "Free disk: ${_disk} GB (10+ recommended)"
        else _pf_bad "Free disk: ${_disk} GB — free up space (10 GB recommended for the database image and data)"; fi
    fi

    # base tools
    for _tool in curl tar; do
        if command -v "$_tool" >/dev/null 2>&1; then _pf_ok "$_tool available"
        else _pf_bad "$_tool missing — install it with your package manager"; fi
    done
    if command -v python3 >/dev/null 2>&1; then
        _pf_ok "python3 available"
    elif [ "$_os" = "macos" ]; then
        _pf_bad "python3 missing — run: xcode-select --install"
    else
        _pf_bad "python3 missing — e.g. sudo apt install python3"
    fi

    # container runtime (only the Nano platforms need one)
    if [ "$_os" != "macos" ]; then
        case "$(detect_container_runtime_detail)" in
            docker)         _pf_ok "Container runtime: docker (running)" ;;
            podman)         _pf_ok "Container runtime: podman (running)" ;;
            docker-stopped) _pf_bad "Docker is installed but not running — start Docker (e.g. Docker Desktop), then re-run" ;;
            podman-stopped) _pf_bad "Podman is installed but not running — try: podman machine start" ;;
            none)           _pf_bad "No container runtime — install Docker (docs.docker.com/get-docker) or Podman (podman.io)" ;;
        esac
    fi

    # port
    if port_in_use "${EXAKIT_DB_PORT:-8563}"; then
        _pf_note "Port ${EXAKIT_DB_PORT:-8563} is in use — fine if that is an existing local Exasol; otherwise stop the other application or set EXAKIT_DB_PORT"
    else
        _pf_ok "Port ${EXAKIT_DB_PORT:-8563} is free"
    fi

    # network reachability (downloads come from these). Any HTTP response
    # counts as reachable — only connection/DNS/TLS failures matter here.
    _pf_reachable() {
        curl -sI --connect-timeout 5 -o /dev/null "https://$1" 2>/dev/null
    }
    for _endpoint in github.com objects.githubusercontent.com; do
        if _pf_reachable "$_endpoint"; then
            _pf_ok "Network: $_endpoint reachable"
        else
            _pf_bad "Network: cannot reach $_endpoint — check connectivity/proxy (set HTTPS_PROXY if needed)"
        fi
    done
    if [ "$_os" != "macos" ]; then
        if _pf_reachable "registry-1.docker.io/v2/"; then
            _pf_ok "Network: Docker Hub reachable"
        else
            _pf_bad "Network: cannot reach Docker Hub — the Nano image cannot be pulled from this network"
        fi
    fi
    if _pf_reachable "pypi.org"; then
        _pf_ok "Network: pypi.org reachable (MCP server package)"
    else
        _pf_bad "Network: cannot reach pypi.org — the MCP server package cannot be downloaded"
    fi

    printf '\n'
    if [ "$_failures" -eq 0 ]; then
        printf 'All checks passed — this machine can run the starter kit.\n'
    else
        printf '%s requirement(s) missing — fix the items marked ✗ above and re-run.\n' "$_failures"
    fi
    return "$_failures"
}

# detect_summary — prints a human-readable report of everything above.
# usage: detect_summary  (safe to call before any install decision)
detect_summary() {
    _os="$(detect_os)"
    _arch="$(detect_arch)"
    _ram="$(detect_ram_gb)"
    _disk="$(detect_free_disk_gb "$HOME")"
    _runtime="$(detect_container_runtime_detail)"

    printf 'Detected environment:\n'
    printf '  OS:                %s\n' "$_os"
    printf '  Architecture:      %s\n' "$_arch"
    printf '  Memory:            %s GB\n' "$_ram"
    printf '  Free disk (home):  %s GB\n' "$_disk"
    printf '  Container runtime: %s\n' "$_runtime"
}
