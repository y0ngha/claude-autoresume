# claude-autoresume

English README: [README.en.md](README.en.md)

Claude Code를 오래 돌리다 보면 5시간 사용 한도에 걸려 세션이 멈춥니다.
자는 동안이나 자리를 비운 사이에 멈추면, 한도가 풀려도 다시 눌러주는 사람이 없어 작업이 그대로 방치됩니다.
claude-autoresume는 한도로 멈춘 세션을 알아채서, 한도가 풀리는 시각이 지나면 그 세션에 직접 "계속 진행" 메시지를 보내 하던 작업을 이어가게 합니다.
세션을 여러 개 동시에 돌려도 각각 지켜보며, csm 대시보드로 모든 세션의 상태를 한눈에 보고 다룰 수 있습니다.

---

## 어떻게 동작하나

각 Claude 세션은 tmux 세션 `claude` 안의 개별 창에서 돌아갑니다.
launchd 데몬이 이 창들을 주기적으로 살펴보다가, 한도 문구가 보이면 리셋 시각이 지난 뒤에 "계속 진행" 메시지를 그 창에 입력합니다.
터미널 위에서 동작하기 때문에 창마다 실행 명령이나 프로필이 달라도 상관없습니다.

macOS에서만 동작합니다. launchd와 BSD `date`를 씁니다.
화면 UI는 기본이 영어이고, csm에서 `l` 키로 한국어로 바꿀 수 있습니다.
한도와 사용량 감지는 Claude가 화면에 띄우는 영어 문구를 기준으로 합니다.

---

## 필요한 것

| 도구 | 이유 | 설치 |
|---|---|---|
| zsh | 셸 함수 `cbg`, `cba`, `csm` 등이 zsh 전용 문법을 씁니다 | macOS 기본 셸 |
| tmux | 데몬이 읽고 입력할 수 있는 백그라운드 창에서 각 세션을 띄웁니다 | `brew install tmux`, 설치기가 알아서 처리 |
| Claude Code CLI | 이어서 진행할 대상 | 이미 설치돼 있어야 합니다 |
| bash, launchd, osascript | 데몬, 시작 등록, 알림 | macOS에 기본 내장 |

이 외에 필요한 것은 없습니다. 어디로도 데이터를 보내지 않고 로컬 터미널만 읽고 입력합니다.

셸 함수는 zsh에서만 동작합니다. oh-my-zsh도 zsh 위에서 도는 프레임워크라 그대로 됩니다.
bash를 기본 셸로 쓰면 함수가 올라오지 않습니다.
데몬과 대시보드는 기본 셸과 상관없이 언제나 bash로 실행됩니다.

---

## 시작하기

```sh
bash ~/Project/claude-autoresume/install.sh   # tmux 확인, 데몬 등록, 셸 함수 연결
source ~/.zshrc                                # 새 터미널이면 생략해도 됩니다

cbg job1                                       # 세션 시작
csm                                            # 대시보드 열기
```

`install.sh`는 tmux 설치를 확인하고, 스크립트에 실행 권한을 주고, launchd 데몬을 등록해 띄운 뒤, `~/.zshrc`에 셸 함수를 연결합니다.

이 문서는 예시 경로로 `~/Project/claude-autoresume`를 씁니다.
다른 위치에 두었다면 명령의 경로만 그 위치로 바꾸면 됩니다.
스크립트가 자기 위치를 스스로 찾으므로 폴더가 어디에 있든 동작합니다.

---

## 기본 명령어

```sh
cbg <창이름> [명령] [args...]   # 새 창에서 claude 실행, 두 번째부터의 인자는 그대로 전달
cba [창]                        # 접속, 인자가 없으면 창 목록에서 고름
cbls                            # 창 목록
cbpeek <창>                     # 창 아래쪽 30줄 들여다보기
cbk <창>                        # 창 하나 종료
cbkill                          # 전체 종료
csm                             # 세션 매니저 대시보드
```

```sh
cbg job1                             # 기본 claude
cbg job2 claude --continue           # 직전 대화 이어서
cbg job3 claude-work --resume        # 프로필 런처로 실행하면서 resume
```

두 번째 인자가 실제로 실행할 명령이고, 그 뒤 인자는 모두 그 명령에 그대로 넘어갑니다.
공백이 들어가면 따옴표로 감싸세요.
`claude-work` 같은 프로필 런처는 아래 `.zshrc` 설정을 참고하세요.
세션은 `cbg`를 실행한 현재 폴더에서 시작하며, 특정 폴더에서 시작하려면 먼저 `cd` 하세요.

tmux를 처음 쓴다면 세 가지만 알면 됩니다.
접속한 창에서 빠져나오려면 `Ctrl-b`를 눌렀다 떼고 `d`를 누릅니다. 세션은 죽지 않고 백그라운드에서 계속 돕니다.
창을 바꾸려면 `Ctrl-b` 다음에 숫자를 누르거나 `w`로 목록을 엽니다.
대부분은 `cbg`, `cba`, `csm`, `cbk`로 끝나서 raw tmux 명령을 쓸 일은 거의 없습니다.

---

## 세션 매니저 csm

![csm 대시보드](imgs/run.png)

위 화면이 기본 영어 UI입니다. `l` 키를 누르면 한국어로 바뀝니다.

각 행은 창 하나를 나타내며 창 이름, 프로필, 상태, 사용량 잔량, 마지막 활동 시각, 마지막 자동 재개 시각, 자동재개 제외 여부를 차례로 보여줍니다.

상태는 다섯 가지입니다.

- 작업중 — 에이전트가 실제로 응답을 만들고 있습니다. 화면에 `esc to interrupt`가 떠 있을 때만 이 상태로 봅니다. 타이핑이나 시계 갱신 같은 단순한 화면 변화는 작업중으로 치지 않습니다.
- 백그라운드 — 메인 화면은 멈춰 있지만 백그라운드 셸이나 에이전트, 워크플로가 돌고 있습니다.
- 한도대기 — 5시간 세션 한도에 걸린 상태입니다. 리셋 시각이 지나면 데몬이 이어갑니다.
- 차단 — 조직 한도나 주간 한도처럼 자동 재개가 의미 없는 경우입니다. 알림만 보내고 직접 확인해야 합니다.
- 유휴 — 정말로 멈춰서 사용자 입력을 기다립니다. 작업이 끝났거나 질문을 던진 경우입니다.

키는 다음과 같습니다.

- `a` 창을 골라서 접속
- `n` 새 세션 만들기
- `k` 세션 종료
- `p` 창별 자동재개 켜고 끄기
- `t` 상태별 알림 설정
- `l` 언어 바꾸기, en과 ko를 오가며 데몬에도 바로 반영됩니다
- `r` 새로고침, `q` 종료

인자로 새로고침 주기를 정할 수 있고(`csm 5`), `csm --once`는 한 번만 출력하고 끝냅니다.
대화형 질문에서는 `esc`를 누르면 취소하고 대시보드로 돌아옵니다.
빈 입력이 어떻게 동작하는지는 질문마다 다릅니다. 예를 들어 접속에서 빈 입력은 세션 전체에 접속합니다.
대시보드는 별도 화면에 그려지므로 터미널 스크롤에 쌓이지 않고, 끄면 원래 화면이 돌아옵니다.

새 세션의 프로필 목록은 그때그때 만들어집니다.
`config.sh`의 `NEW_SESSION_MENU`에 적어 둔 후보와, 홈에 있는 `~/.claude-*` 설정 폴더를 자동으로 찾아 함께 보여줍니다.
프로필 런처를 쓴다면 `NEW_SESSION_MENU`에 추가하면 됩니다.

---

## 한도를 감지하고 이어가는 방식

데몬은 화면 아래쪽 일부만 읽어서 한도 문구를 몇 가지로 나눕니다.

| 화면 문구 예시 | 분류 | 데몬 동작 |
|---|---|---|
| `You've used 97% of your session limit` | 예고 경고 | 무시 |
| `You've hit your session limit · resets 1:40pm` | 세션 한도, 텍스트 | 리셋 시각이 지나면 "계속 진행" 입력 |
| `Stop and wait for limit to reset` + `Enter to confirm` | 세션 한도, 선택 메뉴 | 1번을 자동으로 고른 뒤 리셋이 지나면 입력 |
| `You've hit your org's monthly spend limit ...` | 결제·주간 한도 | 입력하지 않고 알림만 |

경고 문구와 실제 한도 문구를 구분하고, 화면 아래쪽만 보기 때문에 재개 뒤 위로 밀려난 옛 문구를 잘못 읽지 않습니다.
리셋 시각을 읽어서 그 전에는 기다리고, 지나면 바로 입력합니다. 시각을 못 읽으면 잠시 뒤 다시 시도합니다.

한도에 걸렸을 때 선택 메뉴가 뜨는 경우가 있습니다.
메뉴는 글자 입력이 통하지 않으므로 방향키와 Enter로 "Stop and wait for limit to reset"을 고릅니다.
고른 뒤에도 문구가 화면에 남을 수 있어서, 확인 문구가 함께 떠 있는 열린 메뉴일 때만 고릅니다.
선택이 끝나고 리셋이 지나면 일반 텍스트 한도 흐름으로 넘어가 "계속 진행"을 입력합니다.

---

## 창별로 자동재개 켜고 끄기

특정 창만 자동재개에서 빼고 직접 다루고 싶을 때가 있습니다.
csm에서 `p`를 누르고 창 이름을 입력하면 켜지고 꺼집니다. 제외된 창은 대시보드에 표시가 붙습니다.
또는 `disabled.list` 파일에 창 이름을 한 줄에 하나씩 적어도 됩니다.

---

## 상태별 알림

창이 어떤 상태로 바뀌는 순간에 macOS 알림을 한 번 보냅니다.
기본값은 한도대기, 차단, 유휴만 켜져 있습니다. 작업중과 백그라운드는 너무 자주 바뀌어서 꺼져 있습니다.
csm에서 `t`를 누르면 바로 바뀌고, 설정은 `notify.conf`에 저장돼 데몬과 공유됩니다.
상태가 두 번 연속 그대로일 때만 알림을 보내 깜빡임을 막습니다.

---

## 설정 파일 config.sh

| 항목 | 기본 | 설명 |
|---|---|---|
| `CONTINUE_PROMPT` | 언어별 en/ko | 세션에 입력하는 "계속 진행" 문구. 언어에 따라 기본값이 정해지고 `CAR_CONTINUE_PROMPT`로 덮어쓸 수 있음 |
| `RESUME_REGEX` | … | 자동재개 대상 한도 문구 |
| `BLOCKED_NOAUTO_REGEX` | … | 입력하지 않고 알림만 보낼 문구. 주간 한도 실제 문구를 확인하면 추가 |
| `IGNORE_REGEX` | `used NN% of` | 무시할 예고성 경고 |
| `WORKING_REGEX` | `esc to interrupt` | 작업중 판단용. 생성 중에만 뜨는 문구. Claude 문구가 바뀌면 여기만 고침 |
| `BACKGROUND_REGEX` | … | 백그라운드 판단. 셸, 에이전트, 워크플로, 서브에이전트 토큰 카운터 |
| `LIMIT_MENU_OPT`, `LIMIT_MENU_ACTIVE` | `stop and wait…`, `enter to confirm…` | 열린 한도 선택 메뉴 감지 |
| `NEW_SESSION_MENU` | `("claude")` | 새 세션 메뉴 후보 |
| `USAGE_REGEX_SHORT`, `USAGE_REGEX_LONG` | `Nh N% left`, `Nd N% left` | 사용량 읽기, 커스텀 statusline 전용 |
| `NOTIFY_WORKING`, `NOTIFY_BACKGROUND` | 0, 0 | 작업중, 백그라운드로 바뀔 때 알림 |
| `NOTIFY_LIMIT`, `NOTIFY_BLOCKED`, `NOTIFY_IDLE` | 1, 1, 1 | 한도대기, 차단, 유휴로 바뀔 때 알림 |
| `INTERVAL` | 60 | 확인 주기, 초 |
| `MIN_RESEND_GAP` | 540 | 같은 창에 다시 입력하거나 다시 알리는 최소 간격, 초 |
| `RESET_BUFFER` | 30 | 리셋 시각 이후 이만큼 지나서 입력, 초 |
| `CAPTURE_LINES` | 40 | 화면 아래쪽 몇 줄을 보고 판단할지 |

값을 바꾸면 `launchctl kickstart -k gui/$(id -u)/com.claude-autoresume`로 반영합니다.

환경변수로도 몇 가지를 조정할 수 있습니다.

- `CAR_LANG` — 화면 언어입니다. `en`이 기본이고 `ko`로 바꿀 수 있습니다. 가장 쉬운 방법은 csm에서 `l` 키입니다. 우선순위는 환경변수, `lang` 파일, 기본값 en 순입니다.
- `CAR_SESSION` — 지켜볼 tmux 세션 이름입니다. 기본은 `claude`입니다.
- `CAR_LABEL` — launchd 라벨입니다. 기본은 `com.claude-autoresume`입니다.
- `CAR_CONTINUE_PROMPT` — "계속 진행" 문구를 직접 정합니다.
- `TMUX_TMPDIR` — tmux 소켓 위치입니다. 기본 `/tmp`이며 데몬과 공유하려면 그대로 두세요.

---

## 데몬 다루기

`install.sh`가 `RunAtLoad`와 `KeepAlive`로 등록하므로 데몬은 로그인할 때 자동으로 뜨고 죽으면 다시 뜹니다.

```sh
launchctl list | grep com.claude-autoresume                                   # 상태
tail -f ~/Project/claude-autoresume/autoresume.log                            # 로그
launchctl kickstart -k gui/$(id -u)/com.claude-autoresume                     # 설정 반영, 재시작
launchctl bootout   gui/$(id -u)/com.claude-autoresume                        # 끄기
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.claude-autoresume.plist  # 켜기
```

---

## 파일

- `config.sh` — 설정과 공용 헬퍼. 대부분의 조정은 여기서 합니다.
- `i18n.sh` — 화면 문자열의 언어별 표. 문구 추가나 수정은 여기서 합니다.
- `autoresume.sh` — 감시 데몬. `bash autoresume.sh --once`로 한 번만 돌려볼 수 있습니다.
- `session-manager.sh` — 대시보드 csm.
- `shell-functions.zsh` — cbg, cba, csm 같은 셸 함수.
- `install.sh`, `uninstall.sh` — 설치와 제거.
- `disabled.list` — 자동재개 제외 창 목록. 실행 중에 생기며 선택 사항입니다.
- `lang` — 화면 언어 설정. csm의 `l`로 바꾸며 실행 중에 생깁니다.
- `notify.conf` — 상태별 알림 설정. csm의 `t`로 바꾸며 실행 중에 생깁니다.
- `autoresume.log`, `state/`, `.sm/` — 로그와 상태, 캐시. 실행 중에 생깁니다.

`.gitignore`가 실행 중에 생기는 파일과 개인 흔적을 저장소에서 빼둡니다.
`state/`, `.sm/`, `disabled.list`, `lang`, `notify.conf`, 로그 파일이 대상입니다.
코드에는 사용자 이름이나 이메일, 절대 경로, 개인 프로필명이 박혀 있지 않습니다.
프로필과 경로, tmux 위치는 모두 실행할 때 스스로 찾습니다.

---

## `.zshrc` 설정

`install.sh`가 아래 한 줄을 자동으로 넣습니다. 직접 하려면 `~/.zshrc`에 추가하세요.
이 한 줄이 `cbg`, `cba`, `csm` 같은 모든 함수를 올려 줍니다.

```sh
source ~/Project/claude-autoresume/shell-functions.zsh
```

예전 방식으로 `cbg`나 `cba` 함수를 `~/.zshrc`에 직접 붙여넣은 블록이 있다면, 그 블록을 지우고 위 한 줄로 바꾸세요.

여러 계정이나 설정으로 Claude를 띄운다면 프로필별 실행 함수를 만들어 두면 편합니다.
그러면 `cbg <창> <함수명>`으로 바로 쓸 수 있고 새 세션 메뉴에도 나옵니다.

```sh
claude-work()     { CLAUDE_CUSTOM_PROFILE=WORK     command claude --dangerously-skip-permissions "$@"; }
claude-personal() { CLAUDE_CUSTOM_PROFILE=PERSONAL CLAUDE_CONFIG_DIR=~/.claude-personal command claude --dangerously-skip-permissions "$@"; }
```

위 `source` 줄과 프로필 런처는 서로 독립적입니다. 런처가 없어도 기본 `claude`로 동작합니다.
csm의 프로필 표시는 실행 중인 프로세스의 `CLAUDE_CUSTOM_PROFILE`을 읽습니다.
없으면 `CLAUDE_CONFIG_DIR` 폴더 이름을 쓰고, 그것도 없으면 default로 표시합니다.

---

## statusline 설정

대시보드의 사용량 잔량, 예를 들어 `5h 76% · 7d 8%`는 Claude 아래쪽 statusline에서 읽어온 값입니다.
기본 statusline에는 이 값이 없어서 커스텀 statusline이 필요합니다. 없으면 그냥 생략되니 안 써도 됩니다.
statusline이 `5h N% left / 7d N% left` 형식으로 출력하면 csm이 알아서 찾아 보여줍니다.
문구 형식이 다르면 `config.sh`의 `USAGE_REGEX_SHORT`와 `USAGE_REGEX_LONG`를 맞춰 주세요.

---

## 제거

```sh
bash ~/Project/claude-autoresume/uninstall.sh          # 데몬과 plist 제거
bash ~/Project/claude-autoresume/uninstall.sh --purge  # 폴더까지 삭제
```

`~/.zshrc`의 `source` 줄은 직접 지우면 됩니다.
