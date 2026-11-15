#!/bin/sh
# Builds tests/EngineTests.swift with the app's engine and checks it against the page's answers.
set -e
cd "$(dirname "$0")/.."
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
node tests/engine-fixtures.mjs "$work"
swiftc -O -parse-as-library JuiceTracker/Engine.swift tests/EngineTests.swift -o "$work/engine-tests"
"$work/engine-tests" "$work"
