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
tf() { printf "$(t "$1")" "${@:2}"; }   # i18n 포맷 헬퍼: tf <key> [args...]

# tmux/osascript 가 멈춰도 데몬 루프 전체가 무한 대기하지 않도록 감쌈.
# macOS 기본엔 timeout 이 없음 → `brew install coreutils`(gtimeout) 있으면 자동 사용, 없으면 그냥 실행.
_TIMEOUT_BIN="$(command -v timeout 2>/dev/null || command -v gtimeout 2>/dev/null || true)"
_t() { local s="$1"; shift; if [ -n "$_TIMEOUT_BIN" ]; then "$_TIMEOUT_BIN" "$s" "$@"; else "$@"; fi; }
# 상태 파일에서 정수 타임스탬프 읽기. 없거나 손상(비숫자)이면 0 → set -u 산술 크래시/크래시루프 방지.
_num() { local v; v="$(cat "$1" 2>/dev/null)"; case "$v" in ''|*[!0-9]*) echo 0 ;; *) echo "$v" ;; esac; }
# 창 하나($1=window_index)의 기업 한도(orglimit) 재시도 상태 파일을 모두 제거.
clear_org_state() {
  rm -f "$STATE/${TMUX_SESSION}-$1.orgfirst" \
        "$STATE/${TMUX_SESSION}-$1.orgretried" \
        "$STATE/${TMUX_SESSION}-$1.orgblocked" \
        "$STATE/${TMUX_SESSION}-$1.orgwaitlog" 2>/dev/null
}

notify() {  # title body [sound]. " 와 \ 를 이스케이프해 AppleScript 깨짐/주입 방지.
  local ti bo; ti="$(printf '%s' "$1" | sed 's/[\\"]/\\&/g')"; bo="$(printf '%s' "$2" | sed 's/[\\"]/\\&/g')"
  _t 8 osascript -e "display notification \"$bo\" with title \"$ti\" sound name \"${3:-Glass}\"" 2>/dev/null
}

# 로그 무한 증가 방지: 1MB 넘으면 최근 800줄만 남김(24/7 운영 대비)
LOG_MAX_BYTES=1048576
rotate_log() {
  local sz; sz="$(stat -f%z "$LOG" 2>/dev/null || echo 0)"
  [ "$sz" -gt "$LOG_MAX_BYTES" ] && { tail -n 800 "$LOG" > "$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG"; }
}
# 닫힌 창(현재 window index 목록에 없는)에 대한 상태파일 정리
prune_orphans() {
  local live f base idx
  live="$(_t 8 tmux list-windows -t "$TMUX_SESSION" -F '#{window_index}' 2>/dev/null)"
  [ -z "$live" ] && return
  for f in "$STATE/${TMUX_SESSION}-"*; do
    [ -e "$f" ] || continue
    base="${f##*/}"; base="${base#"${TMUX_SESSION}-"}"; idx="${base%%.*}"
    case "$idx" in ''|*[!0-9]*) continue ;; esac
    printf '%s\n' "$live" | grep -qx "$idx" || rm -f "$f"
  done
}


# 상태 '전이' 알림: 창 상태가 안정적으로 바뀌면 그 상태의 NOTIFY_* 플래그에 따라 1회 알림.
#   상태(classify): working|background|limit|blocked|idle
notify_transition() {
  local idx="$1" name="$2" cur="$3"
  local lf="$STATE/${TMUX_SESSION}-${idx}.pstate"
  local cf="$STATE/${TMUX_SESSION}-${idx}.pcount"
  local nf="$STATE/${TMUX_SESSION}-${idx}.pnotified"
  local last cnt notified flag emoji sound
  last="$(cat "$lf" 2>/dev/null || echo)"; echo "$cur" > "$lf"
  cnt="$(_num "$cf")"
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
    orglimit)   flag="${NOTIFY_LIMIT:-0}";       emoji="🟠"; sound="Basso" ;;
    blocked)    flag="${NOTIFY_BLOCKED:-0}";     emoji="⛔"; sound="Basso" ;;
    permission) flag="${NOTIFY_PERMISSION:-0}";  emoji="🟣"; sound="Basso" ;;
    idle)       flag="${NOTIFY_IDLE:-0}";        emoji="✅"; sound="Glass" ;;
    *) return ;;
  esac
  [ "$flag" = 1 ] && [ -n "$name" ] || return
  log "$(tf lg_state "$emoji" "$cur" "$TMUX_SESSION:$idx" "$name")"
  notify "$(t "ntf_${cur}_title")" "$(tf "ntf_${cur}_body" "$name")" "$sound"
}

# 승인 대기 창 하나를 처리: 긍정 선택지의 번호키를 눌러 그대로 진행시킨다.
#   $1=window_index $2=window_name $3=화면내용 $4=now(epoch)
# 누른 직후 화면을 다시 읽어 선택지 목록이 그대로면 그 키는 먹지 않은 것으로 보고 실패로
# 센다. APPROVE_RETRY_GAP 뒤에 다시 눌러보되(키 유실 대비) APPROVE_MAX_TRIES 를 넘기면
# 포기한다 — 판정이 틀렸을 때 입력창에 번호만 계속 쌓이는 것을 막는 안전장치다.
approve_window() {
  local idx="$1" name="$2" content="$3" now="$4"
  local target="$TMUX_SESSION:$idx" af h prev ph pc pt pick plabel multi nf after ah
  [ "${AUTO_APPROVE:-0}" = 1 ] || return 0

  if is_noapprove "$name"; then
    nf="$STATE/${TMUX_SESSION}-${idx}.apexcl"
    if [ $(( now - $(_num "$nf") )) -ge "$MIN_RESEND_GAP" ]; then
      echo "$now" > "$nf"; log "$(tf lg_ap_excluded "$target" "$name")"
    fi
    return 0
  fi
  # DENY 가 FILTER 보다 우선. 둘 다 화면 전체(대화상자 본문 포함)를 상대로 본다.
  if [ -n "${AUTO_APPROVE_DENY:-}" ] && printf '%s' "$content" | grep -qiE "$AUTO_APPROVE_DENY"; then
    nf="$STATE/${TMUX_SESSION}-${idx}.apdeny"
    if [ $(( now - $(_num "$nf") )) -ge "$MIN_RESEND_GAP" ]; then
      echo "$now" > "$nf"; log "$(tf lg_ap_deny "$target" "$name")"
    fi
    return 0
  fi
  if [ -n "${AUTO_APPROVE_FILTER:-}" ] && ! printf '%s' "$content" | grep -qiE "$AUTO_APPROVE_FILTER"; then
    return 0
  fi

  pick="$(printf '%s' "$content" | approve_pick)"
  [ -z "$pick" ] && return 0        # 고를 만한 긍정 선택지가 없음 → 사람에게 맡김

  # 폭주 방지: 기억하는 것은 '화면 전체'가 아니라 '선택지 목록'의 해시다.
  # 화면 전체를 쓰면 우리가 누른 숫자가 입력창에 찍히면서 화면이 매번 달라져 실패 카운트가
  # 계속 0으로 돌아간다(= 오탐일 때 입력창에 숫자가 무한히 쌓인다). 선택지 목록은 판정이
  # 틀려 대화상자가 아닌 본문을 잡은 경우 그대로 남아 있으므로, 그때만 카운트가 쌓인다.
  af="$STATE/${TMUX_SESSION}-${idx}.aptry"
  h="$(printf '%s' "$content" | approve_options | cksum | awk '{print $1}')"
  # 상태파일이 없거나 비었을 때도 awk 가 '한 줄'을 보도록 개행을 붙인다(빈 문자열이면
  # awk 는 아예 출력을 안 해 pc/pt 가 빈 값이 되고, 그 뒤 정수 비교가 깨진다).
  prev="$(cat "$af" 2>/dev/null || echo)"
  ph="$(printf '%s\n' "$prev" | awk '{print $1}')"
  pc="$(printf '%s\n' "$prev" | awk '{print $2+0}')"
  pt="$(printf '%s\n' "$prev" | awk '{print $3+0}')"
  # 카운트는 '직전에 눌렀는데 아무 반응이 없었을 때'만 남아 있다. 반응이 있었으면 0 이라
  # 이 관문을 그냥 통과한다 — 같은 문구('1. Yes / 2. No')의 요청이 연달아 와도 안 밀린다.
  if [ "$pc" -gt 0 ] && [ "$ph" = "$h" ]; then
    [ "$pc" -ge "${APPROVE_MAX_TRIES:-3}" ] && return 0             # 이미 포기함
    [ $(( now - pt )) -lt "${APPROVE_RETRY_GAP:-45}" ] && return 0  # 방금 눌렀음, 반응 대기
  fi

  # 체크박스(multiSelect) 질문은 번호키가 '토글'이라 Right 로 제출 화면까지 넘긴다.
  # 넘어간 제출 화면('1. Submit answers')은 다음 스캔에서 평범한 승인으로 처리된다.
  multi=0; printf '%s' "$content" | match_checkbox && multi=1
  if ! _t 8 tmux send-keys -t "$target" -l "$pick"; then
    log "$(tf lg_ap_fail "$target" "$name")"; return 0
  fi
  if [ "$multi" = 1 ]; then sleep 0.5; _t 8 tmux send-keys -t "$target" Right; fi

  # 누른 게 실제로 먹혔는지 바로 확인한다. 선택지 목록이 그대로면 그 키는 아무 일도 하지
  # 않은 것 → 실패로 세고, APPROVE_MAX_TRIES 를 넘기면 그 화면은 사람에게 넘긴다.
  sleep 1.5
  after="$(_t 8 tmux capture-pane -p -t "$target" 2>/dev/null | tail -n "$CAPTURE_LINES")"
  ah="$(printf '%s' "$after" | approve_options | cksum | awk '{print $1}')"
  if [ "$ah" = "$h" ] && [ "$(printf '%s' "$after" | classify)" = permission ]; then
    pc=$((pc+1))
  else
    pc=0
  fi
  echo "$h $pc $now" > "$af"

  plabel="$(printf '%s' "$content" | approve_options | awk -F'|' -v n="$pick" '$1==n{print $2}' | cut -c1-60)"
  log "$(tf lg_approve "$pick" "$plabel" "$target" "$name")"
  [ "$pc" -ge "${APPROVE_MAX_TRIES:-3}" ] && log "$(tf lg_ap_giveup "$target" "$name")"
  return 0
}

# 승인 전용 짧은 스캔(INTERVAL 사이에 APPROVE_INTERVAL 마다 돈다).
# 승인 대기는 한도와 달리 저절로 풀리지 않아 빨리 눌러줄수록 좋다. capture-pane 만 해서
# 비용은 무시할 수준이고, 한도 관련 액션은 여기서 절대 하지 않는다(scan_once 전용).
approve_scan() {
  [ "${AUTO_APPROVE:-0}" = 1 ] || return 0
  _t 8 tmux has-session -t "$TMUX_SESSION" 2>/dev/null || return 0
  local idx name content
  while read -r idx; do
    case "$idx" in ''|*[!0-9]*) continue ;; esac
    name="$(_t 8 tmux display-message -p -t "$TMUX_SESSION:$idx" '#{window_name}' 2>/dev/null)"
    [ -z "$name" ] && continue
    content="$(_t 8 tmux capture-pane -p -t "$TMUX_SESSION:$idx" 2>/dev/null | tail -n "$CAPTURE_LINES")"
    [ -z "$content" ] && continue
    # classify 로 최종 확인 — 한도/작업중이 먼저 잡히면 그쪽이 우선이므로 손대지 않는다.
    [ "$(printf '%s' "$content" | classify)" = permission ] || continue
    approve_window "$idx" "$name" "$content" "$(date +%s)"
  done < <(_t 8 tmux list-windows -t "$TMUX_SESSION" -F '#{window_index}' 2>/dev/null)
}

scan_once() {
  rotate_log
  if ! _t 8 tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
    # 세션이 없을 때 매 스캔마다 찍으면 로그가 폭증하므로 5분에 한 번만 기록.
    local nf="$STATE/.nosession" nlast now2
    nlast="$(_num "$nf")"
    now2="$(date +%s)"
    if [ $(( now2 - nlast )) -ge 300 ]; then echo "$now2" > "$nf"; log "$(tf lg_no_session "$TMUX_SESSION")"; fi
    return
  fi
  prune_orphans

  # window 열거는 '인덱스만'(숫자) 받아 반복하고, 이름은 창별로 따로 조회한다.
  #   예전엔 '#{window_index}\t#{window_name}' 한 줄을 IFS=탭으로 쪼갰는데,
  #   tmux 는 C/POSIX(빈) 로케일에서 포맷 출력의 탭(0x09)을 '_'(0x5f)로 치환한다.
  #   launchd 데몬은 로케일이 비어 있어(config.sh 에서 UTF-8 강제) 이 치환으로 탭 분리가
  #   깨져 모든 창이 스킵됐다. 구분자 없는 인덱스-only 열거는 로케일과 무관하게 안전하다.
  while read -r idx; do
    case "$idx" in ''|*[!0-9]*) continue ;; esac
    name="$(_t 8 tmux display-message -p -t "$TMUX_SESSION:$idx" '#{window_name}' 2>/dev/null)"
    # 이름 조회 실패(빈 문자열)면 is_disabled 안전확인이 불가능하므로 이 스캔은 스킵한다
    # (비활성화(disabled.list)한 창에 실수로 주입/선택하는 것을 방지). 다음 스캔에서 재시도.
    [ -z "$name" ] && continue
    target="$TMUX_SESSION:$idx"
    content="$(_t 8 tmux capture-pane -p -t "$target" 2>/dev/null | tail -n "$CAPTURE_LINES")"
    now="$(date +%s)"
    # capture 실패/빈 화면(프롬프트가 위에 있고 하단이 비었을 때 포함)이면 상태 판정을 건너뛴다.
    # 단, 빈 화면은 'org 한도 아님'이 확실하므로 org 재시도 상태는 정리한다. 그래야 예전
    # .orgretried 가 남아 나중에 같은 창이 다시 한도에 걸렸을 때 5시간 대기 없이 즉시
    # 차단되는 일이 없다.
    if [ -z "$content" ]; then clear_org_state "$idx"; continue; fi

    state="$(printf '%s' "$content" | classify)"
    notify_transition "$idx" "$name" "$state"     # 상태 전이 알림(플래그별)

    # 기업 한도(orglimit) 가 아닌 상태로 바뀌면 org 재시도 상태를 리셋한다(재개/전이 시).
    # 재개에 성공하면 org 문구가 사라져 다른 상태가 되므로 여기서 자연히 초기화된다.
    [ "$state" != orglimit ] && clear_org_state "$idx"

    # 기업(org) 월 결제 한도: 개인 5시간 한도와 달리 리셋 시각이 화면에 없고, 5시간 한도도
    # 이 문구로 뜬다. 즉시 차단하지 않고 처음 감지 후 ORG_RETRY_DELAY(기본 5시간) 뒤 1회
    # CONTINUE_PROMPT 를 주입해 재시도한다. 그래도 같은 문구가 남으면 그때 차단으로 본다.
    if [ "$state" = orglimit ]; then
      is_disabled "$name" && continue     # 제외 창은 손대지 않음(알림은 위에서 처리)
      off="$STATE/${TMUX_SESSION}-${idx}.orgfirst"
      orf="$STATE/${TMUX_SESSION}-${idx}.orgretried"
      obf="$STATE/${TMUX_SESSION}-${idx}.orgblocked"
      ofirst="$(_num "$off")"; rtried="$(_num "$orf")"
      if [ "$rtried" -gt 0 ]; then
        # 이미 1회 재시도했는데도 org 문구가 계속/다시 뜸 → 진짜 차단. 알림·로그는 gap 간격 1회.
        oblast="$(_num "$obf")"
        if [ $(( now - oblast )) -ge "$MIN_RESEND_GAP" ]; then
          echo "$now" > "$obf"
          log "$(tf lg_orgblocked "$target" "$name")"
          [ "${NOTIFY_BLOCKED:-0}" = 1 ] && notify "$(t ntf_orgblocked_title)" "$(tf ntf_orgblocked_body "$name")" Basso
        fi
      elif [ "$ofirst" -eq 0 ]; then
        echo "$now" > "$off"                # 처음 감지 → 타이머 시작
        log "$(tf lg_orgseen "$target" "$name")"
      elif [ $(( now - ofirst )) -ge "$ORG_RETRY_DELAY" ]; then
        # 감지 후 5시간 경과 → 1회 재시도(주입 성공 시에만 재시도 기록).
        if _t 8 tmux send-keys -t "$target" -l "$CONTINUE_PROMPT"; then
          sleep 1
          _t 8 tmux send-keys -t "$target" Enter
          echo "$now" > "$orf"
          log "$(tf lg_orgretry "$target" "$name")"
        else
          log "$(tf lg_inject_fail "$target" "$name")"
        fi
      else
        # 재시도까지 대기 중. 로그는 5분에 한 번만.
        owf="$STATE/${TMUX_SESSION}-${idx}.orgwaitlog"
        owlast="$(_num "$owf")"
        if [ $(( now - owlast )) -ge 300 ]; then
          echo "$now" > "$owf"
          log "$(tf lg_orgwait "$target" "$(date -r $((ofirst + ORG_RETRY_DELAY)) '+%H:%M')" "$name")"
        fi
      fi
      continue
    fi

    # 승인 대기(권한 요청·질문 대화상자) → AUTO_APPROVE=1 이면 긍정 선택지를 눌러 진행.
    # 꺼져 있으면 아무것도 하지 않는다(위 상태 전이 알림만 나감).
    if [ "$state" = permission ]; then
      approve_window "$idx" "$name" "$content" "$now"
      continue
    fi

    # limit 외 상태(working/background/idle/blocked)는 데몬 자동재개 액션 없음.
    [ "$state" = limit ] || continue

    # 한도대기 상태에서만 자동재개(선택/주입). 제외 창은 스킵(알림은 위에서 이미 처리).
    if is_disabled "$name"; then
      ef="$STATE/${TMUX_SESSION}-${idx}.excllog"
      elast="$(_num "$ef")"
      if [ $(( now - elast )) -ge "$MIN_RESEND_GAP" ]; then
        echo "$now" > "$ef"; log "$(tf lg_excluded "$target" "$name")"
      fi
      continue
    fi

    # (1) 활성 한도 선택 메뉴 → "Stop and wait for limit to reset"(1번) 자동 선택.
    #     선택만으로는 재개되지 않으므로, 이후 리셋이 지나면 (2)에서 주입이 이어짐.
    if printf '%s' "$content" | match_limit_menu; then
      mf="$STATE/${TMUX_SESSION}-${idx}.menu"
      mlast="$(_num "$mf")"
      if [ $(( now - mlast )) -ge "$MIN_RESEND_GAP" ]; then
        echo "$now" > "$mf"
        _t 8 tmux send-keys -t "$target" Up Up      # 커서를 최상단(1번)으로
        sleep 0.3
        _t 8 tmux send-keys -t "$target" Enter      # 확정
        log "$(tf lg_menu "$target" "$name")"
      fi
      continue
    fi

    # (2) 텍스트형 세션 한도 → resets 시각 지나면 CONTINUE_PROMPT 주입(제자리 재개).
    sf="$STATE/${TMUX_SESSION}-${idx}.last"
    last="$(_num "$sf")"
    rep="$(printf '%s' "$content" | reset_epoch)"
    case "$rep" in
      PASSED) waiting=0; lbl="$(t lbl_passed)" ;;
      "")     waiting=0; lbl="$(t lbl_unknown)" ;;
      *)      if [ "$now" -lt $(( rep + RESET_BUFFER )) ]; then waiting=1; else waiting=0; lbl="$(t lbl_passed)"; fi ;;
    esac
    if [ "$waiting" = 1 ]; then
      wf="$STATE/${TMUX_SESSION}-${idx}.waitlog"
      wlast="$(_num "$wf")"
      if [ $(( now - wlast )) -ge 300 ]; then
        echo "$now" > "$wf"
        log "$(tf lg_waiting "$target" "$(date -r "$rep" '+%H:%M')" "$name")"
      fi
    elif [ $(( now - last )) -ge "$MIN_RESEND_GAP" ]; then
      # 주입 성공(send-keys 성공)일 때만 .last 기록 → 실패 시 다음 스캔에 재시도.
      if _t 8 tmux send-keys -t "$target" -l "$CONTINUE_PROMPT"; then
        sleep 1
        _t 8 tmux send-keys -t "$target" Enter
        echo "$now" > "$sf"
        log "$(tf lg_inject "$lbl" "$target" "$name")"
      else
        log "$(tf lg_inject_fail "$target" "$name")"
      fi
    else
      log "$(tf lg_gap "$target")"
    fi
  done < <(_t 8 tmux list-windows -t "$TMUX_SESSION" -F '#{window_index}' 2>/dev/null)
}

# 상시 감시 루프를 함수로 감싸 '한 번에 파싱'되게 함. 이렇게 하면 실행 중에 이 파일이
# 편집돼도 bash 가 루프 본문을 중간부터 재읽기해 깨지는 일이 없음(라이브 편집 안전).
main() {
  log "$(tf lg_start "$TMUX_SESSION" "$INTERVAL" "$MIN_RESEND_GAP")"   # 시작 로그는 여기서만
  [ "${AUTO_APPROVE:-0}" = 1 ] && log "$(tf lg_ap_start "${AUTO_APPROVE_MODE:-all}" "${AUTO_APPROVE_PREFER:-once}" "${APPROVE_INTERVAL:-0}")"
  local waited
  while true; do
    scan_once
    # 자동승인이 켜져 있고 주기가 INTERVAL 보다 짧으면, 한 사이클을 잘게 쪼개 그 사이에
    # 승인 전용 스캔을 돌린다. 승인 대기는 눌러줄 때까지 세션이 그냥 서 있으므로,
    # 한도 스캔 주기(60초)를 기다리게 두면 그만큼 통째로 놀게 된다.
    if [ "${AUTO_APPROVE:-0}" = 1 ] && [ "${APPROVE_INTERVAL:-0}" -gt 0 ] && [ "$APPROVE_INTERVAL" -lt "$INTERVAL" ]; then
      waited=0
      while [ "$waited" -lt "$INTERVAL" ]; do
        sleep "$APPROVE_INTERVAL"; waited=$((waited+APPROVE_INTERVAL)); approve_scan
      done
    else
      sleep "$INTERVAL"
    fi
  done
}

if [ "${1:-}" = "--once" ]; then scan_once; exit 0; fi
if [ "${1:-}" = "--approve-once" ]; then approve_scan; exit 0; fi
main
