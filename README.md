# claude-autoresume

*(English README: [README.en.md](README.en.md))*

5시간 세션 한도로 멈춘 Claude Code 세션들을, **자는 동안 리셋될 때마다
기존 세션 그대로 자동으로 이어가게** 해주는 macOS용 도구 + 세션 매니저 대시보드.

- 각 Claude 세션을 `tmux` 세션(`claude`) 안의 개별 창에서 실행
- `launchd` 데몬이 각 창을 주기적으로 훑어, 한도 문구가 뜨면 **resets 시각 이후**
  이어가기 프롬프트(언어별, 기본 영어)를 그 창에 직접 타이핑해 제자리에서 재개
- **터미널 계층**에서 동작하므로 창마다 실행 명령·프로필이 달라도 무관
- `csm` 대시보드로 모든 세션의 상태를 실시간 확인·제어

---

## 빠른 시작

```sh
bash ~/Project/claude-autoresume/install.sh   # tmux 확인 + 데몬 등록 + 셸 함수
source ~/.zshrc                                # (새 터미널이면 자동 적용)

cbg job1                                       # 세션 시작
csm                                            # 대시보드
```

`install.sh` 가 하는 일: ① tmux 설치 확인(brew) ② 스크립트 실행권한 ③ launchd 데몬
등록·기동 ④ `~/.zshrc` 에 셸 함수 연결.

> 이 README는 예시로 `~/Project/claude-autoresume` 경로를 씁니다. **다른 곳에 클론했다면**
> 명령의 경로만 그 위치로 바꾸세요 — 스크립트는 자기 위치를 자동 인식하므로(하드코딩 없음)
> 폴더 위치와 무관하게 동작합니다.

---

## 매일 쓰는 법

```sh
cbg <창이름> [명령] [args...]   # 새 창에서 claude 실행. 2번째부터의 인자는 그대로 전달
cba [창]                        # 접속. 인자 없으면 창 목록을 보여주고 선택. 나오기: Ctrl-b 다음 d
csm                             # ★ 세션 매니저 대시보드
cbls                            # 창 목록
cbpeek <창>                     # 창 하단 30줄 엿보기(한도 문구 확인용)
cbk <창>                        # 창 하나 종료
cbkill                          # 전체 종료
```

예시:
```sh
cbg job1                             # 기본 claude
cbg job2 claude --continue           # 직전 대화 이어서
cbg job3 claude-work --resume        # 프로필 런처(claude-work)로 실행 + resume
```
> 2번째 인자 = 실행할 명령. 그 뒤 인자는 전부 그 명령에 그대로 넘어감(공백 있으면 따옴표).
> `claude-work` 같은 프로필 런처는 아래 (선택) `.zshrc` 설정 참고.
> 작업 디렉토리는 `cbg` 실행한 현재 폴더. 특정 폴더면 먼저 `cd`.

### tmux 최소 지식
- **나오기(detach)**: `Ctrl-b` 눌렀다 떼고 `d` — 세션은 안 죽고 계속 백그라운드 실행
- **창 전환**: `Ctrl-b` 다음 숫자 / `w`(목록)
- 대부분은 `cbg`/`cba`/`csm`/`cbk` 로 처리되니 raw tmux 명령은 거의 필요 없음

---

## 세션 매니저 (csm)

![csm 대시보드](imgs/run.png)

```
 ⌘ Claude 세션 매니저   16:09:40   ● 자동재개 ON
  [a]접속 [n]새세션 [k]종료 [p]자동재개토글 [t]알림 [l]언어 [r]새로고침 [q]종료 · 새로고침 10s

  job1            PERSONAL  🟢 작업중    · 활동 2s 전 · 5h 76% · 7d 8%
  job2            WORK      🟡 한도대기  · resets 3:30pm (12분 남음)  · 활동 5m 전
  job3            BOTH      🔵 백그라운드 · 활동 8m 전  ⏸제외

  세션 3개  ·  🟢 작업중 1  🔵 백그라운드 1  🟡 한도대기 1  ⛔ 차단 0  ⚪ 유휴 0
```
> 기본 UI 언어는 **영어**입니다. 위는 `l` 키로 한국어(ko)로 전환한 화면 예시입니다.

**상태** (행·요약 워딩 동일)
- 🟢 작업중 — **에이전트가 실제로 생성 중**(화면에 `esc to interrupt` 표시). 프롬프트
  타이핑·`/status`·시계 갱신 같은 단순 화면 변화로는 작업중으로 안 침.
- 🔵 백그라운드 — 메인 화면은 정지지만 백그라운드 shell/agent/workflow 진행 중
- 🟡 한도대기 — 5h 세션 한도. resets 시각 지나면 데몬이 이어감 (+남은 시간 표시)
- ⛔ 차단 — 조직/주간 한도 등. 자동재개 무의미 → 알림만, 수동 확인 필요
- ⚪ 유휴 — 진짜로 멈춰서 사용자 입력 대기(완료 또는 질문 대기)

**컬럼**: 창이름 · 프로필 · 상태 · 사용량 잔량 · 활동시각 · 자동주입 이력 · `⏸제외`(자동재개 off)

**키**: `a` 접속(창 선택) · `n` 새 세션 · `k` 세션 종료 · `p` 창별 자동재개 토글 ·
`t` **상태별 알림 설정** · `l` **언어 토글(en↔ko, 데몬까지 즉시 반영)** · `r` 새로고침 ·
`q` 종료 · 인자로 주기 지정(`csm 5`), `csm --once`는 1회 출력.
모든 대화형 프롬프트는 **`esc`(또는 빈 입력) 로 취소**하고 대시보드로 돌아옵니다.
대시보드는 **대체 화면 버퍼**로 그려져 스크롤백에 쌓이지 않습니다(종료 시 원래 화면 복원).

**새 세션 [n] 의 프로필 메뉴**는 동적입니다: `config.sh` 의 `NEW_SESSION_MENU`
(기본 `claude` 하나) + 홈의 `~/.claude-*` 설정 디렉토리를 자동 탐지해 후보로 보여줍니다.
프로필 런처(셸 함수)를 쓰면 `NEW_SESSION_MENU` 에 추가하면 됩니다.

---

## 자동재개 원리 (한도 문구 분류)

| 화면 문구(예) | 분류 | 데몬 동작 |
|---|---|---|
| `You've used 97% of your session limit` | 예고 경고 | **무시** |
| `You've hit your session limit · resets 1:40pm` | 5h 세션 한도(텍스트) | resets 시각 지나면 **이어가기 주입** |
| 한도 선택 메뉴(`Stop and wait for limit to reset` + `Enter to confirm`) | 5h 세션 한도(메뉴) | **1번 "Stop and wait" 자동 선택** → 이후 리셋 지나면 주입 |
| `You've hit your org's monthly spend limit ...` | 결제/주간 한도 | **주입 안 함 + 알림** |

- `used NN%`(경고) vs `hit ... limit`(차단) 을 구분. 화면 **하단 일부만** 보므로
  재개 후 위로 밀려난 옛 문구는 오판하지 않음.
- resets 시각을 파싱해 **그 시각 전엔 대기**, 지나면 즉시 주입(파싱 실패 시 폴백 재시도).
- **선택 메뉴**는 텍스트 주입이 안 먹으므로 방향키+Enter로 "Stop and wait for limit to
  reset"(1번)을 자동 선택합니다. '선택 후에도 문구가 남을 수 있어' 확정 프롬프트
  (`Enter to confirm`)가 함께 있는 **활성 메뉴일 때만** 선택하고, 선택 뒤 리셋이 지나면
  일반 텍스트 한도 경로로 넘어가 이어가기 주입이 진행됩니다.

---

## 창별 자동재개 on/off (기본 ON)

특정 창만 자동재개에서 빼고 싶을 때 (수동으로 관리):
- csm 에서 `p` → 창 이름 입력 → 토글. 제외된 창은 `⏸제외` 로 표시.
- 또는 `disabled.list` 파일에 창 이름을 한 줄씩 적어도 됨.

---

## 설정 (`config.sh`)

| 항목 | 기본 | 설명 |
|---|---|---|
| `CONTINUE_PROMPT` | i18n(en/ko) | 세션에 주입되는 이어가기 문구. `CAR_LANG` 따라 기본값 결정, `CAR_CONTINUE_PROMPT` 로 재정의 |
| `RESUME_REGEX` | … | (A) 자동재개 대상 한도 문구 |
| `BLOCKED_NOAUTO_REGEX` | … | (B) 주입 안 함(알림만) 문구. **주간 한도 실제 문구 확인 시 추가** |
| `IGNORE_REGEX` | `used NN% of` | 무시할 예고성 경고 |
| `WORKING_REGEX` | `esc to interrupt` | 🟢 작업중 판정용(생성 중에만 뜨는 문구). Claude 문구 바뀌면 여기만 수정 |
| `BACKGROUND_REGEX` | … | 🔵 백그라운드(shell/agent/workflow/서브에이전트 토큰카운터) 판정 |
| `LIMIT_MENU_OPT` / `LIMIT_MENU_ACTIVE` | `stop and wait…` / `enter to confirm…` | 한도 선택 메뉴(활성) 감지 |
| `NEW_SESSION_MENU` | `("claude")` | csm [n] 새 세션 메뉴 후보(프로필 런처 추가 가능) |
| `USAGE_REGEX_SHORT/LONG` | `Nh N% left` / `Nd N% left` | 사용량 파싱(커스텀 statusline 전용) |
| `NOTIFY_WORKING` / `_BACKGROUND` | 0 / 0 | → 🟢작업중 / 🔵백그라운드 전환 시 알림 |
| `NOTIFY_LIMIT` / `_BLOCKED` / `_IDLE` | 1 / 1 / 1 | → 🟡한도대기 / ⛔차단 / ⚪유휴 전환 시 알림 |
| `INTERVAL` | 60 | 감시 주기(초) |
| `MIN_RESEND_GAP` | 540 | 재주입/재알림 최소 간격(초) |
| `RESET_BUFFER` | 30 | resets 시각 + 여유(초) 뒤 주입 |
| `CAPTURE_LINES` | 15 | 화면 하단 몇 줄 보고 판단 |

바꾼 뒤 반영: `launchctl kickstart -k gui/$(id -u)/com.claude-autoresume`

### 상태별 알림 (csm `t`)
창이 각 상태로 **바뀔 때** 한 번 macOS 알림. `NOTIFY_*` 기본은 🟡한도대기·⛔차단·⚪유휴만
켜져 있고 🟢작업중·🔵백그라운드는 잦아서 꺼져 있습니다. **csm 에서 `t`** 로 즉시 토글하면
`notify.conf` 에 저장돼 데몬과 공유됩니다(전이가 2회 연속 안정되면 알림 → 깜빡임 방지).

### 환경변수 (선택)
- `CAR_LANG` — UI 언어: `en`(기본) 또는 `ko`. 대시보드·프롬프트·알림·로그·주입문구에 적용.
  가장 쉬운 방법은 **csm 에서 `l` 키**(즉시 토글, `lang` 파일에 저장돼 데몬도 공유).
  우선순위: 환경변수 `CAR_LANG` > `lang` 파일 > `en`. (셸에 `export CAR_LANG` 하면 그게 우선)
- `CAR_SESSION` — 감시할 tmux 세션 이름(기본 `claude`)
- `CAR_LABEL` — launchd 라벨(기본 `com.claude-autoresume`)
- `CAR_CONTINUE_PROMPT` — 이어가기 문구
- `TMUX_TMPDIR` — tmux 소켓 위치(기본 `/tmp`, 데몬과 공유하려면 그대로 두세요)

---

## 데몬 제어

```sh
launchctl list | grep com.claude-autoresume                                   # 상태
tail -f ~/Project/claude-autoresume/autoresume.log                            # 로그
launchctl kickstart -k gui/$(id -u)/com.claude-autoresume                     # 설정 반영(재시작)
launchctl bootout   gui/$(id -u)/com.claude-autoresume                        # 끄기
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.claude-autoresume.plist  # 켜기
```

---

## 파일

- `config.sh` — 설정 + 공용 헬퍼(판정/파싱). **여기만 고치면 됨**
- `i18n.sh` — UI 문자열 다국어 테이블(en/ko). 문구 추가/수정은 여기
- `autoresume.sh` — 감시 데몬 (`bash autoresume.sh --once` 로 1회 테스트)
- `session-manager.sh` — 대시보드(csm)
- `shell-functions.zsh` — cbg/cba/csm 등 셸 함수
- `install.sh` / `uninstall.sh` — 설치/제거
- `disabled.list` — 자동재개 제외 창 목록(런타임·선택)
- `lang` — UI 언어 설정(csm `l` 로 토글, 런타임)
- `notify.conf` — 상태별 알림 on/off(csm `t` 로 토글, 런타임)
- `autoresume.log`, `state/`, `.sm/` — 로그·상태·캐시(런타임)

> **공개 저장소 안전성**: `.gitignore` 가 런타임/개인 흔적을 제외합니다 —
> `state/`, `.sm/`(pane pid·프로필 캐시), `disabled.list`(창 이름), `lang`(언어 설정),
> `notify.conf`(알림 설정), `*.log`(창 이름·활동). 코드에는 사용자·이메일·절대경로·개인
> 프로필명이 하드코딩돼 있지 않습니다(프로필/경로/tmux 위치 모두 런타임에 동적으로 탐지).

---

## (선택) `.zshrc` 설정

**셸 함수 연결** — `install.sh` 가 자동으로 아래 한 줄을 넣습니다. 수동으로 하려면
`~/.zshrc` 에 추가하세요. 이 한 줄이 `cbg`/`cba`(창 선택기)/`csm`(`l` 언어 토글) 등
모든 함수를 제공합니다:
```sh
source ~/Project/claude-autoresume/shell-functions.zsh
```
> 예전 버전처럼 `~/.zshrc` 에 `cbg`/`cba`/… 함수를 **직접 붙여넣은 블록**이 있다면,
> 그 블록을 지우고 위 `source` 한 줄로 바꾸세요(경로 하드코딩 없고 최신 기능 반영).

**프로필 런처(선택)** — 여러 계정/설정으로 Claude 를 띄운다면, 프로필별 실행 함수를
정의해두면 `cbg <창> <함수명>` 으로 바로 쓸 수 있고 `[n]` 메뉴에도 활용됩니다(예시):
```sh
claude-work()     { CLAUDE_CUSTOM_PROFILE=WORK     command claude --dangerously-skip-permissions "$@"; }
claude-personal() { CLAUDE_CUSTOM_PROFILE=PERSONAL CLAUDE_CONFIG_DIR=~/.claude-personal command claude --dangerously-skip-permissions "$@"; }
```
> 위 `source` 줄과 프로필 런처는 **서로 독립**입니다(런처 없이도 기본 `claude` 로 동작).
> csm 의 프로필 표시는 실행 프로세스의 `CLAUDE_CUSTOM_PROFILE`, 없으면
> `CLAUDE_CONFIG_DIR` 폴더명(예: `.claude-personal`→`personal`), 그것도 없으면 `default`.

## (선택) statusline 설정 — 사용량 잔량 표시용

csm 의 "5h 76% · 7d 8%" 같은 **사용량 잔량**은 Claude 하단 statusline 을 파싱합니다.
**기본 statusline엔 없고, 커스텀 statusline이 필요**합니다. 없으면 그냥 생략되니
안 써도 무방합니다. 커스텀 statusline이 `5h N% left / 7d N% left` 형식의 문자열을
출력하도록 하면(예: `/statusline` 설정, /rc 플러그인 등), csm이 자동으로 잡아 표시합니다.
문구 형식이 다르면 `config.sh` 의 `USAGE_REGEX_SHORT/LONG` 를 맞춰 주세요.

---

## ★ 주간 한도 문구 튜닝

개인 주간 한도 실제 문구는 확인되면 `config.sh` 의 `BLOCKED_NOAUTO_REGEX` 에
핵심어를 추가하세요(현재는 `weekly limit|7-day limit` 로 추정). 확인 방법:
```sh
cbpeek <창>   # 실제 한도 메시지 확인 → config.sh 반영 → kickstart -k 로 재시작
```

## 제거

```sh
bash ~/Project/claude-autoresume/uninstall.sh          # 데몬/plist 제거
bash ~/Project/claude-autoresume/uninstall.sh --purge  # 폴더까지 삭제
# + ~/.zshrc 의 source 줄 삭제
```
