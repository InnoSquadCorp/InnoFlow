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

아직 완료되지 않았다. candidate SHA, run/attempt/job IDs, 실제 실행 수, 실패 이력,
artifact identity, push cleanup, 남은 release gate를 실행 결과와 함께 기록한다.
