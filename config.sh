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
# 자동승인에서만 제외할 창 이름 목록 파일 (자동재개는 그대로 두고 승인만 끔)
NOAPPROVE_LIST="$_CFG_DIR/noapprove.list"

# ── 한도 문구 3분류 (대소문자 무시) ─────────────────────────────────────────
# (A) RESUME_REGEX : 자동 이어가기 대상. 5h 세션 한도 → resets 후 풀림.
#     예) "You've hit your session limit · resets 1:40pm (Asia/Seoul)"
# 마지막 항목은 메뉴 '선택 후' 남는 문구까지 잡기 위한 안전망(활성 메뉴는 메뉴 처리가 우선).
RESUME_REGEX="you'?ve hit your session limit|5-hour limit reached|session limit reached|stop and wait for limit to reset"
# (B) BLOCKED_NOAUTO_REGEX : 차단이며 자동재개 무의미(장기 대기). 감지+알림만.
#     주간/7일 한도가 여기 해당(리셋이 멀어 이어가도 의미 없음).
#     한도 종류 라벨은 claude 바이너리(2.1.220)의 매핑에서 그대로 가져왔다:
#       five_hour:"session limit"            → 5시간, 자동재개 대상(RESUME_REGEX)
#       seven_day:"weekly limit"             → 7일
#       seven_day_opus:"Opus limit"          → 7일(모델별)
#       seven_day_sonnet:"Sonnet limit"      → 7일(모델별)
#       seven_day_overage_included:"… limit" → 7일(최신 모델명이 들어감. 모델명은 버전마다
#                                              바뀌므로 이름 대신 '모델명 + limit' 을 넓게 받는다)
#       overage:"usage credit limit"         → 크레딧 소진
#     배너는 "You've hit your <라벨>" 로 조합된다. 이 목록에 없으면 classify 가 idle 로
#     떨어져 알림도 로그도 없이 방치되므로, 7일 계열은 빠짐없이 넣어 둔다.
BLOCKED_NOAUTO_REGEX="weekly limit|7-day limit|opus limit|sonnet limit|haiku limit|fable [0-9.]+ limit|usage credit limit"
# (B') ORG_LIMIT_REGEX : 기업(org) 계정 전용. 기업 계정은 '개인 5시간 한도'도 이 문구로
#     뜨며(리셋 시각이 화면에 없음), 진짜 월 결제 한도인지 5시간 한도인지 문구만으론
#     구분되지 않는다. 그래서 즉시 차단하지 않고 5시간 뒤 1회 재시도한 뒤(autoresume.sh
#     의 orglimit 상태머신), 그래도 같은 문구가 남으면 그때 차단으로 본다.
#     예) "You've hit your org's monthly spend limit · run /usage-credits ..."
#     개인 계정에는 이 문구가 뜨지 않으므로, 이 규칙이 개인/기업 처리를 자연히 분리한다.
ORG_LIMIT_REGEX="hit your org'?s monthly spend limit|monthly spend limit"
# (C) IGNORE_REGEX : 차단 아닌 예고성 경고 → 무시. 예) "You've used 97% of ..."
IGNORE_REGEX="used [0-9]{1,3}% of|approaching"
# (D) 한도 도달 시 뜨는 대화형 선택 메뉴 → 데몬이 "Stop and wait…" 선택지를 자동 선택.
#     선택 후에도 문구가 남을 수 있어 '활성 메뉴'일 때만 잡아야 한다(그래야 선택 뒤
#     리셋이 지나면 CONTINUE_PROMPT 주입으로 실제 재개가 이어진다).
#     아래 값들은 claude 바이너리(2.1.220)의 메뉴 구현에서 확인한 것이다:
#       options: {label: usage_based ? "Stop" : "Stop and wait for limit to reset"}
#                {label:"Upgrade your plan"} {label:`Add funds to continue with …`} …
#       title:   "What do you want to do?"
#       순서:    기능플래그에 따라 'Stop' 이 첫 번째일 수도 마지막일 수도 있다
#                → 위치로 고르면 안 되고 반드시 라벨로 찾아야 한다(limit_menu_pick).
LIMIT_MENU_OPT="stop and wait for limit to reset|stop"
# 선택지 '줄'로 렌더링된 형태만 인정한다. 커서(❯)와 번호는 둘 다 있을 수도, 없을 수도 있다
# (rate limit 메뉴는 번호가 붙지만, 기업 결제 한도 메뉴는 '❯ 라벨' 로만 그린다).
# 라벨이 줄의 전부여야 한다 — 그래야 대화 본문에 같은 문구가 섞인 산문이 안 걸린다.
LIMIT_MENU_OPTLINE="^[[:space:]]*(❯[[:space:]]*)?([0-9]{1,2}\.[[:space:]]+)?($LIMIT_MENU_OPT)[[:space:]]*$"
# 그 선택지에 커서가 '올라가 있는' 상태. 번호키를 누른 뒤 확정(Enter)을 보내도 되는지
# 판단하는 데 쓴다. 커서가 목표에 안 갔는데 Enter 를 보내면 엉뚱한 선택지가 확정된다.
LIMIT_MENU_SELECTED="^[[:space:]]*❯[[:space:]]*([0-9]{1,2}\.[[:space:]]+)?($LIMIT_MENU_OPT)[[:space:]]*$"
# 메뉴가 '지금 열려 있음'을 뒷받침하는 신호. 둘 중 하나만 있으면 된다.
#   · 제목 "What do you want to do?" : 바이너리의 메뉴 구현에서 확인
#   · 하단 "Enter to confirm"         : 선택 대화상자 공통 안내(폴더 신뢰 화면에서 실물 확인)
# 넓게 잡아도 안전한 이유: 오탐 차단은 LIMIT_MENU_OPTLINE(라벨이 줄의 전부)이 맡는다.
# 좁히면 UI 문구가 하나만 바뀌어도 메뉴를 통째로 놓치므로, 여기서는 넓히는 쪽이 옳다.
LIMIT_MENU_ACTIVE="what do you want to do\?|enter to confirm"
#     LIMIT_MENU_LABELS : 한도 메뉴의 '선택지 라벨' 모음. 승인 경로(match_permission)가
#     이 메뉴를 건드리지 않도록 막는 데 쓴다. LIMIT_MENU_OPT 한 문구만 보면 문구가 다른
#     한도 메뉴(usage_based 계정의 'Stop', 업그레이드·크레딧 안내)가 그대로 통과해
#     '1번 승인'이 눌린다. 라벨 목록은 claude 바이너리(2.1.220)의 메뉴 구현에서 가져왔다.
#     검사 대상은 선택지 라벨뿐이다 — 화면 전체를 보면 본문에 'stop' 한 단어가 있다는
#     이유로 멀쩡한 권한 요청까지 막힌다. 라벨 전체와 맞아야 하는 것은 ^…$ 로 묶는다.
LIMIT_MENU_LABELS="stop and wait for limit to reset|^stop$|^upgrade your plan$|^add funds to continue with|^switch to usage|^ask your admin for more usage|^(upgrade|switch) to team plan$|^wait for limit to reset$|continue with a different model|switch to a different model"

# 백그라운드 작업 진행 중 신호 → '유휴' 아닌 '🔵 백그라운드'
#   · "N shells still running" / "· N shell"        : 백그라운드 셸
#   · "Waiting for N background/dynamic agent(s)"    : 서브에이전트/워크플로 대기
#   · "N/M agents" / "← N agents"                    : 에이전트 진행/정의 수(상태줄)
#   · "↓ 104.0k tokens" / "45m 12s · ↓"             : 실행 중 서브에이전트의 토큰/시간 카운터
# 주의: 이 신호 중 일부('← N agents' 상태줄, 스크롤백에 남은 '✻ Waiting…' 옛 로그)는
# 한도로 멈춰도 화면에 남아 있을 수 있다. 그래서 classify 에서는 '텍스트 한도(match_resume)'
# 를 background 보다 먼저 본다(아래 classify 주석 참고).
BACKGROUND_REGEX="[0-9]+ shells? still running|· [0-9]+ shell|running in the background|waiting for [0-9]+ (background |dynamic )?(agent|workflow|shell)|[0-9]+/[0-9]+ agents|← [0-9]+ agents?|↓ [0-9][0-9.,]*[km]? tokens|[0-9]+m [0-9]+s · ↓"

# ── 승인 대기 대화상자 (자동승인 기능) ──────────────────────────────────────
# Claude 가 도구 실행 권한을 물을 때(rm 같은 명령, 작업폴더 밖 파일 쓰기, WebFetch 등)와
# AskUserQuestion/플랜 승인처럼 사용자의 '선택'을 기다릴 때는 세션이 그 자리에서 멈춘다.
# 한도와 달리 시간이 지나도 저절로 풀리지 않으므로, 자리를 비운 사이엔 이게 더 자주 세션을
# 세운다. 아래 패턴들로 '지금 열려 있는 선택 대화상자'를 찾아 상태를 permission 으로 잡고,
# AUTO_APPROVE=1 이면 데몬이 긍정 선택지의 번호키를 눌러 그대로 진행시킨다.
#
# 실제 화면 예 (claude 2.1.x):
#    Do you want to proceed?
#    ❯ 1. Yes
#      2. Yes, and allow access to foo/ and similar commands
#      3. No
#
#    Esc to cancel · Tab to amend
#
# APPROVE_CURSOR : 선택 커서가 번호 옵션 위에 있는 줄 = '대화상자가 열려 있음'의 핵심 증거.
#                  (닫힌 뒤엔 화면에서 사라지므로 스크롤백 잔상과 구분된다)
APPROVE_CURSOR="^[[:space:]]*❯[[:space:]]*[0-9]{1,2}\."
# APPROVE_ASK    : 도구 권한 요청 특유의 질문 문구. mode=permission 일 때 이것만 인정한다.
#                  'Ready to submit'은 multiSelect 질문의 2단계(제출 확인) 화면.
#                  'quick safety check…' 는 새 폴더에서 처음 뜨는 신뢰 확인 화면이다. 실물:
#                    "Quick safety check: Is this a project you created or one you trust? …"
#                    "❯ 1. Yes, I trust this folder / 2. No, exit"
#                  mode=permission 은 이 목록만 인정하므로, 없으면 새 폴더에서 세션이 선다.
APPROVE_ASK="do you want to (proceed|create|make this edit|allow|use this api key|continue)|would you like to proceed|ready to submit your answers|quick safety check|is this a project you created"
# APPROVE_FOOTER : 선택 대화상자 공통 하단 안내. mode=all 일 때 AskUserQuestion·폴더신뢰
#                  같이 질문 문구가 자유로운 대화상자까지 잡기 위한 보조 증거.
#                  'press n to add notes'는 선택지에 미리보기 패널이 붙는 질문의 하단 안내다.
APPROVE_FOOTER="esc to cancel|enter to confirm|enter to select|tab to amend|shift\+tab to approve|press n to add notes"
# APPROVE_YES    : '그대로 진행' 선택지. 여기 맞는 선택지가 있으면 항상 이걸 우선한다.
APPROVE_YES="^yes([,. ]|$)|^submit answers|^continue([,. ]|$)"
# APPROVE_ALWAYS : '앞으로 묻지 않기' 선택지. AUTO_APPROVE_PREFER=always 일 때만 우선.
#                  세션 내내 규칙이 추가되므로 승인 횟수는 줄지만 그만큼 범위가 넓어진다.
APPROVE_ALWAYS="^yes,? and (don'?t ask again|allow)|^yes, allow all|^yes, during this session|^yes,? and use auto mode"
# APPROVE_NEVER  : 절대 고르면 안 되는 선택지(거부/취소/자유입력). 번호가 1번이어도 건너뛴다.
APPROVE_NEVER="^no([,. ]|$)|^cancel|^type something|^chat about this|^tell claude|^don'?t|^exit|^quit|^keep planning|^refine"
# APPROVE_CHECKBOX : multiSelect 질문의 체크박스. 이게 보이면 번호키는 '토글'이라
#                  번호키 → Right(제출 화면으로) 2단계로 처리한다.
APPROVE_CHECKBOX="^[[:space:]]*(❯[[:space:]]*)?[0-9]{1,2}\.[[:space:]]*\[[[:space:]✔x]\]"
# APPROVE_STALE  : 응답이 시작됐다는 표시(⏺ 응답 머리, ✻ 진행 표시). 대화상자 하단 안내
#                  '아래'에 이게 보이면 그 대화상자는 이미 답이 끝나 기록으로 남은 것이다.
#                  깊은 창(APPROVE_CAPTURE_LINES)에서만 쓰는 오탐 방지 장치.
APPROVE_STALE="^[[:space:]]*(⏺|✻)"

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
NOTIFY_PERMISSION=1   # → 🟣 승인대기 전환 시 (자동승인이 꺼져 있을 때 특히 유용)
# csm 에서 't'(알림설정)로 토글하면 아래 파일에 저장돼 위 기본값을 덮어씀(데몬도 공유)
[ -f "$_CFG_DIR/notify.conf" ] && source "$_CFG_DIR/notify.conf"

# ── 자동승인 (기본 꺼짐) ────────────────────────────────────────────────────
# 1 이면 승인대기(permission) 상태의 창에서 긍정 선택지를 데몬이 눌러 그대로 진행시킨다.
# 켜는 순간 '사람이 한 번 더 볼 기회'가 사라진다. rm·파일 덮어쓰기·외부 전송 같은 되돌리기
# 어려운 작업도 그냥 통과하므로, 감당할 수 있는 작업 창에서만 켜세요.
AUTO_APPROVE=0
# permission = 도구 권한 요청만 승인(APPROVE_ASK 문구가 있는 것만). 보수적.
# all        = 위에 더해 AskUserQuestion·플랜 승인·폴더 신뢰 같은 모든 선택 대화상자까지
#              1번(긍정) 선택지로 답한다. 자리를 완전히 비울 때 쓰는 값.
AUTO_APPROVE_MODE=all
# once   = '예'(이번 한 번만)를 고름. 매번 다시 물어보지만 범위가 가장 좁다.
# always = '예, 앞으로 묻지 않기' 선택지가 있으면 그걸 고름. 질문 수는 줄지만 그 세션 내내
#          같은 종류의 요청이 프리패스가 된다.
AUTO_APPROVE_PREFER=once
# 승인할 대화상자를 좁히는 정규식(대소문자 무시). 화면에 이 패턴이 있을 때만 승인한다.
# 빈 값이면 제한 없음. 예) rm 명령만 자동승인: AUTO_APPROVE_FILTER="rm "
AUTO_APPROVE_FILTER=""
# 이 패턴이 화면에 있으면 절대 승인하지 않는다(FILTER 보다 우선). 빈 값이면 없음.
# 예) AUTO_APPROVE_DENY="sudo|rm -rf /|git push|--force"
AUTO_APPROVE_DENY=""
APPROVE_INTERVAL=10   # 승인 전용 짧은 스캔 주기(초). 0 이면 INTERVAL 마다만 확인.
                      # 승인 대기는 시간이 지나도 안 풀려서, 한도 스캔(60초)과 달리 빨리
                      # 눌러줄수록 좋다. capture-pane 만 해서 비용은 무시할 수준.
APPROVE_RETRY_GAP=45  # 같은 대화상자가 안 닫히면 이 초 뒤 다시 눌러본다(키 유실 대비)
APPROVE_MAX_TRIES=3   # 같은 대화상자에 이 횟수까지만 시도. 넘으면 포기하고 사람을 기다린다
                      # (판정이 틀렸을 때 입력창에 번호가 무한히 쌓이는 것을 막는 안전장치)
# csm 에서 'y'(자동승인)로 바꾸면 아래 파일에 저장돼 위 기본값을 덮어씀(데몬도 공유)
[ -f "$_CFG_DIR/approve.conf" ] && source "$_CFG_DIR/approve.conf"
# 환경변수는 마지막에 적용돼 파일 설정까지 이긴다(한 번만 다르게 돌려보고 싶을 때).
AUTO_APPROVE="${CAR_AUTO_APPROVE:-$AUTO_APPROVE}"
AUTO_APPROVE_MODE="${CAR_AUTO_APPROVE_MODE:-$AUTO_APPROVE_MODE}"
AUTO_APPROVE_PREFER="${CAR_AUTO_APPROVE_PREFER:-$AUTO_APPROVE_PREFER}"
AUTO_APPROVE_FILTER="${CAR_AUTO_APPROVE_FILTER:-$AUTO_APPROVE_FILTER}"
AUTO_APPROVE_DENY="${CAR_AUTO_APPROVE_DENY:-$AUTO_APPROVE_DENY}"
case "$AUTO_APPROVE_MODE"   in permission|all) ;; *) AUTO_APPROVE_MODE=all ;; esac
case "$AUTO_APPROVE_PREFER" in once|always)    ;; *) AUTO_APPROVE_PREFER=once ;; esac
INTERVAL=60           # 감시 주기(초). 짧을수록 리셋 직후 빨리 이어감(capture라 비용 무시)
MIN_RESEND_GAP=540    # 같은 창 재주입/재알림 최소 간격(초)
RESET_BUFFER=30       # resets 시각 + 이 여유(초) 뒤부터 주입
ORG_RETRY_DELAY=18000 # 기업 한도(orglimit): 처음 감지 후 이 시간(초, 기본 5시간) 뒤 1회
                      # 재시도. 그래도 같은 문구면 차단으로 본다. (기업 계정은 5시간 한도도
                      # org 문구로 뜨므로, 5시간 지나 재시도하면 실제 5시간 한도는 풀린다.)
CAPTURE_LINES=20      # 화면 하단 몇 줄 보고 판단할지. 진짜 멈춘 한도배너는 하단 ~17줄
                      # 이내에 있음. 너무 크게 잡으면 재개 후 위로 밀려난 옛 배너를 다시 잡아
                      # limit 로 오판(잘못된 재주입). background-먼저 순서와 함께 오판을 막음.
APPROVE_CAPTURE_LINES=60  # 승인 대화상자 판정에만 쓰는 더 깊은 창.
                      # 선택지에 미리보기 패널이 붙는 질문(AskUserQuestion 등)은 대화상자
                      # 높이가 40줄을 넘어서, 번호 선택지가 화면 위쪽으로 밀려난다. 20줄만
                      # 보면 미리보기 박스 중간만 읽혀 '❯ 1.' 커서를 못 찾고 idle 로 새 버린다.
                      # 한도 판정은 위 CAPTURE_LINES(얕은 창) 그대로 두고(옛 배너 오독 방지)
                      # 승인 판정만 이 깊이로 한 번 더 본다. 너무 키우면 대화상자 위쪽 본문의
                      # 번호 목록('1. …')이 선택지로 잡힐 위험이 커지므로 한 화면 정도로 둔다.
                      # 얕은 창보다 작게 잡으면 승격 자체가 의미를 잃으므로 최소값을 맞춘다.
if [ "$APPROVE_CAPTURE_LINES" -lt "$CAPTURE_LINES" ] 2>/dev/null; then
  APPROVE_CAPTURE_LINES="$CAPTURE_LINES"
fi

export TMUX_TMPDIR="${TMUX_TMPDIR:-/tmp}"   # launchd 데몬과 tmux 소켓 공유

# ── 로케일 보장 (매우 중요) ──────────────────────────────────────────────────
# tmux 는 C/POSIX(로케일 미설정) 환경에서 capture-pane/포맷 출력의 '비인쇄' 바이트를
# 치환한다. 대표적으로 탭(0x09)→'_'(0x5f), UTF-8 박스문자/❯·↓← 등이 깨진다.
# launchd 로 뜬 데몬은 로케일이 비어 있어(C) 이 때문에:
#   · window 목록의 탭 구분자가 '_' 로 바뀌어 파싱이 전부 실패 → 어떤 창도 처리 못 함
#   · 화면 캡처의 UTF-8 문자가 깨져 BACKGROUND/LIMIT_MENU 등 정규식이 빗나갈 수 있음
# 바이트 처리는 LC_CTYPE 만 지배하므로 LC_CTYPE 만 UTF-8 로 맞춘다(LC_ALL/LC_TIME 등
# 을 건드리지 않아 date/정렬 부작용 없음). 이미 UTF-8 이면 사용자 설정을 유지한다.
# 이 파일은 데몬·csm 이 tmux 를 호출하기 전에 항상 source 되므로 로케일의 단일 소스다
# (그래서 plist 에 로케일을 박지 않는다 → CAR_LOCALE 가 데몬에도 그대로 적용됨).
# 판정은 실제 ctype 우선순위(LC_ALL > LC_CTYPE > LANG)를 따르고, 적대적 LC_ALL=C 는
# unset 해 LC_CTYPE 가 이기도록 한다. 다른 로케일은 CAR_LOCALE 로 지정(예: ko_KR.UTF-8).
case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
  *UTF-8*|*utf-8*|*UTF8*|*utf8*) ;;                      # 이미 UTF-8 → 유지
  *) unset LC_ALL; export LC_CTYPE="${CAR_LOCALE:-en_US.UTF-8}" ;;   # C/POSIX/빈값 → UTF-8
esac

# ── csm [n] 새 세션 메뉴 후보 (배포 기본은 'claude' 하나) ────────────────────
#   프로필 런처(셸 함수/alias)를 쓰면 여기에 추가하세요. 각 항목은 대상 창의
#   대화형 셸에서 그대로 실행되므로, 그 셸이 아는 명령이면 무엇이든 됩니다.
#   예: NEW_SESSION_MENU=( "claude" "claude-work" "claude-personal" )
#   추가로, ~/.claude-* 설정 디렉토리가 있으면 csm 이 자동으로 후보에 붙여줍니다.
NEW_SESSION_MENU=( "claude" )

# ── 공용 판정 헬퍼 (stdin = 화면 내용) ──────────────────────────────────────
# 화면을 한 줄로 접는다(줄바꿈·연속 공백 → 공백 하나). 창이 좁으면 안내 문구가 그대로
# 줄바꿈돼 줄 단위 grep 이 빗나가므로, '문구가 있나' 류 판정은 이걸 통과시킨 뒤에 한다.
# 줄 시작 앵커가 필요한 판정(APPROVE_CURSOR, 선택지 파싱)과 줄 번호로 위치를 비교하는
# approve_is_live 는 원문을 그대로 써야 한다.
_flatten() { tr '\n' ' ' | tr -s ' '; }
match_resume()     { grep -iE "$RESUME_REGEX"         2>/dev/null | grep -ivE "$IGNORE_REGEX" | grep -q .; }
match_blocked()    { grep -iE "$BLOCKED_NOAUTO_REGEX" 2>/dev/null | grep -ivE "$IGNORE_REGEX" | grep -q .; }
match_orglimit()   { grep -iE "$ORG_LIMIT_REGEX"      2>/dev/null | grep -ivE "$IGNORE_REGEX" | grep -q .; }
match_background() { grep -qiE "$BACKGROUND_REGEX" 2>/dev/null; }
match_working()    { grep -qiE "$WORKING_REGEX" 2>/dev/null; }
# 활성 한도 메뉴인가. 둘 다 만족해야 참이다:
#   (1) 'Stop…' 선택지가 '선택지 줄'로 렌더링돼 있다(라벨이 줄의 전부)
#       → 대화 본문에 같은 문구가 섞인 산문이나 슬래시 명령 팝업은 여기서 걸러진다
#   (2) 메뉴 제목이나 확정 안내가 화면에 있다 → 이미 닫히고 흔적만 남은 화면 제외
# 커서(❯) 유무는 조건에 넣지 않는다. 화면 하단 입력 프롬프트도 '❯ ' 로 시작해서 사실상
# 항상 참이 되고(무의미), 기업 결제 한도 메뉴는 번호 없이 '❯ 라벨' 로 그려 형태도 다르다.
match_limit_menu() {
  local c; c="$(cat)"
  printf '%s' "$c" | grep -qiE "$LIMIT_MENU_OPTLINE" \
    && printf '%s' "$c" | _flatten | grep -qiE "$LIMIT_MENU_ACTIVE"
}

# 한도 메뉴에서 'Stop…' 선택지에 커서가 올라가 있나(= 지금 Enter 를 보내면 그게 확정되나).
# 번호키를 누른 뒤 이걸로 확인하고 나서야 확정을 보낸다.
match_limit_selected() { grep -qiE "$LIMIT_MENU_SELECTED" 2>/dev/null; }

# ── 승인 대기 대화상자 판정/파싱 ────────────────────────────────────────────
# 화면(stdin)에서 번호 선택지 목록을 뽑아 "번호|라벨" 로 출력.
#   · 선택 커서('❯')는 공백으로 지워 커서가 어디 있든 같은 결과가 나오게 한다.
#   · 같은 번호가 여러 번 나오면 '화면 아래쪽 것'만 남긴다(스크롤백의 옛 목록 무시).
#   · 1번부터 끊기지 않고 이어지는 번호까지만 인정한다. 파일 diff 안의 '12. 항목' 같은
#     본문 텍스트가 우연히 선택지로 잡히는 것을 막는 장치(대화상자는 항상 1번부터다).
#   · 선택지 오른쪽에 미리보기 패널이 붙는 질문은 같은 줄에 박스 테두리('│','┌'…)와 패널
#     본문이 딸려 온다. 그 지점부터 잘라 라벨만 남긴다. 커서를 옮기면 패널 내용이 바뀌는데,
#     안 자르면 라벨이 매번 달라져 폭주 방지 해시(선택지 목록 기준)가 계속 리셋된다.
approve_options() {
  local c line num label prev
  c="$(cat)"
  printf '%s\n' "$c" \
    | sed -e 's/❯/ /g' \
    | grep -E '^[[:space:]]*[0-9]{1,2}\.[[:space:]]' \
    | sed -E 's/[[:space:]]{2,}[│┃┆┇╎╏┌└├┬┴┼─].*$//' \
    | sed -E 's/^[[:space:]]*([0-9]{1,2})\.[[:space:]]+/\1|/' \
    | awk -F'|' '{ last[$1]=$0; if (!($1 in seen)) { seen[$1]=1; order[++n]=$1 } }
                 END { for (i=1;i<=n;i++) print last[order[i]] }' \
    | sort -t'|' -k1,1n \
    | awk -F'|' 'BEGIN{want=1} $1==want { print; want++ }'
}

# 폭주 방지용 선택지 해시. 체크박스 상태([ ] / [✔])는 지우고 계산한다.
#   multiSelect 는 번호키가 '토글'이라 우리가 누를 때마다 라벨이 바뀐다. 그 상태를 그대로
#   해시에 넣으면 매 시도마다 값이 달라져 '반응이 있었다'로 읽히고 실패 카운트가 0으로
#   리셋된다 → APPROVE_MAX_TRIES 가 영영 걸리지 않아 무한 토글이 된다(실측: 10회 이상
#   반복해도 멈추지 않음). 체크 상태를 빼면 같은 화면은 같은 해시가 되어 가드가 살아난다.
approve_hash() {
  approve_options | sed -E 's/^([0-9]{1,2}\|)[[:space:]]*\[[^]]*\][[:space:]]*/\1/' \
    | cksum | awk '{print $1}'
}

# 활성 한도 메뉴에서 'Stop…' 선택지의 번호를 출력(못 찾으면 빈값).
#   위치가 아니라 라벨로 찾는다. 예전에는 'Up Up 으로 최상단'이라는 위치 가정에 기대
#   화살표를 보냈는데, 바이너리를 보면 그 메뉴의 선택지 순서는 기능플래그에 따라 뒤집힌다
#   ('Stop' 이 첫 번째일 수도 마지막일 수도 있다). 위치 가정 자체가 틀렸던 것이다.
#   라벨 전체가 그 문구여야 인정한다($LIMIT_MENU_OPT 는 OR 를 품고 있어 괄호로 묶는다).
#   번호가 안 붙는 메뉴(기업 결제 한도)는 여기서 빈값이 나오고, 데몬은 키를 보내지 않는다.
#   선택지 파싱은 approve_options 를 그대로 쓴다(1..N 연속 번호만 인정하므로 본문 텍스트가
#   섞여 들어오지 않는다). 이 함수는 그래서 approve_options 아래에 둔다.
limit_menu_pick() {
  approve_options | grep -iE "^[0-9]{1,2}\|[[:space:]]*($LIMIT_MENU_OPT)[[:space:]]*$" | head -1 | cut -d'|' -f1
}

# 지금 화면에 '열려 있는' 선택 대화상자가 있나. 커서 줄 + (질문 문구 | 하단 안내) 둘 다 필요.
#   mode=permission 이면 도구 권한 질문(APPROVE_ASK)만 인정한다.
match_permission() {
  local c flat; c="$(cat)"
  printf '%s' "$c" | grep -qE "$APPROVE_CURSOR" || return 1
  # 한도 메뉴는 한도 로직이 전담한다. 여기서 손대면 'Continue with a different model' 같은
  # 선택지를 긍정으로 오인해 모델을 바꿔 버릴 수 있다(classify 가 먼저 걸러 주지만,
  # 메뉴 판정이 어긋난 경우까지 대비해 여기서도 막는다).
  printf '%s' "$c" | approve_options | cut -d'|' -f2- | grep -qiE "$LIMIT_MENU_LABELS" && return 1
  # 문구 판정은 화면을 한 줄로 접어서 한다. 좁은 창(78컬럼)에서는 안내 문구가 그대로
  # 줄바꿈되는데("… Would you like to" / "proceed?"), 줄 단위 grep 은 그걸 못 잡는다.
  # 실제로 mode=permission 에서 계획 승인 대화상자가 통째로 idle 로 새어 세션이 방치됐다.
  flat="$(printf '%s' "$c" | _flatten)"
  printf '%s' "$flat" | grep -qiE "$APPROVE_ASK" && return 0
  [ "${AUTO_APPROVE_MODE:-all}" = all ] || return 1
  printf '%s' "$flat" | grep -qiE "$APPROVE_FOOTER"
}

# 화면(stdin)에서 누를 선택지 번호를 출력. 누르면 안 되면 빈값.
#   우선순위: PREFER=always 면 '앞으로 묻지 않기' → 없으면 '예' → mode=all 이면 첫 유효 선택지
approve_pick() {
  local c opts num label pick_yes="" pick_always="" pick_first=""
  c="$(cat)"
  opts="$(printf '%s' "$c" | approve_options)"
  [ -z "$opts" ] && return 0
  while IFS='|' read -r num label; do
    [ -z "$num" ] && continue
    [ "$num" -gt 9 ] && continue                      # 번호키 하나로 못 누름 → 사람에게 맡김
    label="$(printf '%s' "$label" | sed -E 's/^\[[^]]*\][[:space:]]*//' | tr 'A-Z' 'a-z')"
    printf '%s' "$label" | grep -qE "$APPROVE_NEVER" && continue
    [ -z "$pick_first" ] && pick_first="$num"
    [ -z "$pick_always" ] && printf '%s' "$label" | grep -qE "$APPROVE_ALWAYS" && pick_always="$num"
    [ -z "$pick_yes" ]    && printf '%s' "$label" | grep -qE "$APPROVE_YES"    && pick_yes="$num"
  done <<EOF
$opts
EOF
  if [ "${AUTO_APPROVE_PREFER:-once}" = always ] && [ -n "$pick_always" ]; then printf '%s' "$pick_always"; return 0; fi
  [ -n "$pick_yes" ] && { printf '%s' "$pick_yes"; return 0; }
  [ "${AUTO_APPROVE_MODE:-all}" = all ] && printf '%s' "$pick_first"
  return 0
}

# multiSelect 질문인가(선택지에 체크박스가 있나). 번호키가 '확정'이 아니라 '토글'이라
# 누른 뒤 Right 로 제출 화면까지 넘겨야 한다.
match_checkbox() { grep -qE "$APPROVE_CHECKBOX" 2>/dev/null; }

# 창 이름이 자동승인 제외 목록에 있나 (자동재개 제외(disabled.list)도 자동승인을 막는다)
is_noapprove() {
  [ -n "$1" ] || return 0
  is_disabled "$1" && return 0
  [ -f "$NOAPPROVE_LIST" ] && grep -qxF "$1" "$NOAPPROVE_LIST"
}

# 화면 내용(stdin)을 단일 상태로 분류(csm·데몬 공용). 우선순위 순서:
#   working | limit(활성 메뉴) | blocked | orglimit | limit(텍스트) | permission | background | idle
# · working(esc to interrupt)이 최우선: 메인 에이전트가 지금 생성 중이면 무조건 작업중.
#   재개 후 다시 돌기 시작하면 이 신호가 떠서, 옛 한도 배너가 화면에 남아 있어도 limit 로
#   오판하지 않는다(재주입 방지의 1차 방어선).
# · 활성 한도 메뉴(match_limit_menu: 'Enter to confirm · Esc to cancel' 가 함께 뜬 열린
#   메뉴)는 지금 당장 처리해야 할 live 프롬프트라 그다음으로 본다.
# · orglimit(기업 월 결제 한도)은 background 보다 먼저 본다(자세한 이유는 위 정의 참고).
# · 텍스트 한도(match_resume)를 background 보다 '먼저' 본다: background 신호 중 일부는
#   한도로 멈춰도 화면에 남는다 — claude 하단 상태줄의 '← N agents'(세션에 정의된 서브
#   에이전트 수, 상시 표시)나, 스크롤백에 굳은 '✻ Waiting…' 옛 로그 등. 그래서 background
#   가 한도보다 먼저면 진짜 멈춘 한도가 background 로 가려져 재개가 안 된다. 실제로 작업이
#   도는 중이면 위의 working(esc to interrupt)이 먼저 잡으므로, 여기서 한도를 먼저 봐도
#   '재개 후 아직 도는 세션'을 한도로 오판하지 않는다.
# · permission(승인 대기 대화상자)은 한도 판정을 모두 마친 뒤에 본다. 한도 처리 로직을
#   건드리지 않기 위해서다. 대신 background 보다는 먼저 봐야 한다 — 백그라운드 셸이 도는
#   중에도 권한 질문은 뜨고, 그때 background 로 가려지면 아무도 눌러주지 않는다.
classify() {
  local c; c="$(cat)"
  if   printf '%s' "$c" | match_working;     then printf working
  elif printf '%s' "$c" | match_limit_menu;  then printf limit
  elif printf '%s' "$c" | match_blocked;     then printf blocked
  elif printf '%s' "$c" | match_orglimit;    then printf orglimit
  elif printf '%s' "$c" | match_resume;      then printf limit
  elif printf '%s' "$c" | match_permission;  then printf permission
  elif printf '%s' "$c" | match_background;  then printf background
  else printf idle; fi
}

# 깊은 창에 보이는 대화상자가 '지금 살아 있는' 것인가.
#   마지막 하단 안내(FOOTER/ASK) 줄 아래로 응답 시작 표시(APPROVE_STALE)가 있으면, 그
#   대화상자는 이미 답이 끝나고 대화 기록으로 남은 것이다 → 건드리면 안 된다.
#   판정은 grep -E 로 한다. awk 의 -v 로 패턴을 넘기면 'shift\+tab' 같은 이스케이프가
#   할당 단계에서 깨져('+'가 수량자가 됨) 그 문구만 조용히 안 잡힌다.
approve_is_live() {
  local c last stale
  c="$(cat)"
  last="$(printf '%s\n' "$c" | grep -niE "$APPROVE_FOOTER|$APPROVE_ASK" | tail -1 | cut -d: -f1)"
  [ -n "$last" ] || return 1                      # 하단 안내가 아예 없음 → 대화상자 아님
  stale="$(printf '%s\n' "$c" | grep -nE "$APPROVE_STALE" | tail -1 | cut -d: -f1)"
  [ -n "$stale" ] || return 0                     # 안내 아래로 응답 없음 → 살아 있음
  [ "$stale" -le "$last" ]                        # 응답이 안내보다 위면 살아 있음
}

# classify 를 두 창으로 돌린다: 한도 판정은 얕은 창(CAPTURE_LINES) 그대로, 승인 대화상자만
# 깊은 창(APPROVE_CAPTURE_LINES)에서 한 번 더 찾는다.
#   미리보기 패널이 붙는 질문은 대화상자 높이가 40줄을 넘어 번호 선택지가 얕은 창 위로
#   밀려난다. 그러면 커서 줄이 안 보여 idle 로 새고, 아무도 눌러주지 않는다.
#   깊은 창을 쓰는 곳을 승인으로만 한정하는 이유: 한도 판정에서 창을 키우면 재개 후 위로
#   밀려난 옛 한도 배너를 다시 잡아 잘못 재주입할 수 있다(CAPTURE_LINES 주석 참고).
#   그래서 얕은 판정이 idle/background 로 끝났을 때만 승격을 시도한다. working/limit/
#   blocked/orglimit 이 먼저 잡혔으면 그쪽 우선순위를 그대로 존중한다.
#   승격에는 조건이 둘 더 붙는다. (1) 하단 안내가 '얕은 창 안에' 있어야 한다 — 살아 있는
#   대화상자는 화면 맨 아래에서 끝나기 때문이다. (2) approve_is_live 로 그 안내 아래에
#   응답이 시작되지 않았는지 본다. 창을 깊게 파면 이미 답이 끝난 옛 대화상자가 스크롤백에
#   그대로 남아 걸리는데(Claude 는 답한 질문도 기록에 그려 둔다), 이 둘로 가른다.
classify_deep() {  # $1=얕은 화면, $2=깊은 화면
  local s; s="$(printf '%s' "$1" | classify)"
  case "$s" in
    idle|background)
      if printf '%s' "$1" | _flatten | grep -qiE "$APPROVE_FOOTER|$APPROVE_ASK" \
         && printf '%s' "$2" | approve_is_live \
         && printf '%s' "$2" | match_permission; then printf permission; return 0; fi ;;
  esac
  printf '%s' "$s"
}

# 창 이름이 자동재개 제외 목록에 있나
is_disabled() { [ -n "$1" ] && [ -f "$DISABLED_LIST" ] && grep -qxF "$1" "$DISABLED_LIST"; }

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
  local content raw hour min ampm h2 m2 tz tzpfx day epoch now epoch2 rel rh rm secs md day2
  content="$(cat)"
  # (0) 상대 시간형 "resets in 2h 30m" / "resets in 45m".
  #     claude 는 절대 시각형과 이 형태를 함께 쓴다(바이너리에 'resets in ' 템플릿 존재).
  #     예전에는 이 형식을 못 읽어 빈값 → '시각 불명' → 리셋 전에 재개를 주입하고,
  #     실패하면 MIN_RESEND_GAP 마다 반복했다.
  rel="$(printf '%s' "$content" | grep -oiE 'resets in [0-9]+[hm]([[:space:]]*[0-9]+m)?' | head -1)"
  if [ -n "$rel" ]; then
    rh="$(printf '%s' "$rel" | grep -oiE '[0-9]+h' | tr -dc '0-9')"; rh="${rh:-0}"
    rm="$(printf '%s' "$rel" | grep -oiE '[0-9]+m' | tr -dc '0-9')"; rm="${rm:-0}"
    secs=$(( 10#$rh * 3600 + 10#$rm * 60 ))
    [ "$secs" -le 0 ] && { printf 'PASSED'; return 0; }
    # 5시간 한도의 잔여시간이라기엔 너무 멀면(6시간 초과) 주간 한도 쪽이므로 대기 대상이 아니다.
    [ "$secs" -gt 21600 ] && { printf 'PASSED'; return 0; }
    printf '%s' $(( $(date +%s) + secs )); return 0
  fi
  # (1) 절대 시각형. 날짜가 앞에 붙는 변형이 있다 — 실물 확인:
  #     "resets Jul 30 at 3pm (Asia/Seoul)".  예전 정규식은 'resets' 바로 뒤에 시각이
  #     오는 것만 봐서 이 형태를 통째로 놓쳤다.
  raw="$(printf '%s' "$content" \
        | grep -oiE 'resets[[:space:]]+([A-Za-z]{3,9}[[:space:]]+[0-9]{1,2}[[:space:]]+)?(at[[:space:]]+)?[0-9]{1,2}(:[0-9]{2})?[[:space:]]*(am|pm)?' \
        | head -1)"
  # 날짜 조각("Jul 30")이 있으면 그 날짜를 기준일로 삼는다(없으면 아래에서 오늘로 계산).
  md="$(printf '%s' "$raw" | grep -oiE '^resets[[:space:]]+[A-Za-z]{3,9}[[:space:]]+[0-9]{1,2}' \
        | sed -E 's/^[Rr]esets[[:space:]]+//')"
  # 시각 조각은 맨 뒤 것을 쓴다(날짜의 일(日) 숫자가 먼저 잡히므로 tail -1).
  raw="$(printf '%s' "$raw" | grep -oiE '[0-9]{1,2}(:[0-9]{2})?[[:space:]]*(am|pm)?' | tail -1)"
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
  # 배너에 날짜가 명시돼 있으면("resets Jul 30 at 3pm") 그 날짜를 쓴다. 연도는 화면에
  # 없으므로 올해로 본다(연말 경계에서만 어긋나고, 그때는 아래 6시간 창에서 PASSED 로 빠진다).
  # LC_TIME=C 가 필요하다: 배너의 월 이름은 항상 영문("Jul")인데, 한국어 로케일에서는
  # BSD date 의 %b 가 그걸 못 읽어 변환이 통째로 실패한다(그러면 날짜를 무시하고 오늘로
  # 계산해 버린다). 로케일 강제는 이 한 줄에만 걸어 다른 출력에는 영향을 주지 않는다.
  if [ -n "$md" ]; then
    day2="$(env $tzpfx LC_TIME=C date -j -f "%b %d %Y" "$md $(env $tzpfx date +%Y)" +%Y-%m-%d 2>/dev/null)"
    [ -n "$day2" ] && day="$day2"
  fi
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
