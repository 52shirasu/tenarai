#!/bin/sh
set -eu

agent_path="$1"
updater_path="$2"
service_name="${3:-local.tenarai.inputmethod.tenarai.TrendWordsUpdater}"

# 週1回（月曜 12:30）と読み込み時に1回走る。鮮度の確認があるので、
# 一覧が6日以内に作られていれば取得しない。常駐はしない（KeepAlive・MachServices なし）。
agent_dir="$(dirname "${agent_path}")"
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
        <string>${updater_path}</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>StartCalendarInterval</key>
    <dict>
        <key>Weekday</key>
        <integer>1</integer>
        <key>Hour</key>
        <integer>12</integer>
        <key>Minute</key>
        <integer>30</integer>
    </dict>
    <key>ProcessType</key>
    <string>Background</string>
    <key>LowPriorityIO</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/dev/null</string>
    <key>StandardErrorPath</key>
    <string>/dev/null</string>
</dict>
</plist>
PLIST
