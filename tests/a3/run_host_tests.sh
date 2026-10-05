#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
build=$(mktemp -d)
trap 'rm -rf "$build"' EXIT
"${CXX:-g++}" -std=c++11 -Wall -Wextra -Werror -pedantic -fsanitize=address,undefined -fno-omit-frame-pointer tests/a3/policy_test.cpp -o "$build/policy_test"
ASAN_OPTIONS=detect_leaks=0 "$build/policy_test"
"${CXX:-g++}" -std=c++11 -Wall -Wextra -Werror -Wno-unused-function -pedantic -fsanitize=address,undefined -fno-omit-frame-pointer tests/a3/storage_test.cpp -o "$build/storage_test"
ASAN_OPTIONS=detect_leaks=0 "$build/storage_test"
