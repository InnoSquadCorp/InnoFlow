---
status: Draft
reviewed-by: []
approved-by: null
approved-at: null
---

# Multiplatform hosted 검증 — 2026-10-18

실행 상태: **커밋/푸시 및 원격 검증 진행 중**. 문서 상태는 Draft이며 출시 승인이 아니다.

## 기준선·권한·고정 범위

- 사용자가 현재 수정본의 commit/push 및 API23/35·원격 CI 검증을 승인했다.
  배포는 명시적으로 금지했다. tag, GitHub Release, npm/GitHub Packages publish,
  main 병합/직접 push, 외부 메시지/PR 생성은 이번 실행에 포함하지 않는다.
- 대상: `codex/multiplatform-flow`, 시작 HEAD 및 origin/main
  `0a7e685d3749b3dc28c6d5e56b932c9ad7fc0b11` + 이전 검증한 미커밋 입력.
- 시작 입력 823개 / dirty165개, manifest SHA-256
  `c90f1a39c348253cfc4085d4c7618bc3ec1c03e5d1eec0d884ebeed1c7b7cb12`.
  이전 종료 snapshot과 바이트 동일하고, 이전 128개 candidate manifest도 통과했다.
- raw evidence: `/tmp/innoflow-hosted-20261018.CTW177i3`.
- Swift source/tests/examples/manifests/locks/CI와 원래 dirty Swift checkout은 그대로 보존한다.
- GitHub `Ethan-IS` 활성 계정, InnoSquadCorp 소속 및 저장소 ADMIN 권한을 확인했다.
- 이번 추가는 작업 브랜치 push trigger와 test/log artifact 수집이다. runtime/ABI/lock의
  이전 검증 바이트를 유지한다. 실패가 생기면 product/fixture/toolchain/CI infra를 구분한다.
- staged 공백 검사에서 원본 XML의 CRLF·생성 ABI/원문 LICENSE 끝 구분 줄은 바이트를
  바꾸지 않고 좁은 .gitattributes 규칙으로 취급한다. release-kotlin YAML의 여분 EOF만 정리했다.
- 추가 포장 결함 P05-L: 3개 npm LICENSE에 잘못된 제목 접두어와 누락된 원문 구절이 있었다.
  root LICENSE는 무변경으로 유지하고 package 복사본을 정확히 일치시켰으며, 실제 package
  validator에 원문 equality assertion을 추가했다. 수정 전 새 검사는 의도대로 실패했다.

## 원격 종료 조건

1. exact staged 경로를 점검해 commit하고 현재 작업 브랜치만 non-force push한다.
   local HEAD / origin branch / remote ref SHA 일치 및 worktree 상태를 확인한다.
2. 성공 push마다 parity/worktree 확인 **후** 지정 XcodeBuildMCP cleanup을 실행한다.
   active build/compiler를 종료하지 않으며, 정리량/남은 디스크 또는 skip 이유를 남긴다.
3. 그 정확한 SHA·branch·push event·workflow 경로의 Multiplatform CI run을 찾아
   6개 job 모두 success/실행을 확인한다. 단순 overall green이나 다른 SHA를 대체하지 않는다.
4. Kotlin unit/consumer XML에서 필수 module/sample28 + 외부 JVM/AAR2 검사를 확인하고
   ABI5, lint/debug/release build, KSP positive11/negative5 및 AAR negative2를 로그와 대조한다.
5. Node20.19/22 각각 test28/5files, 실제 React18/19 tarball 소비자와 분리된 SSR/live mutant
   거부를 확인한다. log/screenshot을 내려받아 검증하고 skipped/0-test를 PASS로 세지 않는다.
6. API23 및35 실제 emulator SDK를 확인하고 각각 Compose2 + recreation1의 XML,
   real process death의 다른 PID, 정확한 Count2, 저장된 STOPPED Activity, screenshot/XML,
   crash buffer를 검토한다. instrumentation 성공으로 process restoration을 대신하지 않는다.
7. 원격 artifact와 로그의 identity/해시, 최종 local/remote parity, Swift/main diff,
   이전 evidence 보존을 문서/JSON으로 남긴다. 증거만 후속 commit할 경우 runtime 입력이
   동일함을 증명하되, 새 HEAD의 CI 결과를 이전 SHA 결과로 가장하지 않는다.

## 기존 63행과의 연결

- [수정 후 로컬 원장](MULTIPLATFORM_FIX_VERIFICATION_2026_10_18.md)과 sidecar는
  당시 immutable 입력/관측으로 보존한다. 새 workflow 바이트는 별도 hosted manifest로 식별한다.
- A06: 이번 실제 API23/35 실행으로 재개방한다.
- C06: exact-SHA hosted **작업 브랜치** CI를 확인한다. release helper가 요구하는
  **main-push** eligibility는 main 병합·해당 SHA main CI 전까지 별개로 미충족이다.
  branch run을 main release evidence로 위장하거나 helper 조건을 완화하지 않는다.
- C07: registry-only install/publication/출시 승인은 명시적 배포 금지로 미수행한다.
- X01/X02: Swift runtime/release, physical device/다른 engine/RN/soak·심층 보안은 이전 제외다.

## 실행 원장

### 최초 hosted 실행 — 실패 보존

- commit `f4016461031468a7ebc372a47d256aa8e95bb2e0`, push event, 작업 브랜치,
  [run 39108493753](https://github.com/InnoSquadCorp/InnoFlow/actions/runs/39108493753).
- 계약, Kotlin/JVM/AAR/KSP, Node20.19.0/22.23.3, API35 job은 success다.
  API23 job은 failure이며 원래 결과를 재시도 성공으로 덮지 않는다.
- API23 Compose2 + sample recreation1은 통과했고, 정식 probe가 initial UI XML을
  가져오지 못해 process kill 이전에 실패했다. 실패 screenshot은 정상 Count0이며
  해당 실행으로 process restoration을 PASS 판정하지 않는다. raw UI 출력은 최초
  helper에 보존되지 않았으므로 tty/file/idle의 세부 원인을 아직 단정하지 않는다.
- API35는 PID `4638 → 4811`, 정확한 Count2를 am-kill 뒤 복원했다.
- Node20/22 각각 unit28/5files, 네 React18/19 소비자와 두 분리 mutant 거부를
  artifact log로 확인했다. 다운로드한 ZIP SHA-256이 GitHub digest와 일치했다.
- 첫 push 뒤 local/tracking/remote SHA 동일, diverged `0 0`, worktree clean,
  Swift/main diff0을 확인한 뒤 cleanup을 실행했다. 251개 지정 디렉터리에서
  회수0 KiB, free73 GiB였으며 다른 build/compiler를 중단하지 않았다.

### UI 수집 portability 보완 — 다음 후보에서 재검증

- tty raw 출력을 저장하고 XML이 없으면 별도 고유 temp XML 파일을 사용한다.
  매번 dump 전/후 자신의 temp 파일만 지워 stale XML을 수락하지 않는다.
  dump의 error/성공 출력, 실제 파일 XML을 보존하고 실패는 그대로 실패한다.
- exact Count/STOPPED/saved state/UID/PID/새 PID assertion은 약화하지 않았다.
  정상 tty, legacy-file 성공, dump 실패/stale 거부, missing/invalid XML을 추가해
  20개 안전/UI-capture selftests가 통과했다. 실제 API23 성공은 아직 별도 증거가 필요하다.
- 파일 기반 dump 계약과 idle/null-root 실패 경로는
  [AOSP DumpCommand](https://android.googlesource.com/platform/frameworks/uiautomator/+/17fac436d78f6ac642386a245fb4fdb7243a91a4/cmds/uiautomator/src/com/android/commands/uiautomator/DumpCommand.java)를 대조했다.
  이 소스 대조가 현재 API23 실패의 세부 원인을 확정하거나 실제 device 결과를 대신하지 않는다.

다음 candidate SHA와 exact-SHA run, artifact/새 PID 결과는 실행 후 추가한다.
