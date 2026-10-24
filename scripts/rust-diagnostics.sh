#!/bin/sh
# Collect a compact Rust/Cargo diagnostic report inside iSH/Alpine.
# This script does not install packages or modify the project.

set +e
printf '%s\n' '=== iSH More Rust diagnostics ==='
printf 'date: '; date -u 2>&1
printf 'kernel: '; uname -a 2>&1
printf 'architecture: '; uname -m 2>&1
if [ -r /etc/alpine-release ]; then
    printf 'Alpine: '; cat /etc/alpine-release 2>&1
else
    printf '%s\n' 'Alpine: /etc/alpine-release not found'
fi

if command -v apk >/dev/null 2>&1; then
    printf '\n%s\n' '--- package information ---'
    apk --version 2>&1
    apk info -e cargo 2>&1
    apk info -e rust 2>&1
fi

for tool in cargo rustc; do
    printf '\n--- %s ---\n' "$tool"
    if command -v "$tool" >/dev/null 2>&1; then
        printf 'path: '; command -v "$tool"
        "$tool" --version 2>&1
        rc=$?
        printf 'exit status: %s\n' "$rc"
    else
        printf '%s\n' 'not found in PATH'
    fi
done

printf '\n%s\n' '--- environment ---'
printf 'PATH=%s\n' "$PATH"
printf 'RUSTFLAGS=%s\n' "${RUSTFLAGS-}"
printf 'CARGO_HOME=%s\n' "${CARGO_HOME-}"
printf 'RUSTUP_HOME=%s\n' "${RUSTUP_HOME-}"

if [ "${1-}" = '--check' ]; then
    if command -v cargo >/dev/null 2>&1 && [ -f Cargo.toml ]; then
        printf '\n%s\n' '--- cargo check -v ---'
        cargo check -v 2>&1
        rc=$?
        printf 'cargo check exit status: %s\n' "$rc"
    else
        printf '%s\n' 'Skip cargo check: Cargo or Cargo.toml not found.'
    fi
else
    printf '\n%s\n' 'Build was not run. From a project directory, use: sh rust-diagnostics.sh --check'
fi
