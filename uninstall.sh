#!/usr/bin/env bash
# ============================================================================
# claude-autoresume 제거기 — 데몬 내리고 plist 삭제.
#   (스크립트/설정 폴더와 .zshrc source 줄은 안내만; --purge 로 폴더까지 삭제)
# 사용:  bash ~/Project/claude-autoresume/uninstall.sh [--purge]
# ============================================================================
set -e
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$DIR/config.sh"
LABEL="$DAEMON_LABEL"
MYUID="$(id -u)"

printf "$(t un_title)\n"
launchctl bootout "gui/$MYUID/$LABEL" 2>/dev/null && printf "$(t un_booted)\n" "$LABEL" || true
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist" && printf "$(t un_plist)\n" "$LABEL.plist" || true

echo
printf "$(t un_manual)\n"
printf "$(t un_zsh)\n"
if [ "${1:-}" = "--purge" ]; then
  read -r -p "$(printf "$(t un_purge_ask)" "$DIR")" a
  [ "$a" = y ] && { rm -rf "$DIR"; printf "$(t un_purged)\n"; } || printf "$(t un_canceled)\n"
else
  printf "$(t un_purge_hint)\n" "$DIR"
fi
