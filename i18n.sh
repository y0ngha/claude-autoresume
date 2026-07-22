#!/usr/bin/env bash
# ============================================================================
# claude-autoresume i18n — UI 문자열 다국어 테이블
#   기본 언어: en. 토글: 환경변수 CAR_LANG=ko (또는 en)
#   사용: t <key> → 현재 언어의 문자열(printf 포맷) 반환. 없으면 en 으로 폴백.
#   포맷 문자열엔 %s/%d 만 사용(색상/패딩은 호출부에서). bash 3.2 호환(연관배열 X).
# ============================================================================
CAR_LANG="${CAR_LANG:-en}"

t() {
  local v; v="$(_msg_"${CAR_LANG}" "$1" 2>/dev/null)"
  [ -z "$v" ] && v="$(_msg_en "$1")"
  printf '%s' "$v"
}

_msg_en() { case "$1" in
  # ── dashboard (csm) ──
  title)          printf ' ⌘ Claude Session Manager ' ;;
  daemon_on)      printf '● auto-resume ON' ;;
  daemon_off)     printf '○ auto-resume OFF' ;;
  keys)           printf '  [a]attach [n]new [k]kill [p]auto-toggle [t]alerts [l]lang [r]refresh [q]quit · refresh %%ss' ;;
  no_session)     printf "No session '%%s'. Press [n] to start one." ;;
  # state labels (label part padded to 11 cols so columns align)
  st_working)     printf '🟢 working    ' ;;
  st_blocked)     printf '⛔ blocked    ' ;;
  st_limit)       printf '🟡 limit-wait ' ;;
  st_bg)          printf '🔵 background ' ;;
  st_idle)        printf '⚪ idle       ' ;;
  st_resets)      printf '· resets %%s (%%s)' ;;
  # relative time
  ago_sec)        printf '%%ss ago' ;;
  ago_min)        printf '%%dm ago' ;;
  ago_hm)         printf '%%dh %%dm ago' ;;
  left_sec)       printf '%%ds left' ;;
  left_min)       printf '%%dm left' ;;
  left_hm)        printf '%%dh %%dm left' ;;
  # row suffixes
  row_active)     printf '· active %%s' ;;
  row_inject)     printf '· auto-inject %%s' ;;
  excluded)       printf '⏸excluded' ;;
  summary)        printf '%%d sessions  ·  🟢 working %%d  🔵 background %%d  🟡 limit-wait %%d  ⛔ blocked %%d  ⚪ idle %%d' ;;
  recent_title)   printf 'Recent auto-resume activity' ;;
  # ── actions ──
  cancel)         printf 'cancel' ;;
  attach_list)    printf 'Windows to attach:' ;;
  attach_prompt)  printf 'number/name (empty=active window, esc=cancel): ' ;;
  no_window)      printf "no window '%%s'" ;;
  new_name)       printf 'new window name (esc=cancel): ' ;;
  select_profile) printf 'select profile/command:' ;;
  new_num)        printf 'number [1] (esc=cancel): ' ;;
  new_args)       printf 'extra args (e.g. --resume / --continue, empty=none, esc=cancel): ' ;;
  win_exists)     printf "window '%%s' already exists." ;;
  running)        printf "▶ running in '%%s': %%s" ;;
  kill_list)      printf 'Windows to kill:' ;;
  kill_prompt)    printf 'number/name (esc=cancel): ' ;;
  killed)         printf "'%%s' killed" ;;
  notfound)       printf "no '%%s'" ;;
  toggle_list)    printf 'Toggle auto-resume for window:' ;;
  toggle_prompt)  printf 'window name (esc=cancel): ' ;;
  toggle_on)      printf "'%%s' auto-resume ON" ;;
  toggle_off)     printf "'%%s' auto-resume OFF (excluded)" ;;
  notify_title)   printf 'Notify on state change (toggle):' ;;
  notify_prompt)  printf 'number 1-5 (esc=cancel): ' ;;
  # ── shell functions (cbg/cba/...) ──
  sh_no_session)  printf 'no claude session' ;;
  sh_attach_prompt) printf 'number/name (empty=whole session): ' ;;
  sh_win_exists)  printf "window '%%s' already exists. attach: cba %%s" ;;
  sh_launched)    printf "▶ tmux[claude] window '%%s': %%s   (attach: cba / detach: Ctrl-b d)" ;;
  sh_killed_all)  printf 'claude session fully terminated' ;;
  # ── daemon notifications ──
  ntf_idle_title)       printf 'Claude: idle' ;;
  ntf_idle_body)        printf "Window '%%s' stopped (finished or awaiting input)" ;;
  ntf_working_title)    printf 'Claude: working' ;;
  ntf_working_body)     printf "Window '%%s' started generating" ;;
  ntf_background_title) printf 'Claude: background' ;;
  ntf_background_body)  printf "Window '%%s' is running background work" ;;
  ntf_limit_title)      printf 'Claude: limit reached' ;;
  ntf_limit_body)       printf "Window '%%s' hit the session limit (waiting for reset)" ;;
  ntf_blocked_title)    printf 'Claude: blocked' ;;
  ntf_blocked_body)     printf "Window '%%s' blocked (billing/weekly) — manual check needed" ;;
  # ── daemon log ──
  lg_state)       printf "%%s [%%s] %%s (window='%%s')" ;;
  lg_menu)        printf "🟡 limit menu → auto-selected 'Stop and wait': %%s (window='%%s')" ;;
  lg_start)       printf 'watcher started (session=%%s, interval=%%ss, gap=%%ss)' ;;
  lg_no_session)  printf "session '%%s' not found — waiting" ;;
  lg_idle)        printf "✅ %%s idle transition (finished/awaiting input): window='%%s'" ;;
  lg_blocked)     printf "⛔ auto-resume not possible: %%s (window='%%s') — manual check needed" ;;
  lg_excluded)    printf "⏸ %%s auto-resume excluded (disabled): window='%%s'" ;;
  lg_waiting)     printf "⏳ %%s session limit — waiting for resets (eta %%s, window='%%s')" ;;
  lg_inject)      printf "▶ resume injected (%%s): %%s (window='%%s')" ;;
  lg_gap)         printf '… %%s session limit detected but injected recently (gap wait)' ;;
  lbl_passed)     printf 'resets passed' ;;
  lbl_unknown)    printf 'time unknown' ;;
  # ── injected resume prompt (typed into the stalled session) ──
  continue_prompt) printf 'Continue. Pick up the previous task and finish it to completion.' ;;
  # ── install / uninstall ──
  in_title)       printf '== claude-autoresume install (%%s) ==' ;;
  in_tmux_ok)     printf '✓ tmux: %%s' ;;
  in_tmux_get)    printf 'installing tmux (brew)...' ;;
  in_tmux_done)   printf '✓ tmux installed' ;;
  in_daemon)      printf '✓ daemon registered/started: %%s' ;;
  in_daemon_fail) printf '(check failed — see launchd.err.log)' ;;
  in_zsh_have)    printf '• .zshrc already sources the shell functions (skipped)' ;;
  in_zsh_inline)  printf '• .zshrc already has an inline function block (kept as-is)' ;;
  in_zsh_add)     printf '✓ added to .zshrc: %%s' ;;
  in_done)        printf 'Done. Open a new terminal or run  source ~/.zshrc  then:' ;;
  un_title)       printf '== claude-autoresume uninstall ==' ;;
  un_booted)      printf '✓ daemon stopped: %%s' ;;
  un_plist)       printf '✓ plist removed: %%s' ;;
  un_manual)      printf 'Manual cleanup:' ;;
  un_zsh)         printf "  • remove the 'source .../shell-functions.zsh' line from ~/.zshrc" ;;
  un_purge_hint)  printf '  • to delete the folder too: bash %%s/uninstall.sh --purge' ;;
  un_purge_ask)   printf 'Really delete %%s ? (y/N) ' ;;
  un_purged)      printf '✓ deleted' ;;
  un_canceled)    printf 'canceled' ;;
  *) printf '' ;;
esac; }

_msg_ko() { case "$1" in
  title)          printf ' ⌘ Claude 세션 매니저 ' ;;
  daemon_on)      printf '● 자동재개 ON' ;;
  daemon_off)     printf '○ 자동재개 OFF' ;;
  keys)           printf '  [a]접속 [n]새세션 [k]종료 [p]자동재개토글 [t]알림 [l]언어 [r]새로고침 [q]종료 · 새로고침 %%ss' ;;
  no_session)     printf "세션 '%%s' 없음. [n] 으로 새 세션을 시작하세요." ;;
  st_working)     printf '🟢 작업중    ' ;;
  st_blocked)     printf '⛔ 차단      ' ;;
  st_limit)       printf '🟡 한도대기  ' ;;
  st_bg)          printf '🔵 백그라운드' ;;
  st_idle)        printf '⚪ 유휴      ' ;;
  st_resets)      printf '· resets %%s (%%s)' ;;
  ago_sec)        printf '%%ss 전' ;;
  ago_min)        printf '%%dm 전' ;;
  ago_hm)         printf '%%dh %%dm 전' ;;
  left_sec)       printf '%%d초 남음' ;;
  left_min)       printf '%%d분 남음' ;;
  left_hm)        printf '%%d시간 %%d분 남음' ;;
  row_active)     printf '· 활동 %%s' ;;
  row_inject)     printf '· 자동주입 %%s' ;;
  excluded)       printf '⏸제외' ;;
  summary)        printf '%%d개 세션  ·  🟢 작업중 %%d  🔵 백그라운드 %%d  🟡 한도대기 %%d  ⛔ 차단 %%d  ⚪ 유휴 %%d' ;;
  recent_title)   printf '최근 자동재개 활동' ;;
  cancel)         printf '취소' ;;
  attach_list)    printf '접속할 창:' ;;
  attach_prompt)  printf '번호/이름 (엔터=현재 활성창, esc=취소): ' ;;
  no_window)      printf "'%%s' 창 없음" ;;
  new_name)       printf '새 창 이름 (esc=취소): ' ;;
  select_profile) printf '프로필/명령 선택:' ;;
  new_num)        printf '번호 [1] (esc=취소): ' ;;
  new_args)       printf '추가 인자 (예: --resume / --continue, 엔터=없음, esc=취소): ' ;;
  win_exists)     printf "이미 '%%s' 창이 있습니다." ;;
  running)        printf "▶ '%%s' 에서 실행: %%s" ;;
  kill_list)      printf '종료할 창:' ;;
  kill_prompt)    printf '번호/이름 (esc=취소): ' ;;
  killed)         printf "'%%s' 종료됨" ;;
  notfound)       printf "'%%s' 없음" ;;
  toggle_list)    printf '자동재개 토글할 창:' ;;
  toggle_prompt)  printf '창 이름 (esc=취소): ' ;;
  toggle_on)      printf "'%%s' 자동재개 ON" ;;
  toggle_off)     printf "'%%s' 자동재개 OFF (제외)" ;;
  notify_title)   printf '상태 전환 시 알림 (토글):' ;;
  notify_prompt)  printf '번호 1-5 (esc=취소): ' ;;
  sh_no_session)  printf 'claude 세션 없음' ;;
  sh_attach_prompt) printf '번호/이름 (엔터=세션 전체): ' ;;
  sh_win_exists)  printf "이미 '%%s' 창이 있습니다. 접속: cba %%s" ;;
  sh_launched)    printf "▶ tmux[claude] 창 '%%s': %%s   (접속: cba / 나오기: Ctrl-b d)" ;;
  sh_killed_all)  printf 'claude 세션 전체 종료됨' ;;
  ntf_idle_title)       printf 'Claude: 유휴' ;;
  ntf_idle_body)        printf "창 '%%s' 작업이 멈춤 (완료 또는 입력 대기)" ;;
  ntf_working_title)    printf 'Claude: 작업 시작' ;;
  ntf_working_body)     printf "창 '%%s' 생성 시작" ;;
  ntf_background_title) printf 'Claude: 백그라운드' ;;
  ntf_background_body)  printf "창 '%%s' 백그라운드 작업 중" ;;
  ntf_limit_title)      printf 'Claude: 한도 도달' ;;
  ntf_limit_body)       printf "창 '%%s' 세션 한도 도달 (리셋 대기)" ;;
  ntf_blocked_title)    printf 'Claude: 차단' ;;
  ntf_blocked_body)     printf "창 '%%s' 차단(결제/주간) — 수동 확인 필요" ;;
  lg_state)       printf "%%s [%%s] %%s (window='%%s')" ;;
  lg_menu)        printf "🟡 한도 메뉴 → 'Stop and wait' 자동선택: %%s (window='%%s')" ;;
  lg_start)       printf 'watcher 시작 (session=%%s, interval=%%ss, gap=%%ss)' ;;
  lg_no_session)  printf "세션 '%%s' 없음 — 대기" ;;
  lg_idle)        printf "✅ %%s 유휴 전환(완료/입력대기): window='%%s'" ;;
  lg_blocked)     printf "⛔ 자동재개 불가 차단: %%s (window='%%s') — 수동 확인 필요" ;;
  lg_excluded)    printf "⏸ %%s 자동재개 제외됨(disabled): window='%%s'" ;;
  lg_waiting)     printf "⏳ %%s 세션한도 — resets까지 대기 (예정 %%s, window='%%s')" ;;
  lg_inject)      printf "▶ 이어가기 주입(%%s): %%s (window='%%s')" ;;
  lg_gap)         printf '… %%s 세션한도 감지됐지만 최근 주입함 (gap 대기 중)' ;;
  lbl_passed)     printf 'resets 경과' ;;
  lbl_unknown)    printf '시각 미상' ;;
  continue_prompt) printf '계속 진행해줘. 이전에 하던 작업을 끝까지 이어서 완료해.' ;;
  in_title)       printf '== claude-autoresume 설치 (%%s) ==' ;;
  in_tmux_ok)     printf '✓ tmux: %%s' ;;
  in_tmux_get)    printf 'tmux 설치 중 (brew)...' ;;
  in_tmux_done)   printf '✓ tmux 설치됨' ;;
  in_daemon)      printf '✓ 데몬 등록/기동: %%s' ;;
  in_daemon_fail) printf '(확인 실패 — launchd.err.log 확인)' ;;
  in_zsh_have)    printf '• .zshrc 이미 셸 함수를 source 함 (건너뜀)' ;;
  in_zsh_inline)  printf '• .zshrc 에 인라인 함수 블록이 이미 있음 (그대로 사용)' ;;
  in_zsh_add)     printf '✓ .zshrc 에 추가: %%s' ;;
  in_done)        printf '설치 완료. 새 터미널을 열거나  source ~/.zshrc  후:' ;;
  un_title)       printf '== claude-autoresume 제거 ==' ;;
  un_booted)      printf '✓ 데몬 내림: %%s' ;;
  un_plist)       printf '✓ plist 삭제: %%s' ;;
  un_manual)      printf '남은 정리(수동):' ;;
  un_zsh)         printf "  • ~/.zshrc 의 'source .../shell-functions.zsh' 줄 삭제" ;;
  un_purge_hint)  printf '  • 폴더까지 지우려면: bash %%s/uninstall.sh --purge' ;;
  un_purge_ask)   printf '정말 %%s 를 삭제할까요? (y/N) ' ;;
  un_purged)      printf '✓ 삭제됨' ;;
  un_canceled)    printf '취소' ;;
  *) printf '' ;;
esac; }
