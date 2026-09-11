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

# The pinned em_proxy checkout still requests the legacy loose assets from the
# latest release. Current tagged releases contain only an XCFramework, while
# the legacy rolling "build" release still supplies the files this project
# references. Download to temporary files first so a 404 can never truncate a
# previously valid bridge or archive.
asset_base_url="https://github.com/SideStore/em_proxy/releases/download/build"
asset_marker="${em_proxy_dir}/.multistore-em-proxy-build-assets-v1"
assets=(libem_proxy-sim.a libem_proxy-ios.a em_proxy.h em_proxy.swift)

needs_assets=false
if [[ ! -f "${asset_marker}" ]]; then
    needs_assets=true
fi
for asset in "${assets[@]}"; do
    if [[ ! -s "${em_proxy_dir}/${asset}" ]]; then
        needs_assets=true
    fi
done

if [[ "${needs_assets}" == true ]]; then
    for asset in "${assets[@]}"; do
        curl --fail --location --retry 3 --retry-delay 1 \
            --output "${em_proxy_dir}/.${asset}.download" \
            "${asset_base_url}/${asset}"
        test -s "${em_proxy_dir}/.${asset}.download"
    done

    verify_asset() {
        local asset="$1"
        local expected="$2"
        local actual
        actual="$(shasum -a 256 "${em_proxy_dir}/.${asset}.download" | awk '{print $1}')"
        if [[ "${actual}" != "${expected}" ]]; then
            echo "Checksum mismatch for ${asset}." >&2
            exit 1
        fi
    }

    verify_asset libem_proxy-sim.a 8b9b1181d2333c99360587b7b17cdc9e297250ed32574b47d5731584dbd755c4
    verify_asset libem_proxy-ios.a f88c64e4444f4a14919f19e2f8f826967908475698b8babbdca71b34c077064a
    verify_asset em_proxy.h ac754452d420a6840a707d698ce98eaf36f167d006c5b1c5a16f37fcd57717d9
    verify_asset em_proxy.swift c89e4c05cdd886a63993e6e50002a448816b1c966c068e443f2f4c5fa5248848

    for asset in "${assets[@]}"; do
        mv -f "${em_proxy_dir}/.${asset}.download" "${em_proxy_dir}/${asset}"
    done
    touch "${asset_marker}"
    echo "Installed verified em_proxy legacy build assets."
fi

# Prevent the submodule's outdated build phase from replacing the verified
# files with 404 response bodies from the latest tagged release.
touch "${em_proxy_dir}/.skip-prebuilt-fetch-em_proxy"
