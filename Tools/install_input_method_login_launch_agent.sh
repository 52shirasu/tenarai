#!/bin/sh
set -eu

# ログイン時に入力メソッド本体を起動する LaunchAgent を登録する。
# ad-hoc 署名の開発用バンドルは、ログイン直後に入力ソースとして選ばれていても
# macOS が本体を起動しないことがあり、その間はキー入力を受け取れない。
# 常駐はしない（KeepAlive なし）。読み込み時に open を1回呼ぶだけ。

service_name="local.tenarai.inputmethod.tenarai.LoginLauncher"
app_path="${1:-${HOME}/Library/Input Methods/tenarai-Dev.app}"
agent_dir="${HOME}/Library/LaunchAgents"
agent_path="${agent_dir}/${service_name}.plist"
gui_domain="gui/$(id -u)"

if [ ! -d "${app_path}" ]; then
    echo "Input method bundle not found: ${app_path}" >&2
    exit 1
fi

mkdir -p "${agent_dir}"
cat > "${agent_path}" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${service_name}</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/bin/open</string>
        <string>-g</string>
        <string>${app_path}</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>ProcessType</key>
    <string>Background</string>
    <key>StandardOutPath</key>
    <string>/dev/null</string>
    <key>StandardErrorPath</key>
    <string>/dev/null</string>
</dict>
</plist>
PLIST

launchctl bootout "${gui_domain}" "${agent_path}" >/dev/null 2>&1 || true
launchctl bootstrap "${gui_domain}" "${agent_path}"
launchctl print "${gui_domain}/${service_name}" >/dev/null

echo "Installed ${service_name}"
echo "${agent_path}"
