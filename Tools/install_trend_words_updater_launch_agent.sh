#!/bin/sh
set -eu

service_name="local.tenarai.inputmethod.tenarai.TrendWordsUpdater"
default_app_path="${BUILT_PRODUCTS_DIR:-/tmp/azooKeyDesktopDerivedData/Build/Products/Debug}/azooKeyMac.app"
app_path="${1:-${default_app_path}}"
updater_path="${app_path}/Contents/Helpers/TrendWordsUpdater/TrendWordsUpdater"
agent_dir="${HOME}/Library/LaunchAgents"
agent_path="${agent_dir}/${service_name}.plist"
gui_domain="gui/$(id -u)"
script_dir="$(cd "$(dirname "$0")" && pwd)"

if [ ! -x "${updater_path}" ]; then
    echo "TrendWordsUpdater not found: ${updater_path}" >&2
    echo "Build azooKeyMac first, or pass the app bundle path as the first argument." >&2
    exit 1
fi

"${script_dir}/write_trend_words_updater_launch_agent.sh" "${agent_path}" "${updater_path}" "${service_name}"

# kickstart はしない。RunAtLoad で1回走り、鮮度の確認があるので毎回は取得しない
launchctl bootout "${gui_domain}" "${agent_path}" >/dev/null 2>&1 || true
launchctl bootstrap "${gui_domain}" "${agent_path}"
launchctl print "${gui_domain}/${service_name}" >/dev/null

echo "Installed ${service_name}"
echo "${agent_path}"
