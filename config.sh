#!/usr/bin/env bash
# ============================================================================
# claude-autoresume 설정 + 공용 헬퍼
#   이 파일만 고치면 감시자(autoresume.sh)와 대시보드(session-manager.sh) 동작이
#   함께 바뀝니다. (두 스크립트가 이 파일을 source 함)
# ============================================================================

_CFG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── UI 언어 (기본 en) ────────────────────────────────────────────────────────
# 우선순위: 환경변수 CAR_LANG > lang 파일(csm 에서 [l] 로 토글) > en
# 모든 화면/알림/로그/주입문구는 i18n.sh 의 t() 로 조회됩니다.
CAR_LANG="${CAR_LANG:-$(cat "$_CFG_DIR/lang" 2>/dev/null || true)}"
CAR_LANG="${CAR_LANG:-en}"
case "$CAR_LANG" in en|ko) ;; *) CAR_LANG=en ;; esac
# shellcheck source=/dev/null
source "$_CFG_DIR/i18n.sh"

# ── 환경 (배포 대비: 하드코딩 없이 자동 탐지) ───────────────────────────────
# launchd 데몬 라벨 (사용자별로 바꾸려면 CAR_LABEL 환경변수)
DAEMON_LABEL="${CAR_LABEL:-com.claude-autoresume}"
# tmux 실행 파일 (Apple Silicon/Intel/기타 자동 탐지)
TMUX_BIN="$(command -v tmux 2>/dev/null || echo /opt/homebrew/bin/tmux)"

# ── 기본 ────────────────────────────────────────────────────────────────────
# 감시할 tmux 세션 이름 (이 세션의 모든 window 를 감시)
TMUX_SESSION="${CAR_SESSION:-claude}"
# 세션 한도 리셋 후 멈춘 창에 넣어줄 "이어가기" 프롬프트.
# 기본값은 CAR_LANG 에 맞는 i18n 문구(en/ko). CAR_CONTINUE_PROMPT 로 직접 지정 가능.
CONTINUE_PROMPT="${CAR_CONTINUE_PROMPT:-$(t continue_prompt)}"
# 자동재개에서 제외할 창 이름 목록 파일 (창별 on/off)
DISABLED_LIST="$_CFG_DIR/disabled.list"

# ── 한도 문구 3분류 (대소문자 무시) ─────────────────────────────────────────
# (A) RESUME_REGEX : 자동 이어가기 대상. 5h 세션 한도 → resets 후 풀림.
#     예) "You've hit your session limit · resets 1:40pm (Asia/Seoul)"
# 마지막 항목은 메뉴 '선택 후' 남는 문구까지 잡기 위한 안전망(활성 메뉴는 메뉴 처리가 우선).
RESUME_REGEX="you'?ve hit your session limit|5-hour limit reached|session limit reached|stop and wait for limit to reset"
# (B) BLOCKED_NOAUTO_REGEX : 차단이지만 자동재개 무의미(관리자/장기 대기). 감지+알림만.
#     예) "You've hit your org's monthly spend limit · run /usage-credits ..."
BLOCKED_NOAUTO_REGEX="hit your org'?s monthly spend limit|monthly spend limit|weekly limit|7-day limit"
# (C) IGNORE_REGEX : 차단 아닌 예고성 경고 → 무시. 예) "You've used 97% of ..."
IGNORE_REGEX="used [0-9]{1,3}% of|approaching"
# (D) 한도 도달 시 뜨는 대화형 선택 메뉴 → 데몬이 "Stop and wait for limit to reset"(1번)
#     자동 선택. 단, 선택 후에도 문구가 남을 수 있어 '활성 메뉴'일 때만 잡아야 함
#     (그래야 선택 뒤 리셋 지나면 CONTINUE_PROMPT 주입으로 실제 재개가 진행됨).
#     LIMIT_MENU_OPT  : 옵션 문구,  LIMIT_MENU_ACTIVE : 활성 메뉴에만 있는 확정 프롬프트
LIMIT_MENU_OPT="stop and wait for limit to reset"
LIMIT_MENU_ACTIVE="enter to confirm|esc to cancel|❯ *1\."

# 백그라운드 작업(shell/agent/workflow/sub-agent) 진행 중 신호 → '유휴' 아닌 '🔵 백그라운드'
#   · "N shells still running" / "· N shell"        : 백그라운드 셸
#   · "Waiting for N background agent(s)"            : 서브에이전트 대기
#   · "N/M agents" / "← N agent"                     : 에이전트 진행
#   · "↓ 104.0k tokens" / "45m 12s · ↓"             : 실행 중 서브에이전트의 토큰/시간 카운터
BACKGROUND_REGEX="[0-9]+ shells? still running|· [0-9]+ shell|running in the background|waiting for [0-9]+ (background |dynamic )?(agent|workflow|shell)|[0-9]+/[0-9]+ agents|← [0-9]+ agent|↓ [0-9][0-9.,]*[km]? tokens|[0-9]+m [0-9]+s · ↓"

# 메인 에이전트가 '실제로 생성 중'일 때만 뜨는 문구 → '🟢 작업중' 판정.
# (화면 해시 변화만으로 판정하면 프롬프트 타이핑·/status 등도 작업중으로 오판되므로,
#  Claude TUI 가 생성 중에만 보여주는 'esc to interrupt' 스피너 문구를 앵커로 사용.)
# Claude 버전에 따라 문구가 바뀌면 이 한 줄만 맞춰주면 됩니다.
WORKING_REGEX="esc to interrupt|escape to interrupt"

# ── statusline 파싱 패턴 (커스텀 statusline 전용, 없으면 자동 생략) ──────────
# 사용자의 /rc 등 커스텀 statusline 예: "5h 0% left / 7d 11% left"
# 이 패턴에 안 맞으면(기본 statusline) 사용량 표시는 그냥 생략됩니다(예외처리).
USAGE_REGEX_SHORT="[0-9]+h [0-9]+% left"     # 5시간 창
USAGE_REGEX_LONG="[0-9]+d [0-9]+% left"      # 7일 창

# ── 동작/알림 ───────────────────────────────────────────────────────────────
# 상태 '전이' 시 macOS 알림 (1=켬, 0=끔). 창이 그 상태로 바뀔 때 한 번 알림.
#   기본: 유휴(완료)·한도대기·차단만 켜짐. 작업중/백그라운드는 잦아서 기본 꺼짐.
NOTIFY_WORKING=0      # → 🟢 작업중 전환 시
NOTIFY_BACKGROUND=0   # → 🔵 백그라운드 전환 시
NOTIFY_LIMIT=1        # → 🟡 한도대기 전환 시
NOTIFY_BLOCKED=1      # → ⛔ 차단 전환 시
NOTIFY_IDLE=1         # → ⚪ 유휴(완료/입력대기) 전환 시
# csm 에서 't'(알림설정)로 토글하면 아래 파일에 저장돼 위 기본값을 덮어씀(데몬도 공유)
[ -f "$_CFG_DIR/notify.conf" ] && source "$_CFG_DIR/notify.conf"
INTERVAL=60           # 감시 주기(초). 짧을수록 리셋 직후 빨리 이어감(capture라 비용 무시)
MIN_RESEND_GAP=540    # 같은 창 재주입/재알림 최소 간격(초)
RESET_BUFFER=30       # resets 시각 + 이 여유(초) 뒤부터 주입
CAPTURE_LINES=20      # 화면 하단 몇 줄 보고 판단할지. 진짜 멈춘 한도배너는 하단 ~17줄
                      # 이내에 있음. 너무 크게 잡으면 재개 후 위로 밀려난 옛 배너를 다시 잡아
                      # limit 로 오판(잘못된 재주입). background-먼저 순서와 함께 오판을 막음.

export TMUX_TMPDIR="${TMUX_TMPDIR:-/tmp}"   # launchd 데몬과 tmux 소켓 공유

# ── csm [n] 새 세션 메뉴 후보 (배포 기본은 'claude' 하나) ────────────────────
#   프로필 런처(셸 함수/alias)를 쓰면 여기에 추가하세요. 각 항목은 대상 창의
#   대화형 셸에서 그대로 실행되므로, 그 셸이 아는 명령이면 무엇이든 됩니다.
#   예: NEW_SESSION_MENU=( "claude" "claude-work" "claude-personal" )
#   추가로, ~/.claude-* 설정 디렉토리가 있으면 csm 이 자동으로 후보에 붙여줍니다.
NEW_SESSION_MENU=( "claude" )

# ── 공용 판정 헬퍼 (stdin = 화면 내용) ──────────────────────────────────────
match_resume()     { grep -iE "$RESUME_REGEX"         2>/dev/null | grep -ivE "$IGNORE_REGEX" | grep -q .; }
match_blocked()    { grep -iE "$BLOCKED_NOAUTO_REGEX" 2>/dev/null | grep -ivE "$IGNORE_REGEX" | grep -q .; }
match_background() { grep -qiE "$BACKGROUND_REGEX" 2>/dev/null; }
match_working()    { grep -qiE "$WORKING_REGEX" 2>/dev/null; }
# 활성 한도 메뉴: 옵션 문구 + 확정 프롬프트가 함께 있을 때만 참(선택 후 잔여문구 제외)
match_limit_menu() {
  local c; c="$(cat)"
  printf '%s' "$c" | grep -qiE "$LIMIT_MENU_OPT" \
    && printf '%s' "$c" | grep -qiE "$LIMIT_MENU_ACTIVE"
}

# 화면 내용(stdin)을 단일 상태로 분류(csm·데몬 공용). 우선순위 순서:
#   working | blocked | background | limit | idle
# background 를 limit 보다 먼저 보는 이유: 재개 후 계속 작업 중인데 옛 한도 배너가
# 화면에 남아 있으면 limit 로 오판해 잘못 재주입할 수 있음. 백그라운드 작업이 돌고 있으면
# 아직 '멈춘 한도'가 아니므로 background 로 본다. 진짜 멈춘 한도는 background 신호가 없다.
classify() {
  local c; c="$(cat)"
  if   printf '%s' "$c" | match_working;    then printf working
  elif printf '%s' "$c" | match_blocked;    then printf blocked
  elif printf '%s' "$c" | match_background; then printf background
  elif printf '%s' "$c" | match_resume || printf '%s' "$c" | match_limit_menu; then printf limit
  else printf idle; fi
}

# 창 이름이 자동재개 제외 목록에 있나
is_disabled() { [ -f "$DISABLED_LIST" ] && grep -qxF "$1" "$DISABLED_LIST"; }

# statusline에서 사용량 잔량 파싱 → "5h 0% · 7d 11%" (없으면 빈값)
usage_of() {
  local c s l; c="$(cat)"
  s="$(printf '%s' "$c" | grep -oiE "$USAGE_REGEX_SHORT" | head -1 | grep -oiE '[0-9]+h [0-9]+%')"
  l="$(printf '%s' "$c" | grep -oiE "$USAGE_REGEX_LONG"  | head -1 | grep -oiE '[0-9]+d [0-9]+%')"
  [ -z "$s" ] && [ -z "$l" ] && return 0
  if [ -n "$s" ] && [ -n "$l" ]; then printf '%s · %s' "$s" "$l"
  else printf '%s%s' "$s" "$l"; fi
}

# 화면 내용(stdin)에서 'resets <시각> (Zone/City)'을 파싱.
#   출력: 미래면 epoch(초) / 이미 지났으면 "PASSED" / 못 읽으면 빈값.
reset_epoch() {
  local content raw hour min ampm h2 m2 tz tzpfx day epoch now epoch2
  content="$(cat)"
  raw="$(printf '%s' "$content" \
        | grep -oiE 'resets[[:space:]]+(at[[:space:]]+)?[0-9]{1,2}(:[0-9]{2})?[[:space:]]*(am|pm)?' \
        | head -1 | grep -oiE '[0-9]{1,2}(:[0-9]{2})?[[:space:]]*(am|pm)?' | tail -1)"
  raw="$(printf '%s' "$raw" | tr -d '[:space:]' | tr 'a-z' 'A-Z')"
  [ -z "$raw" ] && return 0
  hour="$(printf '%s' "$raw" | grep -oE '^[0-9]{1,2}')"; [ -z "$hour" ] && return 0
  min="$(printf '%s' "$raw" | grep -oE ':[0-9]{2}' | tr -d ':')"; min="${min:-00}"
  # 10진수 강제: bash 3.2 는 08/09 를 8진수로 오인해 산술/printf 가 깨짐(리셋 시각 오차)
  hour=$((10#$hour)); min=$((10#$min))
  ampm="$(printf '%s' "$raw" | grep -oE '[AP]M')"
  [ "$ampm" = PM ] && [ "$hour" != 12 ] && hour=$((hour+12))
  [ "$ampm" = AM ] && [ "$hour" = 12 ] && hour=0
  [ "$hour" -gt 23 ] 2>/dev/null && return 0
  h2="$(printf '%02d' "$hour")"; m2="$(printf '%02d' "$min")"
  tz="$(printf '%s' "$content" | grep -oE '\([A-Za-z]+/[A-Za-z_]+\)' | head -1 | tr -d '()')"
  tzpfx=""; [ -n "$tz" ] && tzpfx="TZ=$tz"
  day="$(env $tzpfx date +%Y-%m-%d)"
  epoch="$(env $tzpfx date -j -f "%Y-%m-%d %H:%M" "$day $h2:$m2" +%s 2>/dev/null)"
  [ -z "$epoch" ] && return 0
  now="$(date +%s)"
  if [ "$epoch" -gt "$now" ]; then
    [ $((epoch-now)) -gt 21600 ] && { printf 'PASSED'; return 0; }
    printf '%s' "$epoch"; return 0
  fi
  epoch2=$((epoch+86400))
  [ $((epoch2-now)) -le 21600 ] && { printf '%s' "$epoch2"; return 0; }
  printf 'PASSED'; return 0
}
