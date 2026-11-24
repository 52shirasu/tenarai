#!/bin/sh
set -eu

swift_configuration=debug
if [ "${CONFIGURATION}" = "Release" ]; then
    swift_configuration=release
fi

swift build --package-path "${SRCROOT}/Core" --product ConverterServer -c "${swift_configuration}"
# 流行語の一覧を週1回作り直す更新プログラム。通信するのはこのプログラムだけで、
# Foundation だけに依存する（リソースバンドルや Frameworks は要らない）。
swift build --package-path "${SRCROOT}/Core" --product TrendWordsUpdater -c "${swift_configuration}"

server_source="${SRCROOT}/Core/.build/${swift_configuration}/ConverterServer"
server_directory="${TARGET_BUILD_DIR}/${CONTENTS_FOLDER_PATH}/Helpers/ConverterServer"
server_destination="${server_directory}/ConverterServer"
server_build_directory="${SRCROOT}/Core/.build/${swift_configuration}"
mkdir -p "${server_directory}"
cp "${server_source}" "${server_destination}"

# SwiftPM の Bundle.module は、実行時に Bundle.main.bundleURL 直下を最初に探し、
# 見つからない場合はビルド時の絶対パスへフォールバックする。Helperを独立した
# Contents/Helpers配下のdirectoryに置くと、そのdirectoryがBundle.mainになるため、
# resource bundleも同じ場所に置ける。app bundle root直下はcodesignで許可されない。
for resource_bundle in "${server_build_directory}"/*.bundle; do
    if [ -d "${resource_bundle}" ]; then
        resource_bundle_name="$(basename "${resource_bundle}")"
        embedded_resource_bundle="${server_directory}/${resource_bundle_name}"
        ditto "${resource_bundle}" "${embedded_resource_bundle}"
        # command-line SwiftPM buildが生成するbundleはInfo.plistを持たないため、
        # archiveのcodesignが正規のresource bundleとして検証できるよう補う。
        cp "${SRCROOT}/Tools/ConverterServerResourceBundleInfo.plist" "${embedded_resource_bundle}/Info.plist"
    fi
done

# General n-gram model that the personal model is compared against (Zenzai
# personalization). The helper verifies its SHA-256 before use.
base_lm_source="${SRCROOT}/azooKeyMac/Resources/base_n5_lm"
# The helper's Bundle.main resolves to the app, so this goes in the app's Resources.
base_lm_destination="${TARGET_BUILD_DIR}/${CONTENTS_FOLDER_PATH}/Resources/base_n5_lm"
mkdir -p "${base_lm_destination}"
for suffix in c_abc r_xbx u_abx u_xbc; do
    cp "${base_lm_source}/lm_${suffix}.marisa" "${base_lm_destination}/lm_${suffix}.marisa"
done

if ! otool -l "${server_destination}" | grep -q "@executable_path/../../Frameworks"; then
    install_name_tool -add_rpath "@executable_path/../../Frameworks" "${server_destination}"
fi

updater_source="${SRCROOT}/Core/.build/${swift_configuration}/TrendWordsUpdater"
updater_directory="${TARGET_BUILD_DIR}/${CONTENTS_FOLDER_PATH}/Helpers/TrendWordsUpdater"
updater_destination="${updater_directory}/TrendWordsUpdater"
mkdir -p "${updater_directory}"
cp "${updater_source}" "${updater_destination}"

if [ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ] && [ "${EXPANDED_CODE_SIGN_IDENTITY}" != "-" ]; then
    server_identifier="${PRODUCT_BUNDLE_IDENTIFIER}.ConverterServer"
    # ConverterServerも学習データや個人化モデルをApp Groupから読む。entitlementなしで
    # Group Containersを直接参照すると、macOSが「ほかのアプリのデータ」と判定して
    # ファイルごとのアクセス確認を表示するため、埋め込みHelperにも同じGroupを付与する。
    codesign \
        --force \
        --sign "${EXPANDED_CODE_SIGN_IDENTITY}" \
        --identifier "${server_identifier}" \
        --options runtime \
        --entitlements "${SRCROOT}/azooKeyMac/ConverterServer.entitlements" \
        --timestamp=none \
        "${server_destination}"
    codesign --verify --strict "${server_destination}"

    updater_identifier="${PRODUCT_BUNDLE_IDENTIFIER}.TrendWordsUpdater"
    codesign \
        --force \
        --sign "${EXPANDED_CODE_SIGN_IDENTITY}" \
        --identifier "${updater_identifier}" \
        --options runtime \
        --timestamp=none \
        "${updater_destination}"
    codesign --verify --strict "${updater_destination}"

    for resource_bundle in "${server_directory}"/*.bundle; do
        if [ -d "${resource_bundle}" ]; then
            codesign \
                --force \
                --sign "${EXPANDED_CODE_SIGN_IDENTITY}" \
                --timestamp=none \
                "${resource_bundle}"
            codesign --verify --strict "${resource_bundle}"
        fi
    done
fi
