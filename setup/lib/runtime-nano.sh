#!/usr/bin/env bash
# runtime-nano.sh — Exasol Nano container runtime module (Linux, WSL, Windows).
#
# Sourced by setup scripts after common.sh and detect.sh. Runs the pinned
# exasol/nano image under Docker (preferred) or Podman (fallback), with:
#   - a persistent named volume for /exa (database state survives restarts)
#   - the SQL port bound to localhost only
#   - a generated SYS password injected on first deployment via secret mount
#
# Container contract (from the image documentation):
#   - readiness: logs print "Database is now up and running!"
#   - connection: 127.0.0.1:8563, user sys, TLS (self-signed certificate)
#   - recommended limits: --shm-size=512mb --pids-limit=-1

EXAKIT_NANO_CONTAINER="${EXAKIT_NANO_CONTAINER:-exasol-nano}"
EXAKIT_NANO_VOLUME="${EXAKIT_NANO_VOLUME:-exasol-nano-data}"
EXAKIT_NANO_MIN_RAM_GB="${EXAKIT_NANO_MIN_RAM_GB:-4}"
EXAKIT_NANO_READY_TIMEOUT="${EXAKIT_NANO_READY_TIMEOUT:-600}"

# nano_engine — the usable container engine, cached after first call.
nano_engine() {
    if [ -z "${EXAKIT_NANO_ENGINE:-}" ]; then
        EXAKIT_NANO_ENGINE="$(detect_container_runtime)"
    fi
    echo "$EXAKIT_NANO_ENGINE"
}

nano_check_requirements() {
    _engine="$(detect_container_runtime_detail)"
    case "$_engine" in
        docker|podman)
            ok "Container runtime: $_engine"
            ;;
        docker-stopped)
            die "Docker is installed but not running. Start Docker (e.g. open Docker Desktop) and re-run."
            ;;
        podman-stopped)
            die "Podman is installed but its machine/service is not running. Try 'podman machine start' and re-run."
            ;;
        none)
            error "No container runtime found. Exasol Nano needs Docker or Podman."
            printf '    Install one of:\n' >&2
            printf '      Docker:  https://docs.docker.com/get-docker/\n' >&2
            printf '      Podman:  https://podman.io/docs/installation\n' >&2
            die "Install a container runtime and re-run this script."
            ;;
    esac

    _ram="$(detect_ram_gb)"
    if [ "$_ram" -lt "$EXAKIT_NANO_MIN_RAM_GB" ] && [ "${EXAKIT_FORCE:-0}" != "1" ]; then
        die "Exasol Nano needs at least ${EXAKIT_NANO_MIN_RAM_GB} GB RAM (detected: ${_ram} GB). Set EXAKIT_FORCE=1 to try anyway."
    fi

    _disk="$(detect_free_disk_gb "$HOME")"
    if [ "$_disk" -lt 10 ] && [ "${EXAKIT_FORCE:-0}" != "1" ]; then
        die "Less than 10 GB free disk space (detected: ${_disk} GB) — the database image and data need room. Free up space or set EXAKIT_FORCE=1."
    fi
}

nano_image_ref() {
    echo "docker.io/${EXAKIT_NANO_IMAGE}:${EXAKIT_NANO_TAG}"
}

nano_container_exists() {
    "$(nano_engine)" container inspect "$EXAKIT_NANO_CONTAINER" >/dev/null 2>&1
}

nano_container_running() {
    [ "$("$(nano_engine)" container inspect -f '{{.State.Running}}' "$EXAKIT_NANO_CONTAINER" 2>/dev/null)" = "true" ]
}

nano_ready_in_logs() {
    "$(nano_engine)" logs "$EXAKIT_NANO_CONTAINER" 2>&1 | grep -q "Database is now up and running!"
}

# nano_install — pull the pinned image and start the container (first run
# deploys the database with a generated SYS password). Idempotent.
nano_install() {
    _engine="$(nano_engine)"
    _image="$(nano_image_ref)"

    if nano_container_running && nano_ready_in_logs; then
        ok "Nano container already running and healthy"
        nano_record_manifest
        return 0
    fi

    if nano_container_exists && ! nano_container_running; then
        info "Found existing Nano container — starting it"
        run_logged "$_engine" start "$EXAKIT_NANO_CONTAINER" || \
            die "Could not start existing container $EXAKIT_NANO_CONTAINER (see log)"
        nano_wait_ready
        nano_record_manifest
        return 0
    fi

    if ! nano_container_exists; then
        if port_in_use "$EXAKIT_DB_PORT"; then
            die "Port $EXAKIT_DB_PORT is already in use by another application. Stop it or set EXAKIT_DB_PORT, then re-run."
        fi
        info "Pulling image $_image"
        _pulled=0
        for _attempt in 1 2 3; do
            if run_logged "$_engine" pull "$_image"; then
                _pulled=1
                break
            fi
            [ "$_attempt" -lt 3 ] && { warn "Pull attempt $_attempt failed — retrying in $((_attempt * 10))s"; sleep $((_attempt * 10)); }
        done
        [ "$_pulled" -eq 1 ] || die "Image pull failed after 3 attempts: $_image (network/Docker Hub issue — see log)"
        ok "Image pulled"

        # First deployment: generate the SYS password up front and hand it to
        # the container as a read-only secret file. It is only applied when
        # /exa is empty; on an existing volume the previous password stays.
        _password="$(read_credential nano_sys_password)"
        if [ -z "$_password" ]; then
            _password="$(generate_password)"
            store_credential nano_sys_password "$_password"
        fi

        # SELinux systems (Fedora, RHEL) need the :z label on bind mounts;
        # harmless elsewhere, so apply it for podman across the board.
        _secret_mount="${EXAKIT_CREDS_DIR}/nano_sys_password:/run/secrets/sys_password:ro"
        [ "$_engine" = "podman" ] && _secret_mount="${_secret_mount},z"

        info "Starting Nano container ($EXAKIT_NANO_CONTAINER)"
        run_logged "$_engine" run -d \
            --name "$EXAKIT_NANO_CONTAINER" \
            --shm-size=512mb \
            --pids-limit=-1 \
            -p "127.0.0.1:${EXAKIT_DB_PORT}:8563" \
            -v "${EXAKIT_NANO_VOLUME}:/exa" \
            -v "$_secret_mount" \
            "$_image" init sys_password_file=/run/secrets/sys_password || \
            die "Container failed to start (see log)"
        push_rollback "$_engine rm -f $EXAKIT_NANO_CONTAINER"
        push_rollback "$_engine volume rm $EXAKIT_NANO_VOLUME"
    fi

    nano_wait_ready
    nano_record_manifest
}

# nano_wait_ready — poll container logs until the database reports ready.
nano_wait_ready() {
    info "Waiting for the database to come up (timeout: ${EXAKIT_NANO_READY_TIMEOUT}s)"
    _waited=0
    while [ "$_waited" -lt "$EXAKIT_NANO_READY_TIMEOUT" ]; do
        if ! nano_container_running; then
            "$(nano_engine)" logs --tail 30 "$EXAKIT_NANO_CONTAINER" >> "${EXAKIT_LOG_FILE:-/dev/null}" 2>&1
            die "Nano container stopped unexpectedly (see log)"
        fi
        if nano_ready_in_logs; then
            ok "Database is up (took ~${_waited}s)"
            return 0
        fi
        sleep 5
        _waited=$((_waited + 5))
        if [ $((_waited % 30)) -eq 0 ]; then
            info "Still starting... (${_waited}s)"
        fi
    done
    error "Database did not become ready within ${EXAKIT_NANO_READY_TIMEOUT}s."
    printf '    Inspect the logs:   %s logs %s\n' "$(nano_engine)" "$EXAKIT_NANO_CONTAINER" >&2
    printf '    If a first install was interrupted, the data volume may be half-initialized.\n' >&2
    printf '    Reset and retry:    %s rm -f %s && %s volume rm %s\n' \
        "$(nano_engine)" "$EXAKIT_NANO_CONTAINER" "$(nano_engine)" "$EXAKIT_NANO_VOLUME" >&2
    die "Nano startup timed out"
}

nano_record_manifest() {
    manifest_set runtime.type "nano"
    manifest_set runtime.engine "$(nano_engine)"
    manifest_set runtime.image "$(nano_image_ref)"
    manifest_set runtime.container "$EXAKIT_NANO_CONTAINER"
    manifest_set runtime.volume "$EXAKIT_NANO_VOLUME"
    manifest_set runtime.dsn "127.0.0.1:${EXAKIT_DB_PORT}"
    manifest_set runtime.user "sys"
    manifest_set runtime.password_file "$EXAKIT_CREDS_DIR/nano_sys_password"
    manifest_set runtime.tls "self-signed"
    manifest_set runtime.status "healthy"
}

# --- lifecycle (used by exakit) ---------------------------------------------
nano_status() {
    if ! nano_container_exists; then
        echo "not installed"
    elif ! nano_container_running; then
        echo "stopped"
    elif nano_ready_in_logs; then
        echo "running"
    else
        echo "starting"
    fi
}

nano_start() {
    nano_container_exists || die "No Nano container found. Run the installer first."
    if nano_container_running; then
        ok "Nano container is already running"
        return 0
    fi
    run_logged "$(nano_engine)" start "$EXAKIT_NANO_CONTAINER" || die "Failed to start container"
    nano_wait_ready
    ok "Nano started"
}

nano_stop() {
    nano_container_running || { ok "Nano container is not running"; return 0; }
    info "Stopping Nano container (waiting up to 60s for a clean shutdown)"
    run_logged "$(nano_engine)" stop -t 60 "$EXAKIT_NANO_CONTAINER" || die "Failed to stop container"
    manifest_set runtime.status "stopped"
    ok "Nano stopped"
}

# nano_teardown [--data] — remove the container; --data also removes the
# persistent volume (all database content).
nano_teardown() {
    _engine="$(nano_engine)"
    if nano_container_exists; then
        info "Removing Nano container"
        run_logged "$_engine" rm -f "$EXAKIT_NANO_CONTAINER" || warn "Container removal failed"
    fi
    if [ "${1:-}" = "--data" ]; then
        if "$_engine" volume inspect "$EXAKIT_NANO_VOLUME" >/dev/null 2>&1; then
            info "Removing data volume $EXAKIT_NANO_VOLUME"
            run_logged "$_engine" volume rm "$EXAKIT_NANO_VOLUME" || warn "Volume removal failed"
        fi
    else
        info "Data volume $EXAKIT_NANO_VOLUME kept (pass --data to remove it)"
    fi
    manifest_set runtime.status "removed"
}
