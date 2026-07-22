#!/usr/bin/env bash
# ============================================================================
# Claude 세션 매니저 (csm) — tmux 컨트롤 패널 겸 실시간 대시보드
#  표시: 창별 프로필 / 상태(🟢작업 🟡한도대기 ⛔차단 ⚪유휴) / 사용량 잔량 /
#        resets 카운트다운 / 자동주입 이력 / ⏸자동재개 제외
#  키:  a 접속(창 선택)  n 새 세션  k 세션 종료  p 자동재개 토글
#       r 새로고침  q 종료
# ============================================================================
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$DIR/config.sh"
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
T="$TMUX_BIN"
STATE="$DIR/state"
RT="$DIR/.sm"; mkdir -p "$RT"
ONCE=0; [ "${1:-}" = "--once" ] && { ONCE=1; shift; }
REFRESH="${1:-10}"

B=$'\e[1m'; D=$'\e[2m'; R=$'\e[0m'
GRN=$'\e[32m'; YEL=$'\e[33m'; CYN=$'\e[36m'; RED=$'\e[31m'; GRY=$'\e[90m'; MAG=$'\e[35m'; BLU=$'\e[94m'

ago() { local s=$1  # 경과 시간
  if   [ "$s" -lt 60 ];   then printf "$(t ago_sec)" "$s"
  elif [ "$s" -lt 3600 ]; then printf "$(t ago_min)" "$((s/60))"
  else printf "$(t ago_hm)" "$((s/3600))" "$(((s%3600)/60))"; fi; }

left() { local s=$1  # 남은 시간
  if   [ "$s" -lt 60 ];   then printf "$(t left_sec)" "$s"
  elif [ "$s" -lt 3600 ]; then printf "$(t left_min)" "$((s/60))"
  else printf "$(t left_hm)" "$((s/3600))" "$(((s%3600)/60))"; fi; }

# 창의 claude 프로세스에서 프로필 유추 (사람마다 셋업이 달라도 동작, pane_pid 캐시)
#   우선순위: CLAUDE_CUSTOM_PROFILE > CLAUDE_CONFIG_DIR basename > "default"
profile_of() {
  local idx="$1" pane_pid cf cached p cmd envs prof cfgdir
  pane_pid="$($T display -p -t "$TMUX_SESSION:$idx" '#{pane_pid}' 2>/dev/null)"
  [ -z "$pane_pid" ] && return
  cf="$RT/${idx}.prof"
  if [ -f "$cf" ]; then
    cached="$(cat "$cf" 2>/dev/null)"
    [ "${cached%%|*}" = "$pane_pid" ] && { printf '%s' "${cached#*|}"; return; }
  fi
  for p in $(pgrep -P "$pane_pid" 2>/dev/null); do
    cmd="$(ps -o command= -p "$p" 2>/dev/null)"
    case "$cmd" in *claude*) ;; *) continue ;; esac        # claude 프로세스만
    envs="$(ps eww -p "$p" 2>/dev/null | tr ' ' '\n')"
    prof="$(printf '%s' "$envs" | grep -m1 '^CLAUDE_CUSTOM_PROFILE=' | cut -d= -f2)"
    if [ -z "$prof" ]; then
      cfgdir="$(printf '%s' "$envs" | grep -m1 '^CLAUDE_CONFIG_DIR=' | cut -d= -f2)"
      [ -n "$cfgdir" ] && { prof="$(basename "$cfgdir")"; prof="${prof#.claude-}"; prof="${prof#.claude}"; }
    fi
    [ -z "$prof" ] && prof="default"
    echo "${pane_pid}|${prof}" > "$cf"; printf '%s' "$prof"; return
  done
}

daemon() {
  if launchctl list 2>/dev/null | grep -q "$DAEMON_LABEL"; then
    printf '%s%s%s' "$GRN" "$(t daemon_on)" "$R"
  else printf '%s%s%s' "$RED" "$(t daemon_off)" "$R"; fi
}

draw() {
  local now; now=$(date +%s)
  printf '\e[H\e[2J'
  printf "%s%s%s  %s%s%s   %s\n" \
    "$B$CYN" "$(t title)" "$R" "$D" "$(date '+%H:%M:%S')" "$R" "$(daemon)"
  printf "%s$(t keys)%s\n\n" "$D" "$REFRESH" "$R"

  if ! $T has-session -t "$TMUX_SESSION" 2>/dev/null; then
    printf "   %s$(t no_session)%s\n" "$GRY" "$TMUX_SESSION" "$R"
    return
  fi

  local n=0 working=0 bg=0 limited=0 blocked=0 idle=0
  while IFS=$'\t' read -r idx name; do
    [ -z "$idx" ] && continue
    n=$((n+1))
    local cur curhash hashf chgf prevhash lastchg status inj sf prof pbadge usage ustr dis
    cur="$($T capture-pane -p -t "$TMUX_SESSION:$idx" 2>/dev/null | tail -n "$CAPTURE_LINES")"
    curhash="$(printf '%s' "$cur" | cksum | awk '{print $1}')"
    hashf="$RT/${idx}.hash"; chgf="$RT/${idx}.chg"
    prevhash=""; [ -f "$hashf" ] && prevhash="$(cat "$hashf" 2>/dev/null)"
    [ "$curhash" != "$prevhash" ] && echo "$now" > "$chgf"
    echo "$curhash" > "$hashf"
    lastchg="$now"; [ -f "$chgf" ] && lastchg="$(cat "$chgf" 2>/dev/null)"

    # 상태 판정은 데몬과 동일한 classify() 사용(작업중=esc to interrupt, 한도=텍스트/활성메뉴 등).
    local st2; st2="$(printf '%s' "$cur" | classify)"
    case "$st2" in
      working)    status="${GRN}$(t st_working)${R}"; working=$((working+1)) ;;
      blocked)    status="${RED}$(t st_blocked)${R}"; blocked=$((blocked+1)) ;;
      limit)      status="${YEL}$(t st_limit)${R}"; limited=$((limited+1))
                  local rep2; rep2="$(printf '%s' "$cur" | reset_epoch)"
                  case "$rep2" in ''|PASSED) : ;;
                    *) status="$status ${D}$(printf "$(t st_resets)" "$(date -r "$rep2" '+%H:%M')" "$(left $((rep2-now)))")${R}" ;;
                  esac ;;
      background) status="${BLU}$(t st_bg)${R}"; bg=$((bg+1)) ;;
      *)          status="${GRY}$(t st_idle)${R}"; idle=$((idle+1)) ;;
    esac

    prof="$(profile_of "$idx")"
    if [ -z "$prof" ]; then
      pbadge="${GRY}—       ${R}"
    else
      local pcol="$CYN"
      case "$(printf '%s' "$prof" | tr 'A-Z' 'a-z')" in
        *personal*)        pcol="$MAG" ;;
        *both*|*company*)  pcol="$YEL" ;;
      esac
      pbadge="$(printf '%s%-8.8s%s' "$pcol" "$prof" "$R")"
    fi

    usage="$(printf '%s' "$cur" | usage_of)"
    ustr=""; [ -n "$usage" ] && ustr="  ${D}· ${usage}${R}"
    inj=""; sf="$STATE/${TMUX_SESSION}-${idx}.last"
    [ -f "$sf" ] && inj="  ${D}$(printf "$(t row_inject)" "$(ago $((now-$(cat "$sf"))))")${R}"
    dis=""; is_disabled "$name" && dis="  ${RED}$(t excluded)${R}"
    local act; act="$(printf "$(t row_active)" "$(ago $((now-lastchg)))")"

    printf "  %s%-14s%s %b %b  %s%s%s%s%s%s\n" \
      "$B" "$name" "$R" "$pbadge" "$status" "$D" "$act" "$R" "$ustr" "$inj" "$dis"
  done < <($T list-windows -t "$TMUX_SESSION" -F '#{window_index}	#{window_name}' 2>/dev/null)

  printf "\n  %s$(t summary)%s\n" \
    "$D" "$n" "$working" "$bg" "$limited" "$blocked" "$idle" "$R"

  # 로그의 주요 이벤트를 언어 무관하게 이모지 마커로 추림(주입 ▶ / 상태전이 🟢🔵🟡⛔✅)
  local recent
  recent="$(grep -aE '\] (▶|⛔|✅|🟢|🔵|🟡)' "$DIR/autoresume.log" 2>/dev/null | tail -4)"
  if [ -n "$recent" ]; then
    printf "\n  %s$(t recent_title)%s\n" "$B" "$R"
    printf '%s\n' "$recent" | sed "s/^/    $D/; s/\$/$R/"
  fi
}

# ── 대화형 액션 (터미널 정상화 후 실행) ────────────────────────────────────
term_normal(){ printf '\e[?25h'; [ -n "${saved:-}" ] && stty "$saved" 2>/dev/null; }
# 대체 화면 버퍼 진입 + 커서 숨김. 대체 화면은 스크롤백에 안 쌓여 메모리 누적이 없음.
# tmux attach 후 복귀(tmux가 대체화면을 빠져나감) 시에도 재진입해 주 화면 오염을 막음.
term_raw(){ printf '\e[?1049h\e[?25l'; }

# 한 줄 입력받되 ESC 를 누르면 취소(return 1). 결과는 REPLY 에.
#   Enter=확정, Backspace 지원, ESC=즉시 취소. (모든 프롬프트 공통)
read_esc() {
  local ch acc=""; REPLY=""
  while IFS= read -rsn1 ch; do
    case "$ch" in
      $'\e')                 printf '\n'; return 1 ;;               # ESC → 취소
      ''|$'\n'|$'\r')        printf '\n'; REPLY="$acc"; return 0 ;; # Enter → 확정
      $'\177'|$'\b')         [ -n "$acc" ] && { acc="${acc%?}"; printf '\b \b'; } ;;  # Backspace
      *)                     acc="$acc$ch"; printf '%s' "$ch" ;;
    esac
  done
  REPLY="$acc"; return 0
}

ensure_session_and_window() {  # name cmd
  local nn="$1" cmd="$2"
  if ! $T has-session -t "$TMUX_SESSION" 2>/dev/null; then
    $T new-session -d -s "$TMUX_SESSION" -n "$nn" -c "$PWD"
  elif $T list-windows -t "$TMUX_SESSION" -F '#{window_name}' 2>/dev/null | grep -qx "$nn"; then
    printf "  $(t win_exists)\n" "$nn"; return 1
  else
    $T new-window -t "$TMUX_SESSION" -n "$nn" -c "$PWD"
  fi
  $T send-keys -t "$TMUX_SESSION:$nn" "$cmd" Enter
  printf "  $(t running)\n" "$nn" "$cmd"
}

# 새 세션 메뉴 후보를 동적으로 구성: config 의 NEW_SESSION_MENU + ~/.claude-* 자동탐지
build_menu() {  # 결과를 전역 배열 MENU 에
  MENU=(); local m d base seen
  for m in "${NEW_SESSION_MENU[@]}"; do MENU+=("$m"); done
  for d in "$HOME"/.claude-*; do
    [ -d "$d" ] || continue
    base="$(basename "$d")"
    seen=0; for m in "${MENU[@]}"; do case "$m" in *"$base"*) seen=1 ;; esac; done
    [ "$seen" = 0 ] && MENU+=("CLAUDE_CONFIG_DIR=\"$d\" claude")
  done
}

action_attach() {
  echo; printf "  $(t attach_list)\n"; $T list-windows -t "$TMUX_SESSION" -F '    #{window_index}) #{window_name}' 2>/dev/null
  printf "  $(t attach_prompt)"
  read_esc || { printf "  $(t cancel)\n"; return; }
  local sel="$REPLY"
  case "$sel" in c|C) printf "  $(t cancel)\n" ;; "") $T attach -t "$TMUX_SESSION" ;;
    *) $T attach -t "$TMUX_SESSION:$sel" 2>/dev/null || { printf "  $(t no_window)\n" "$sel"; sleep 1; } ;; esac
}
action_new() {
  local nn cmd extra i
  printf "  $(t new_name)"; read_esc || { printf "  $(t cancel)\n"; return; }
  nn="$REPLY"; [ -z "$nn" ] && { printf "  $(t cancel)\n"; return; }
  build_menu
  if [ "${#MENU[@]}" -le 1 ]; then
    cmd="${MENU[0]:-claude}"
  else
    printf "  $(t select_profile)\n"
    for i in "${!MENU[@]}"; do printf "    %d) %s\n" "$((i+1))" "${MENU[$i]}"; done
    printf "  $(t new_num)"; read_esc || { printf "  $(t cancel)\n"; return; }
    local n2="${REPLY:-1}"
    case "$n2" in ''|*[!0-9]*) cmd="${MENU[0]}" ;;
      *) cmd="${MENU[$((n2-1))]:-${MENU[0]}}" ;; esac
  fi
  printf "  $(t new_args)"
  read_esc || { printf "  $(t cancel)\n"; return; }
  extra="$REPLY"
  ensure_session_and_window "$nn" "$cmd${extra:+ $extra}"; sleep 1
}
action_kill() {
  echo; printf "  $(t kill_list)\n"; $T list-windows -t "$TMUX_SESSION" -F '    #{window_index}) #{window_name}' 2>/dev/null
  printf "  $(t kill_prompt)"; read_esc || { printf "  $(t cancel)\n"; return; }
  local sel="$REPLY"
  case "$sel" in c|C|"") printf "  $(t cancel)\n" ;;
    *) $T kill-window -t "$TMUX_SESSION:$sel" 2>/dev/null && printf "  $(t killed)\n" "$sel" || printf "  $(t notfound)\n" "$sel"; sleep 1 ;; esac
}
action_toggle() {
  echo; printf "  $(t toggle_list)\n"; $T list-windows -t "$TMUX_SESSION" -F '    #{window_name}' 2>/dev/null
  printf "  $(t toggle_prompt)"; read_esc || { printf "  $(t cancel)\n"; return; }
  local wn="$REPLY"
  [ -z "$wn" ] && { printf "  $(t cancel)\n"; return; }; [ "$wn" = c ] && { printf "  $(t cancel)\n"; return; }
  if is_disabled "$wn"; then
    grep -vxF "$wn" "$DISABLED_LIST" > "$DISABLED_LIST.tmp" 2>/dev/null; mv "$DISABLED_LIST.tmp" "$DISABLED_LIST"
    printf "  $(t toggle_on)\n" "$wn"
  else
    echo "$wn" >> "$DISABLED_LIST"; printf "  $(t toggle_off)\n" "$wn"
  fi
  sleep 1
}

# 데몬을 백그라운드로 재기동(즉시 화면 갱신을 막지 않도록 & 로 분리)
daemon_reload() { launchctl kickstart -k "gui/$(id -u)/$DAEMON_LABEL" >/dev/null 2>&1 & }

# 언어 즉시 토글(en↔ko): lang 파일 기록 + 실행 중 변수 갱신 + 데몬 동기화(비동기)
action_lang() {
  local new; [ "$CAR_LANG" = ko ] && new=en || new=ko
  echo "$new" > "$DIR/lang"
  CAR_LANG="$new"
  daemon_reload
}

# 상태별 알림 on/off 설정: notify.conf 에 저장(데몬도 공유), 즉시 반영.
action_notify() {
  local keys=(NOTIFY_WORKING NOTIFY_BACKGROUND NOTIFY_LIMIT NOTIFY_BLOCKED NOTIFY_IDLE)
  local labels=("$(t st_working)" "$(t st_bg)" "$(t st_limit)" "$(t st_blocked)" "$(t st_idle)")
  echo; printf "  %s\n" "$(t notify_title)"
  local i k v
  for i in "${!keys[@]}"; do
    eval "v=\${${keys[$i]}:-0}"
    printf "    %d) [%s] %b\n" "$((i+1))" "$([ "$v" = 1 ] && echo ON || echo '  ')" "${labels[$i]}"
  done
  printf "  $(t notify_prompt)"; read_esc || { printf "  $(t cancel)\n"; return; }
  local sel="$REPLY"; case "$sel" in ''|*[!0-9]*) printf "  $(t cancel)\n"; return ;; esac
  [ "$sel" -ge 1 ] && [ "$sel" -le 5 ] || { printf "  $(t cancel)\n"; return; }
  k="${keys[$((sel-1))]}"; eval "v=\${${k}:-0}"
  [ "$v" = 1 ] && v=0 || v=1
  eval "$k=$v"
  # 5개 값 전부 notify.conf 에 기록
  { for i in "${!keys[@]}"; do eval "printf '%s=%s\n' \"${keys[$i]}\" \"\${${keys[$i]}}\""; done; } > "$DIR/notify.conf"
  daemon_reload
  printf "  %s = %s\n" "$k" "$v"; sleep 1
}

if [ "$ONCE" = 1 ]; then draw; echo; exit 0; fi

saved=$(stty -g 2>/dev/null || true)
cleanup(){ term_normal; printf '\e[?1049l'; }   # 대체 화면 종료 → 원래 터미널 화면 복원
trap 'cleanup; exit 0' EXIT INT TERM
term_raw

while true; do
  draw
  if read -rsn1 -t "$REFRESH" key 2>/dev/null; then
    case "$key" in
      q|Q) break ;;
      r|R) : ;;
      a|A) term_normal; action_attach; term_raw ;;
      n|N) term_normal; action_new;    term_raw ;;
      k|K) term_normal; action_kill;   term_raw ;;
      p|P) term_normal; action_toggle; term_raw ;;
      t|T) term_normal; action_notify; term_raw ;;
      l|L) action_lang ;;
    esac
  fi
done
