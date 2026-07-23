#!/usr/bin/env bash
# ============================================================================
# claude-autoresume 설치기
#   1) tmux 확인/설치  2) 실행권한  3) launchd 데몬 등록/기동
#   4) .zshrc 에 셸 함수 source 추가
# 사용:  bash ~/Project/claude-autoresume/install.sh
# ============================================================================
set -e
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$DIR/config.sh"
LABEL="$DAEMON_LABEL"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
MYUID="$(id -u)"

printf "$(t in_title)\n" "$DIR"

# 1) tmux
if [ -x /opt/homebrew/bin/tmux ] || command -v tmux >/dev/null 2>&1; then
  printf "$(t in_tmux_ok)\n" "$(/opt/homebrew/bin/tmux -V 2>/dev/null || tmux -V)"
else
  printf "$(t in_tmux_get)\n"; brew install tmux; printf "$(t in_tmux_done)\n"
fi

# 1b) coreutils(gtimeout) — 데몬이 멈춘 tmux 에 무한 대기하지 않게. 없어도 동작(best-effort).
if ! command -v gtimeout >/dev/null 2>&1 && ! command -v timeout >/dev/null 2>&1; then
  if command -v brew >/dev/null 2>&1; then
    printf "$(t in_coreutils_get)\n"; brew install coreutils >/dev/null 2>&1 || printf "$(t in_coreutils_skip)\n"
  else
    printf "$(t in_coreutils_skip)\n"
  fi
fi

# 2) 실행권한 + 언어 파일(csm [l] 로 토글, 데몬도 공유). 이미 있으면 보존.
chmod +x "$DIR/autoresume.sh" "$DIR/session-manager.sh" 2>/dev/null || true
mkdir -p "$DIR/state"
[ -f "$DIR/lang" ] || echo "$CAR_LANG" > "$DIR/lang"

# 3) LaunchAgent plist 생성 + 로드
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array>
    <string>/bin/bash</string><string>$DIR/autoresume.sh</string>
  </array>
  <key>EnvironmentVariables</key><dict>
    <key>PATH</key><string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
    <key>TMUX_TMPDIR</key><string>/tmp</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>$DIR/launchd.out.log</string>
  <key>StandardErrorPath</key><string>$DIR/launchd.err.log</string>
</dict></plist>
PLIST_EOF
launchctl bootout "gui/$MYUID/$LABEL" 2>/dev/null || true
sleep 1   # bootout 이 비동기라 바로 bootstrap 하면 간헐적 'Bootstrap failed: 5'
launchctl bootstrap "gui/$MYUID" "$PLIST" || true
sleep 1
printf "$(t in_daemon)\n" "$(launchctl list | grep "$LABEL" || t in_daemon_fail)"

# 4) .zshrc 에 셸 함수 source 추가 (셸 함수는 zsh 전용)
case "${SHELL:-}" in *zsh) ;; *) printf "$(t in_not_zsh)\n" "${SHELL:-?}" ;; esac
SRC_LINE="source \"$DIR/shell-functions.zsh\""
if grep -qF "$DIR/shell-functions.zsh" "$HOME/.zshrc" 2>/dev/null; then
  printf "$(t in_zsh_have)\n"
elif grep -q 'claude-autoresume: tmux 런처' "$HOME/.zshrc" 2>/dev/null; then
  printf "$(t in_zsh_inline)\n"
else
  printf '\n# claude-autoresume shell functions\n%s\n' "$SRC_LINE" >> "$HOME/.zshrc"
  printf "$(t in_zsh_add)\n" "$SRC_LINE"
fi

echo
printf "$(t in_done)\n"
cat <<DONE
  cbg job1                          # start a session with default claude
  cbg job2 claude --resume          # args after the command pass through
  csm                               # dashboard (a attach / n new / k kill / p toggle / q quit)

  status:    launchctl list | grep $LABEL
  logs:      tail -f $DIR/autoresume.log
  uninstall: bash $DIR/uninstall.sh
DONE
