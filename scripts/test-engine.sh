#!/bin/sh
# Builds tests/EngineTests.swift with the app's engine and checks it against tests/fixtures: the answers the old HTML
# page gave for the same inputs (frozen when the page was retired; they were made by tests/engine-fixtures.mjs).
set -e
cd "$(dirname "$0")/.."
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cp -R tests/fixtures/. "$work/"
swiftc -O -parse-as-library JuiceTracker/Engine.swift tests/EngineTests.swift -o "$work/engine-tests"
"$work/engine-tests" "$work"
