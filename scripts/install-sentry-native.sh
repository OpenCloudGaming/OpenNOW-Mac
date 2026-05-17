#!/usr/bin/env bash
set -euo pipefail

readonly repo="getsentry/sentry-native"
readonly project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly sdk_root="${project_root}/third_party/sentry-native"
readonly source_dir="${sdk_root}/source"
readonly build_dir="${sdk_root}/build"
readonly install_dir="${sdk_root}/install"
readonly build_type="${SENTRY_NATIVE_BUILD_TYPE:-RelWithDebInfo}"
readonly archs="${SENTRY_NATIVE_ARCHS:-arm64}"
readonly deployment_target="${SENTRY_NATIVE_DEPLOYMENT_TARGET:-14.0}"

resolve_version() {
    if [[ -n "${SENTRY_NATIVE_VERSION:-}" ]]; then
        printf '%s\n' "${SENTRY_NATIVE_VERSION}"
        return 0
    fi

    if command -v gh >/dev/null 2>&1; then
        gh release view --repo "${repo}" --json tagName --jq .tagName
        return 0
    fi

    printf 'latest\n'
}

download_release() {
    local version="$1"
    local zip_path="$2"

    if command -v gh >/dev/null 2>&1 && [[ "${version}" != "latest" ]]; then
        gh release download "${version}" --repo "${repo}" --pattern sentry-native.zip --clobber -D "${sdk_root}"
        mv "${sdk_root}/sentry-native.zip" "${zip_path}"
        return 0
    fi

    local url="https://github.com/${repo}/releases/latest/download/sentry-native.zip"
    if [[ "${version}" != "latest" ]]; then
        url="https://github.com/${repo}/releases/download/${version}/sentry-native.zip"
    fi
    curl -fL "${url}" -o "${zip_path}"
}

resolve_sdk_root() {
    if [[ -n "${SDKROOT:-}" ]]; then
        printf '%s\n' "${SDKROOT}"
        return 0
    fi

    xcrun --sdk macosx --show-sdk-path
}

main() {
    local version
    version="$(resolve_version)"
    local zip_path="${sdk_root}/sentry-native-${version}.zip"
    local macos_sdk
    macos_sdk="$(resolve_sdk_root)"

    mkdir -p "${sdk_root}"
    rm -rf "${source_dir}" "${build_dir}" "${install_dir}"

    download_release "${version}" "${zip_path}"
    mkdir -p "${source_dir}"
    unzip -q "${zip_path}" -d "${source_dir}"

    cmake -S "${source_dir}" -B "${build_dir}" \
        -DCMAKE_BUILD_TYPE="${build_type}" \
        -DCMAKE_OSX_ARCHITECTURES="${archs}" \
        -DCMAKE_OSX_DEPLOYMENT_TARGET="${deployment_target}" \
        -DCMAKE_OSX_SYSROOT="${macos_sdk}" \
        -DSENTRY_BUILD_TESTS=OFF \
        -DSENTRY_BUILD_EXAMPLES=OFF
    cmake --build "${build_dir}" --parallel
    cmake --install "${build_dir}" --prefix "${install_dir}" --config "${build_type}"

    printf 'Sentry Native %s installed to %s\n' "${version}" "${install_dir}"
}

main "$@"
