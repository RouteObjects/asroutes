#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

VERSION="${1:-}"
[[ "${VERSION}" =~ ^[0-9]+[.][0-9]+[.][0-9]+$ ]] ||
    fail "Usage: scripts/check-release.sh MAJOR.MINOR.PATCH"

cd "${PACKAGE_ROOT}"

[[ -z "$(git status --short)" ]] ||
    fail "Commit or stash package changes before running the release check."

for required in \
    LICENSE \
    THIRD_PARTY_NOTICES.txt \
    .swift-format.json \
    .github/workflows/ci.yml \
    .github/workflows/release.yml; do
    [[ -e "${required}" ]] || fail "Required release file is missing: ${required}"
done

while IFS= read -r swift_file; do
    grep -q 'SPDX-License-Identifier: Apache-2.0' "${swift_file}" ||
        fail "Apache license header is missing: ${swift_file}"
done < <(find Package.swift Sources Tests -name '*.swift' -type f -print)

"${SCRIPT_DIR}/audit-release-content.sh" tree

git diff --check
swift package resolve
git diff --exit-code -- Package.resolved
swift format lint \
    --configuration .swift-format.json \
    --recursive \
    --strict \
    Package.swift Sources Tests
swift build --product asroutes
"${SCRIPT_DIR}/test.sh"
if [[ "$(uname -s)" == "Linux" ]]; then
    swift build \
        -c release \
        --static-swift-stdlib \
        --product asroutes \
        -Xswiftc -debug-prefix-map \
        -Xswiftc "${PACKAGE_ROOT}=Source" \
        -Xcc "-ffile-prefix-map=${PACKAGE_ROOT}/.build=SwiftPMBuild"
else
    # Match the GitHub Actions Darwin build so the local release gate audits
    # the same remapped and stripped binary that will be placed in public archives.
    swift build \
        -c release \
        --product asroutes \
        -Xswiftc -file-prefix-map \
        -Xswiftc "${PACKAGE_ROOT}/.build=SwiftPMBuild" \
        -Xswiftc -file-prefix-map \
        -Xswiftc "${PACKAGE_ROOT}=Source" \
        -Xcc "-ffile-prefix-map=${PACKAGE_ROOT}/.build=SwiftPMBuild" \
        -Xcc "-ffile-prefix-map=${PACKAGE_ROOT}=Source"
fi

binary="$(swift build -c release --show-bin-path)/asroutes"
if [[ "$(uname -s)" == "Linux" ]]; then
    strip --strip-unneeded "${binary}"
elif [[ "$(uname -s)" == "Darwin" ]]; then
    strip -S -x "${binary}"
fi
[[ "$("${binary}" --version)" == "${VERSION}" ]] ||
    fail "The executable version does not match ${VERSION}."
"${binary}" --help >/dev/null
"${SCRIPT_DIR}/audit-release-content.sh" binary "${binary}"

if [[ "$(uname -s)" == "Linux" ]]; then
    readelf -d "${binary}" >.build/release-elf-dynamic-section.txt
    if grep -E 'NEEDED.*(libswift|libFoundation|libdispatch|libBlocksRuntime)' \
        .build/release-elf-dynamic-section.txt; then
        fail "The executable still requires a Swift runtime shared library."
    fi
fi

if [[ "$(uname -s)" == "Darwin" ]]; then
    sdk_path="$(xcrun --sdk iphonesimulator --show-sdk-path)"
    swift build \
        --target ASRoutesClient \
        --triple arm64-apple-ios18.0-simulator \
        --sdk "${sdk_path}"
fi

[[ -z "$(git status --short)" ]] ||
    fail "Release checks changed the working tree."

printf 'asroutes %s release checks passed.\n' "${VERSION}"
