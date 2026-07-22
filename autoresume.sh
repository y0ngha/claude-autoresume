#!/usr/bin/env bash
# ============================================================================
# claude-autoresume 감시자 (launchd 가 백그라운드 상시 실행)
#  - TMUX_SESSION 의 모든 window 를 INTERVAL 마다 훑어 상태를 분류(classify):
#    · limit(텍스트)  → resets 시각 지나면 CONTINUE_PROMPT 주입해 제자리 재개
#    · limit(선택메뉴)→ "Stop and wait for limit to reset"(1번) 자동 선택
#    · blocked        → 자동재개 안 함(알림만)
#    · 모든 상태 전이 → 상태별 NOTIFY_* 플래그에 따라 macOS 알림
#  - disabled.list 에 있는 창은 자동재개(주입/선택)에서 제외(알림은 유지)
# ============================================================================
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$DIR/config.sh"

STATE="$DIR/state"; mkdir -p "$STATE"
LOG="$DIR/autoresume.log"
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

log() { echo "[$(date '+%F %T')] $*" >> "$LOG"; }
notify() { osascript -e "display notification \"$2\" with title \"$1\" sound name \"${3:-Glass}\"" 2>/dev/null; }
tf() { printf "$(t "$1")" "${@:2}"; }   # i18n 포맷 헬퍼: tf <key> [args...]

# 로그 무한 증가 방지: 1MB 넘으면 최근 800줄만 남김(24/7 운영 대비)
LOG_MAX_BYTES=1048576
rotate_log() {
  local sz; sz="$(stat -f%z "$LOG" 2>/dev/null || echo 0)"
  [ "$sz" -gt "$LOG_MAX_BYTES" ] && { tail -n 800 "$LOG" > "$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG"; }
}
# 닫힌 창(현재 window index 목록에 없는)에 대한 상태파일 정리
prune_orphans() {
  local live f base idx
  live="$(tmux list-windows -t "$TMUX_SESSION" -F '#{window_index}' 2>/dev/null)"
  [ -z "$live" ] && return
  for f in "$STATE/${TMUX_SESSION}-"*; do
    [ -e "$f" ] || continue
    base="${f##*/}"; base="${base#"${TMUX_SESSION}-"}"; idx="${base%%.*}"
    case "$idx" in ''|*[!0-9]*) continue ;; esac
    printf '%s\n' "$live" | grep -qx "$idx" || rm -f "$f"
  done
}

log "$(tf lg_start "$TMUX_SESSION" "$INTERVAL" "$MIN_RESEND_GAP")"

# 상태 '전이' 알림: 창 상태가 안정적으로 바뀌면 그 상태의 NOTIFY_* 플래그에 따라 1회 알림.
#   상태(classify): working|background|limit|blocked|idle
notify_transition() {
  local idx="$1" name="$2" cur="$3"
  local lf="$STATE/${TMUX_SESSION}-${idx}.pstate"
  local cf="$STATE/${TMUX_SESSION}-${idx}.pcount"
  local nf="$STATE/${TMUX_SESSION}-${idx}.pnotified"
  local last cnt notified flag emoji sound
  last="$(cat "$lf" 2>/dev/null || echo)"; echo "$cur" > "$lf"
  cnt="$(cat "$cf" 2>/dev/null || echo 0)"
  notified="$(cat "$nf" 2>/dev/null || echo)"
  if [ "$cur" != "$last" ]; then echo 0 > "$cf"; return; fi   # 아직 바뀌는 중 → 안정 대기
  cnt=$((cnt+1)); echo "$cnt" > "$cf"
  [ "$cnt" -ge 1 ] || return          # 2회 연속(직전+현재) 같아야 안정
  [ "$cur" = "$notified" ] && return  # 이미 이 상태로 알림함
  echo "$cur" > "$nf"
  case "$cur" in
    working)    flag="${NOTIFY_WORKING:-0}";    emoji="🟢"; sound="Glass" ;;
    background) flag="${NOTIFY_BACKGROUND:-0}";  emoji="🔵"; sound="Glass" ;;
    limit)      flag="${NOTIFY_LIMIT:-0}";       emoji="🟡"; sound="Basso" ;;
    blocked)    flag="${NOTIFY_BLOCKED:-0}";     emoji="⛔"; sound="Basso" ;;
    idle)       flag="${NOTIFY_IDLE:-0}";        emoji="✅"; sound="Glass" ;;
    *) return ;;
  esac
  [ "$flag" = 1 ] && [ -n "$name" ] || return
  log "$(tf lg_state "$emoji" "$cur" "$TMUX_SESSION:$idx" "$name")"
  notify "$(t "ntf_${cur}_title")" "$(tf "ntf_${cur}_body" "$name")" "$sound"
}

scan_once() {
  rotate_log
  if ! tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
    # 세션이 없을 때 매 스캔마다 찍으면 로그가 폭증하므로 5분에 한 번만 기록.
    local nf="$STATE/.nosession" nlast now2
    nlast=0; [ -f "$nf" ] && nlast="$(cat "$nf" 2>/dev/null || echo 0)"
    now2="$(date +%s)"
    if [ $(( now2 - nlast )) -ge 300 ]; then echo "$now2" > "$nf"; log "$(tf lg_no_session "$TMUX_SESSION")"; fi
    return
  fi
  prune_orphans

  while IFS=$'\t' read -r idx name; do
    # window_index 는 항상 숫자. 아니면(탭 파싱 깨짐 등) 잘못된 행 → 스킵.
    case "$idx" in ''|*[!0-9]*) continue ;; esac
    target="$TMUX_SESSION:$idx"
    content="$(tmux capture-pane -p -t "$target" 2>/dev/null | tail -n "$CAPTURE_LINES")"
    # capture 실패/빈 화면이면 오판하지 않도록 스킵.
    [ -z "$content" ] && continue
    now="$(date +%s)"

    state="$(printf '%s' "$content" | classify)"
    notify_transition "$idx" "$name" "$state"     # 상태 전이 알림(플래그별)

    # limit 외 상태(working/background/idle/blocked)는 데몬 자동재개 액션 없음.
    [ "$state" = limit ] || continue

    # 한도대기 상태에서만 자동재개(선택/주입). 제외 창은 스킵(알림은 위에서 이미 처리).
    if is_disabled "$name"; then
      ef="$STATE/${TMUX_SESSION}-${idx}.excllog"
      elast=0; [ -f "$ef" ] && elast="$(cat "$ef" 2>/dev/null || echo 0)"
      if [ $(( now - elast )) -ge "$MIN_RESEND_GAP" ]; then
        echo "$now" > "$ef"; log "$(tf lg_excluded "$target" "$name")"
      fi
      continue
    fi

    # (1) 활성 한도 선택 메뉴 → "Stop and wait for limit to reset"(1번) 자동 선택.
    #     선택만으로는 재개되지 않으므로, 이후 리셋이 지나면 (2)에서 주입이 이어짐.
    if printf '%s' "$content" | match_limit_menu; then
      mf="$STATE/${TMUX_SESSION}-${idx}.menu"
      mlast=0; [ -f "$mf" ] && mlast="$(cat "$mf" 2>/dev/null || echo 0)"
      if [ $(( now - mlast )) -ge "$MIN_RESEND_GAP" ]; then
        echo "$now" > "$mf"
        tmux send-keys -t "$target" Up Up      # 커서를 최상단(1번)으로
        sleep 0.3
        tmux send-keys -t "$target" Enter      # 확정
        log "$(tf lg_menu "$target" "$name")"
      fi
      continue
    fi

    # (2) 텍스트형 세션 한도 → resets 시각 지나면 CONTINUE_PROMPT 주입(제자리 재개).
    sf="$STATE/${TMUX_SESSION}-${idx}.last"
    last=0; [ -f "$sf" ] && last="$(cat "$sf" 2>/dev/null || echo 0)"
    rep="$(printf '%s' "$content" | reset_epoch)"
    case "$rep" in
      PASSED) waiting=0; lbl="$(t lbl_passed)" ;;
      "")     waiting=0; lbl="$(t lbl_unknown)" ;;
      *)      if [ "$now" -lt $(( rep + RESET_BUFFER )) ]; then waiting=1; else waiting=0; lbl="$(t lbl_passed)"; fi ;;
    esac
    if [ "$waiting" = 1 ]; then
      wf="$STATE/${TMUX_SESSION}-${idx}.waitlog"
      wlast=0; [ -f "$wf" ] && wlast="$(cat "$wf" 2>/dev/null || echo 0)"
      if [ $(( now - wlast )) -ge 300 ]; then
        echo "$now" > "$wf"
        log "$(tf lg_waiting "$target" "$(date -r "$rep" '+%H:%M')" "$name")"
      fi
    elif [ $(( now - last )) -ge "$MIN_RESEND_GAP" ]; then
      tmux send-keys -t "$target" -l "$CONTINUE_PROMPT"
      sleep 1
      tmux send-keys -t "$target" Enter
      echo "$now" > "$sf"
      log "$(tf lg_inject "$lbl" "$target" "$name")"
    else
      log "$(tf lg_gap "$target")"
    fi
  done < <(tmux list-windows -t "$TMUX_SESSION" -F '#{window_index}	#{window_name}' 2>/dev/null)
}

if [ "${1:-}" = "--once" ]; then scan_once; exit 0; fi
while true; do scan_once; sleep "$INTERVAL"; done
