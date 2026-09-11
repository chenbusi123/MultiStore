#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
em_proxy_dir="${repo_root}/Dependencies/em_proxy"
patch_file="${repo_root}/patches/em-proxy-copy-prebuilt.patch"
project_file="${em_proxy_dir}/em_proxy.xcodeproj/project.pbxproj"

if [[ ! -f "${project_file}" ]]; then
    echo "em_proxy project is missing. Initialize submodules first." >&2
    exit 1
fi

if grep -Fq 'ln -f -- \"$BUILT_SRC\"' "${project_file}"; then
    git -C "${em_proxy_dir}" apply --check "${patch_file}"
    git -C "${em_proxy_dir}" apply "${patch_file}"
    echo "Applied em_proxy prebuilt-library copy fix."
elif grep -Fq 'cp \"$BUILT_SRC\" \"$TARGET_BUILD_DIR/$EXECUTABLE_PATH\"' "${project_file}"; then
    echo "em_proxy prebuilt-library copy fix is already applied."
else
    echo "em_proxy build rule has an unexpected format; refusing to patch it." >&2
    exit 1
fi
