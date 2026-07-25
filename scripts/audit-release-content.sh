#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

audit_temporary_file=""
audit_filtered_file=""

cleanup() {
    if [[ -n "${audit_temporary_file}" ]]; then
        rm -f -- "${audit_temporary_file}"
    fi
    if [[ -n "${audit_filtered_file}" ]]; then
        rm -f -- "${audit_filtered_file}"
    fi
}

trap cleanup EXIT

# Build the expressions from fragments so this audit script never satisfies its
# own searches. Keep matches out of logs because a match may itself be secret.
legacy_dependency="swift""-rpsl"
legacy_type="RPSL""ASNumber"
legacy_import="import R""PSL"

mac_home="/""Users/"
linux_home="/""home/[^/]+/"
private_var="/""private/var/"
file_url="file:""///"

private_key="-----BE""GIN (OPENSSH |RSA |EC |DSA |ENCRYPTED )?PRIVATE KEY-----"
aws_key="(A""KIA|A""SIA)[0-9A-Z]{16}"
github_token="gh""[pousr]_[A-Za-z0-9]{20,}"
github_pat="github""_pat_[A-Za-z0-9_]{20,}"
slack_token="xo""x[baprs]-[A-Za-z0-9-]{20,}"
api_key="sk""-(live|proj)-[A-Za-z0-9_-]{16,}"

audit_tracked_tree() {
    local status

    if git -C "${PACKAGE_ROOT}" grep --quiet -I -E \
        -e "${legacy_dependency}" \
        -e "${legacy_type}" \
        -e "${legacy_import}" \
        -- .; then
        fail "Tracked files contain a removed private dependency reference."
    else
        status=$?
        [[ ${status} -eq 1 ]] || fail "Unable to audit tracked dependency references."
    fi

    if git -C "${PACKAGE_ROOT}" grep --quiet -I -E \
        -e "${mac_home}" \
        -e "${linux_home}" \
        -e "${private_var}" \
        -e "${file_url}" \
        -- .; then
        fail "Tracked files contain a local absolute path."
    else
        status=$?
        [[ ${status} -eq 1 ]] || fail "Unable to audit tracked local paths."
    fi

    if git -C "${PACKAGE_ROOT}" grep --quiet -I -E \
        -e "${private_key}" \
        -e "${aws_key}" \
        -e "${github_token}" \
        -e "${github_pat}" \
        -e "${slack_token}" \
        -e "${api_key}" \
        -- .; then
        fail "Tracked files contain a credential or private-key marker."
    else
        status=$?
        [[ ${status} -eq 1 ]] || fail "Unable to audit tracked sensitive markers."
    fi
}

audit_binary() {
    local binary="$1"
    local path_pattern
    local raw_path_pattern
    local status
    local upstream_runtime_path
    local upstream_toolchain_path

    [[ -f "${binary}" ]] || fail "Binary not found: ${binary}"
    command -v strings >/dev/null 2>&1 || fail "Required command not found: strings"

    audit_temporary_file="$(mktemp)"
    audit_filtered_file="$(mktemp)"
    # Inspect every data section consistently on Darwin and Linux; the default
    # Apple `strings` selection omits Mach-O sections that GNU `strings` examines.
    LC_ALL=C strings -a "${binary}" >"${audit_temporary_file}"

    # Static Swift runtime archives contain source locations from the official
    # toolchain build. They are public upstream paths rather than runner paths.
    upstream_toolchain_path="^/""home/build-user/swift(-experimental-string-processing)?/"
    # Static Foundation contains this literal system lookup path on Linux; it
    # is runtime behavior, not a path to the source tree or release runner.
    upstream_runtime_path="^/""private/var/automount/$"
    grep -E -v \
        -e "${upstream_toolchain_path}" \
        -e "${upstream_runtime_path}" \
        "${audit_temporary_file}" >"${audit_filtered_file}"

    path_pattern="(${mac_home}|${linux_home}|${private_var}|/workspace(/|$)|/github/workspace(/|$)|/__w/|/builds?(/|$)|/runner/_work/|[.]build/)"
    if grep --quiet -E "${path_pattern}" "${audit_filtered_file}"; then
        fail "Release binary contains a workspace, home, or build path."
    else
        status=$?
        [[ ${status} -eq 1 ]] || fail "Unable to audit release binary paths."
    fi

    # Apple's `strings` does not inspect every Mach-O section that GNU `strings`
    # examines. Scan raw bytes for non-toolchain path families so the build job and the
    # Linux assembly job enforce the same artifact policy.
    # The filtered `strings -a` pass checks Linux home and private-var paths because
    # static Swift runtime libraries contain reviewed upstream literals in those
    # families. Keep this unfiltered byte scan to path families with no such exception.
    raw_path_pattern="(${mac_home}|/workspace(/|$)|/github/workspace(/|$)|/__w/|/builds?(/|$)|/runner/_work/|[.]build/)"
    if LC_ALL=C grep -a --quiet -E "${raw_path_pattern}" "${binary}"; then
        fail "Release binary contains a workspace, home, or build path."
    else
        status=$?
        [[ ${status} -eq 1 ]] || fail "Unable to audit raw release binary paths."
    fi

    if grep --quiet -E \
        -e "${private_key}" \
        -e "${aws_key}" \
        -e "${github_token}" \
        -e "${github_pat}" \
        -e "${slack_token}" \
        -e "${api_key}" \
        "${audit_temporary_file}"; then
        fail "Release binary contains a credential or private-key marker."
    else
        status=$?
        [[ ${status} -eq 1 ]] || fail "Unable to audit release binary markers."
    fi

    cleanup
    audit_temporary_file=""
    audit_filtered_file=""
}

case "${1:-}" in
tree)
    [[ $# -eq 1 ]] || fail "Usage: audit-release-content.sh tree"
    audit_tracked_tree
    ;;
binary)
    [[ $# -eq 2 ]] || fail "Usage: audit-release-content.sh binary PATH"
    audit_binary "$2"
    ;;
*)
    fail "Usage: audit-release-content.sh {tree|binary PATH}"
    ;;
esac
