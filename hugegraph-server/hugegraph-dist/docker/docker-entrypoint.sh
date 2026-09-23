#!/bin/bash
#
# Licensed to the Apache Software Foundation (ASF) under one or more
# contributor license agreements.  See the NOTICE file distributed with
# this work for additional information regarding copyright ownership.
# The ASF licenses this file to You under the Apache License, Version 2.0
# (the "License"); you may not use this file except in compliance with
# the License.  You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
set -euo pipefail

DOCKER_FOLDER="./docker"
INIT_FLAG_FILE="init_complete"
GRAPH_CONF="./conf/graphs/hugegraph.properties"
REST_SERVER_CONF="./conf/rest-server.properties"

mkdir -p "${DOCKER_FOLDER}"

log() { echo "[hugegraph-server-entrypoint] $*"; }

# Property reading/writing goes through props.awk, which implements the
# java.util.Properties grammar HugeConfig applies (escapes, `:`/whitespace
# separators, continuations, first-definition-wins duplicates).  grep/sed
# rewrites disagree with it on mounted or upgraded configs, silently
# producing two definitions of one key.  Values move through environment
# variables rather than argv so a PASSWORD never shows up in `ps` output.
PROPS_AWK="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/props.awk"
if [[ ! -f "${PROPS_AWK}" ]]; then
    log "ERROR: props.awk not found next to the entrypoint"
    exit 1
fi

encode_prop_value() {
    local value="$1" encoded="" char
    local i

    LC_ALL=C
    for ((i = 0; i < ${#value}; i++)); do
        char="${value:i:1}"
        case "${char}" in
            "\\") encoded+="\\\\" ;;
            " ") encoded+="\\ " ;;
            $'\t') encoded+="\\t" ;;
            $'\n') encoded+="\\n" ;;
            $'\r') encoded+="\\r" ;;
            $'\f') encoded+="\\f" ;;
            *) encoded+="${char}" ;;
        esac
    done
    printf '%s' "${encoded}"
}

set_prop_encoded() {
    local key="$1" encoded_val="$2" file="$3"

    PROPS_MODE=set PROPS_KEY="${key}" \
        PROPS_VALUE_ENCODED="${encoded_val}" PROPS_FILE="${file}" \
        awk -f "${PROPS_AWK}" /dev/null
}

set_prop() {
    local key="$1" val="$2" file="$3"

    set_prop_encoded "$key" "$(encode_prop_value "$val")" "$file"
}

get_prop_encoded() {
    local key="$1" file="$2"

    PROPS_MODE=get PROPS_KEY="${key}" PROPS_FILE="${file}" \
        awk -f "${PROPS_AWK}" /dev/null
}

# What the top-level authentication mapping of gremlin-server.yaml says about
# authentication, as one of three states:
#
#   none     no such mapping
#   named    the mapping carries an authenticator
#   nameless the mapping exists but names no authenticator
#
# Only presence is asked for, never the class: the entrypoint does not copy a
# value between the two files any more, so quotes, inline comments and flow
# mappings stay snakeyaml's business instead of becoming a parser here.  The
# key must start at column 0 — an `authentication:` nested under another
# mapping belongs to that feature, not to the Gremlin server, and reading it as
# the Gremlin one would let an unrelated class decide whether REST is
# authenticated while Gremlin stayed on TinkerPop's AllowAllAuthenticator.
yaml_auth_state() {
    local yaml="./conf/gremlin-server.yaml"

    [[ -f "${yaml}" ]] || { echo "none"; return 0; }
    awk '
        /^authentication[ \t]*:/ {
            inblk = 1
            have = 1
            # A flow mapping keeps the authenticator on the same line as the
            # key, so it has to count there too; missing it would report a
            # configured mapping as nameless and refuse a valid deployment.
            if (match($0, /authenticator[ \t]*:/)) { named = 1; exit }
            next
        }
        # Any other column-0 key ends the mapping.  A blank or whitespace-only
        # line does not, because YAML does not close a mapping on an empty line.
        inblk && /^[^ \t]/ { inblk = 0 }
        inblk && /^[ \t]+authenticator[ \t]*:/ { named = 1; exit }
        END {
            if (named) print "named"
            else if (have) print "nameless"
            else print "none"
        }
    ' "${yaml}"
}

# Authentication has to be configured on both sides or on neither.  A mounted
# config carrying only one is refused rather than completed: the entrypoint
# cannot know which class the operator means, and finishing the other side from
# a guessed default is how Gremlin ends up on AllowAllAuthenticator while REST
# enforces StandardAuthenticator.  A mapping that names no authenticator is
# refused by itself, because enable-auth.sh guards on the presence of that
# mapping and would otherwise write only the REST side.
check_auth_sides() {
    local rest=0 yaml=0 state

    state=$(yaml_auth_state)
    if [[ "${state}" == "nameless" ]]; then
        log "ERROR: gremlin-server.yaml carries a top-level authentication" \
            "mapping that names no authenticator; add an authenticator entry" \
            "to it or remove the mapping, then restart."
        return 1
    fi
    if [[ -n "$(get_prop_encoded "auth.authenticator" "${REST_SERVER_CONF}")" ]]; then
        rest=1
    fi
    if [[ "${state}" == "named" ]]; then
        yaml=1
    fi
    if (( rest == yaml )); then
        return 0
    fi
    log "ERROR: authentication is configured in only one of" \
        "rest-server.properties (auth.authenticator) and" \
        "gremlin-server.yaml (authentication.authenticator);" \
        "configure both or neither, then restart."
    return 1
}

migrate_env() {
    local old_name="$1" new_name="$2"

    if [[ -n "${!old_name:-}" && -z "${!new_name:-}" ]]; then
        log "WARN: deprecated env '${old_name}' detected; mapping to '${new_name}'"
        export "${new_name}=${!old_name}"
    fi
}

migrate_env "BACKEND"  "HG_SERVER_BACKEND"
migrate_env "PD_PEERS" "HG_SERVER_PD_PEERS"

if [[ -n "${HG_SERVER_AUTH_TOKEN_SECRET:-}" ]]; then
    LC_ALL=C
    if (( ${#HG_SERVER_AUTH_TOKEN_SECRET} < 32 )); then
        log "ERROR: HG_SERVER_AUTH_TOKEN_SECRET must be at least 32 bytes"
        exit 1
    fi
fi

if [[ -n "${PASSWORD:-}" &&
      "${HG_SERVER_REQUIRE_AUTH_TOKEN_SECRET:-false}" == "true" &&
      -z "${HG_SERVER_AUTH_TOKEN_SECRET:-}" ]]; then
    log "ERROR: HG_SERVER_AUTH_TOKEN_SECRET is required when authentication is enabled"
    exit 1
fi

AUTH_TOKEN_SECRET_ENCODED=""
if [[ -n "${PASSWORD:-}" && -z "${HG_SERVER_AUTH_TOKEN_SECRET:-}" ]]; then
    rest_secret=$(get_prop_encoded "auth.token_secret" "${REST_SERVER_CONF}")
    graph_secret=$(get_prop_encoded "auth.token_secret" "${GRAPH_CONF}")
    if [[ -n "${rest_secret}" ]]; then
        AUTH_TOKEN_SECRET_ENCODED="${rest_secret}"
        if [[ -n "${graph_secret}" && "${graph_secret}" != "${rest_secret}" ]]; then
            log "WARN: authentication token secrets differ; using REST secret"
        fi
    elif [[ -n "${graph_secret}" ]]; then
        AUTH_TOKEN_SECRET_ENCODED="${graph_secret}"
    else
        HG_SERVER_AUTH_TOKEN_SECRET=$(head -c 32 /dev/urandom | base64 | tr -d '\n')
        log "generated a shared authentication token secret"
    fi
fi

# ── Map env → properties file ─────────────────────────────────────────
[[ -n "${HG_SERVER_BACKEND:-}"  ]] && set_prop "backend"  "${HG_SERVER_BACKEND}"  "${GRAPH_CONF}"
[[ -n "${HG_SERVER_PD_PEERS:-}" ]] && set_prop "pd.peers" "${HG_SERVER_PD_PEERS}" "${GRAPH_CONF}"
[[ -n "${HG_SERVER_USE_PD:-}" ]] && \
    set_prop "usePD" "${HG_SERVER_USE_PD}" "${REST_SERVER_CONF}"
[[ -n "${HG_SERVER_PD_PEERS:-}" ]] && \
    set_prop "pd.peers" "${HG_SERVER_PD_PEERS}" "${REST_SERVER_CONF}"
[[ -n "${HG_SERVER_CLUSTER:-}" ]] && \
    set_prop "cluster" "${HG_SERVER_CLUSTER}" "${REST_SERVER_CONF}"
[[ -n "${HG_SERVER_REST_URL:-}" ]] && set_prop "restserver.url" \
    "${HG_SERVER_REST_URL}" "${REST_SERVER_CONF}"
[[ -n "${HG_SERVER_MIN_FREE_MEMORY:-}" ]] && set_prop "restserver.min_free_memory" \
    "${HG_SERVER_MIN_FREE_MEMORY}" "${REST_SERVER_CONF}"
if [[ -n "${HG_SERVER_AUTH_TOKEN_SECRET:-}" ]]; then
    set_prop "auth.token_secret" "${HG_SERVER_AUTH_TOKEN_SECRET}" \
        "${REST_SERVER_CONF}"
    set_prop "auth.token_secret" "${HG_SERVER_AUTH_TOKEN_SECRET}" "${GRAPH_CONF}"
elif [[ -n "${AUTH_TOKEN_SECRET_ENCODED}" ]]; then
    set_prop_encoded "auth.token_secret" "${AUTH_TOKEN_SECRET_ENCODED}" \
        "${REST_SERVER_CONF}"
    set_prop_encoded "auth.token_secret" "${AUTH_TOKEN_SECRET_ENCODED}" \
        "${GRAPH_CONF}"
fi
if [[ -n "${PASSWORD:-}" ]]; then
    set_prop "auth.admin_pa" "${PASSWORD}" "${REST_SERVER_CONF}"
    # A refusal here exits the entrypoint under set -e, so enable-auth.sh can
    # never run one-sided after it.
    check_auth_sides
    # This script is idempotent and must run outside the initialization guard:
    # an upgrade can preserve the marker from an unauthenticated deployment.
    ./bin/enable-auth.sh
fi

# Normalized once here and reused by the init-flag guard below. The accepted
# spellings are the ones HugeConfig accepts, case-insensitive: commons-lang 2.x
# BooleanUtils, reached through commons-configuration 1.x PropertyConverter.
# That set excludes 0 and 1, which commons-lang3 would have taken. Anything
# outside it is rejected now rather than touching the init flag for a value the
# server is going to refuse anyway.
INIT_STORE_ENABLED=$(printf '%s' "${HG_SERVER_INIT_STORE_ENABLED:-}" |
                     tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
case "${INIT_STORE_ENABLED}" in
    "" | y | t | yes | on | true | n | f | no | off | false) ;;
    *) log "ERROR: invalid HG_SERVER_INIT_STORE_ENABLED" \
           "'${HG_SERVER_INIT_STORE_ENABLED}'"
       exit 1 ;;
esac
[[ -n "${INIT_STORE_ENABLED}" ]] && \
    set_prop "init_store.enabled" "${INIT_STORE_ENABLED}" "${REST_SERVER_CONF}"

# ── Build wait-storage env ─────────────────────────────────────────────
WAIT_ENV=()
[[ -n "${HG_SERVER_BACKEND:-}"  ]] && WAIT_ENV+=("hugegraph.backend=${HG_SERVER_BACKEND}")
[[ -n "${HG_SERVER_PD_PEERS:-}" ]] && WAIT_ENV+=("hugegraph.pd.peers=${HG_SERVER_PD_PEERS}")

# ── Init store ────────────────────────────────────────────────────────
# init-store owns the marker: it skips re-initialization when the marker is
# present and writes it only after it has actually initialized. Deciding here
# would mean guessing from the environment variable, which says nothing about
# a config mounted with the property already set. Absolute, so the in-Java
# existence check agrees with the guard below no matter where init-store.sh
# leaves its working directory.
INIT_MARKER_PATH="$(cd "${DOCKER_FOLDER}" && pwd)/${INIT_FLAG_FILE}"
export HG_SERVER_INIT_COMPLETE_MARKER="${INIT_MARKER_PATH}"

if [[ ! -f "${INIT_MARKER_PATH}" ]]; then
    if (( ${#WAIT_ENV[@]} > 0 )); then
        env "${WAIT_ENV[@]}" ./bin/wait-storage.sh
    else
        ./bin/wait-storage.sh
    fi

    if [[ -z "${PASSWORD:-}" ]]; then
        log "init hugegraph with non-auth mode"
        ./bin/init-store.sh
    else
        log "init hugegraph with auth mode"
        # init-store reads the password from stdin, and a disabled one returns
        # before it gets there, so say plainly that PASSWORD is being dropped
        case "${INIT_STORE_ENABLED}" in
            n | f | no | off | false)
                log "init-store does not read PASSWORD while disabled;" \
                    "the entrypoint applies it through 'auth.admin_pa' for" \
                    "the PD startup path" ;;
        esac
        printf '%s\n' "${PASSWORD}" | ./bin/init-store.sh
    fi
else
    log "HugeGraph initialization already done. Revalidating the config..."
    # The marker skips re-initialization inside init-store, not init-store
    # itself: a disabled one must pass its fail-closed check on every startup,
    # because the marker may predate this configuration or this release and
    # says nothing about whether the admin the current config relies on is
    # reachable. An enabled one returns at the marker, before it touches the
    # backend or reads stdin, so neither wait-storage nor PASSWORD is needed.
    ./bin/init-store.sh
fi

./bin/start-hugegraph.sh -j "${JAVA_OPTS:-}" -t 120

# Post-startup cluster stabilization check (hstore only — rocksdb has no partitions)
# Read through props.awk so a mounted config using the `:` or bare-whitespace
# separator is seen at all, and first-definition-wins matches HugeConfig; the
# grep this replaces only ever accepted `=`.  Trailing whitespace is dropped
# here rather than in the reader, which reports the on-disk bytes verbatim.
ACTUAL_BACKEND=$(get_prop_encoded "backend" "${GRAPH_CONF}" | tr -d '[:space:]' || true)
if [[ "${ACTUAL_BACKEND}" == "hstore" ]]; then
    STORE_REST="${STORE_REST:-store:8520}"
    export STORE_REST
    ./bin/wait-partition.sh || log "WARN: partitions not assigned yet"
fi

PID=$(cat ./bin/pid 2>/dev/null || true)
if [[ -n "$PID" ]]; then
    trap 'kill -TERM "$PID" 2>/dev/null; while kill -0 "$PID" 2>/dev/null; do sleep 1; done; exit 0' TERM INT
    tail --pid="$PID" -f /dev/null
    exit 1
fi
