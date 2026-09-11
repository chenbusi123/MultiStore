#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
altsign_dir="${repo_root}/Dependencies/AltSign"
patch_file="${repo_root}/patches/altsign-gsa-login.patch"
auth_source="${altsign_dir}/Sources/ALTAppleAPI+Authentication.swift"

if [[ ! -f "${auth_source}" ]]; then
    echo "AltSign authentication source is missing. Initialize submodules first." >&2
    exit 1
fi

if grep -q 'AltSign\.AuthenticationResponse' "${auth_source}"; then
    echo "AltSign GSA login compatibility patch is already applied."
    exit 0
fi

git -C "${altsign_dir}" apply --check "${patch_file}"
git -C "${altsign_dir}" apply "${patch_file}"
echo "Applied AltSign GSA login compatibility patch."
