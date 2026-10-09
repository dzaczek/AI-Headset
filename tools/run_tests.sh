#!/bin/bash
# Buduje i uruchamia testy jednostkowe z tools/. Wpis = nazwa testu
# (tools/<nazwa>.swift) i pliki aplikacji, których używa. Test jest
# kopiowany jako main.swift, bo tylko tam swiftc pozwala na kod
# najwyższego poziomu przy kompilacji wielu plików.
#
# Bez sieci i bez urządzeń audio. Klucze w osobnym koncie Keychain.
set -euo pipefail
cd "$(dirname "$0")/.."

A=daemon/AIHeadset
TESTS=(
    "transcript_store_test: $A/TranscriptModel.swift $A/TranscriptStore.swift"
)

OUT=build/tests
mkdir -p "$OUT"
failed=0
for entry in "${TESTS[@]}"; do
    name="${entry%%:*}"
    deps="${entry#*:}"
    dir="$OUT/$name"
    mkdir -p "$dir"
    cp "tools/$name.swift" "$dir/main.swift"
    # shellcheck disable=SC2086
    if ! swiftc -o "$dir/$name" "$dir/main.swift" $deps 2>"$dir/build.log"; then
        echo "BUILD FAIL  $name"
        cat "$dir/build.log"
        failed=1
        continue
    fi
    if (cd "$dir" && AIHEADSET_TEST_KEYCHAIN_SUFFIX=unit-test "./$name"); then
        echo "PASS        $name"
    else
        echo "FAIL        $name"
        failed=1
    fi
done
exit $failed
