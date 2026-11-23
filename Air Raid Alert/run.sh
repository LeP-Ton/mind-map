#!/bin/bash
set -euo pipefail

cd -- "$(dirname -- "$0")"

# 命令行工具缺少包管理器模块时，使用本机已有的完整 Xcode。
if [[ -z "${DEVELOPER_DIR:-}" &&
      "$(xcode-select -p 2>/dev/null)" == /Library/Developer/CommandLineTools &&
      -d /Applications/Xcode.app/Contents/Developer ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

swift build --product AirRaidAlert
exec .build/debug/AirRaidAlert "$@"
