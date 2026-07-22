# ============================================================================
# claude-autoresume 셸 함수 — ~/.zshrc 에서 아래 한 줄로 불러쓰기:
#     source ~/Project/claude-autoresume/shell-functions.zsh
# (기존에 .zshrc 에 직접 넣어둔 블록이 있다면 그건 지우고 이걸 source 하세요)
# ============================================================================
export TMUX_TMPDIR="${TMUX_TMPDIR:-/tmp}"   # launchd 감시자와 tmux 소켓 공유
# 이 파일이 어디에 있든 자동으로 설치 폴더를 잡음(경로 하드코딩 없음)
_CAR_DIR="${${(%):-%x}:A:h}"
# tmux 실행 파일 자동 탐지(Apple Silicon/Intel/기타)
_CAR_TMUX="$(command -v tmux 2>/dev/null || echo /opt/homebrew/bin/tmux)"

# i18n 메시지 해석(서브셸에서 처리 → 대화형 셸 네임스페이스 오염 없음).
# 언어 우선순위: 환경변수 CAR_LANG > lang 파일(csm [l] 로 토글) > en
_carmsg() { ( CAR_LANG="${CAR_LANG:-$(cat "$_CAR_DIR/lang" 2>/dev/null)}"
              CAR_LANG="${CAR_LANG:-en}"; source "$_CAR_DIR/i18n.sh"; t "$1" ); }

# 백그라운드 tmux 세션(claude)에 새 창을 열어 claude(변형)를 실행
# 사용법: cbg <창이름> <명령> [명령에 그대로 전달할 args...]
#   예: cbg job1 claude --resume
#       cbg job2 claude-work --continue     # 'claude-work' 는 사용자 프로필 런처 예시
#   · 2번째 = 실행할 명령(프로파일). 그 뒤 인자는 전부 그 명령에 그대로 전달.
#   · 작업 디렉토리 = 현재 폴더($PWD). 특정 폴더면 먼저 cd 후 실행.
cbg() {
  local name="${1:?usage: cbg <window> <command> [args...]}"; shift
  local cmd="${1:-claude}"; (( $# )) && shift
  local dir="$PWD" line="$cmd"
  (( $# )) && line="$cmd ${(j: :)${(q)@}}"
  if ! $_CAR_TMUX has-session -t claude 2>/dev/null; then
    $_CAR_TMUX new-session -d -s claude -n "$name" -c "$dir"
  else
    if $_CAR_TMUX list-windows -t claude -F '#{window_name}' 2>/dev/null | grep -qxF "$name"; then
      printf "$(_carmsg sh_win_exists)\n" "$name" "$name"; return 1
    fi
    $_CAR_TMUX new-window -t claude -n "$name" -c "$dir"
  fi
  $_CAR_TMUX send-keys -t "claude:$name" "$line" Enter
  printf "$(_carmsg sh_launched)\n" "$name" "$line"
}

# 세션 접속. 인자로 창을 주면 그 창으로, 없으면 창 목록을 보여주고 선택.
#   나오기(detach): Ctrl-b 다음 d
cba() {
  local w="$1"
  if [ -z "$w" ]; then
    $_CAR_TMUX has-session -t claude 2>/dev/null || { echo "$(_carmsg sh_no_session)"; return 1; }
    printf '%s\n' "$(_carmsg attach_list)"
    $_CAR_TMUX list-windows -t claude -F '    #{window_index}) #{window_name}' 2>/dev/null
    printf '  %s' "$(_carmsg sh_attach_prompt)"; read -r w
  fi
  $_CAR_TMUX attach -t "claude${w:+:$w}"   # 빈 입력=세션 전체
}

cbls()  { $_CAR_TMUX list-windows -t claude 2>/dev/null || echo "$(_carmsg sh_no_session)"; }   # 창 목록
cbpeek(){ $_CAR_TMUX capture-pane -p -t "claude:${1:?window}" -S -30; }                          # 창 하단 30줄 엿보기
cbk()   { $_CAR_TMUX kill-window  -t "claude:${1:?window}" && printf "$(_carmsg killed)\n" "$1"; } # 창 하나 종료
cbkill(){ $_CAR_TMUX kill-session -t claude && echo "$(_carmsg sh_killed_all)"; }                # 전체 종료
csm()   { bash "$_CAR_DIR/session-manager.sh" "$@"; }                                            # 세션 매니저 대시보드
