# CI 개선 단계와 검증 범위

> Historical snapshot: claims, dates, SHAs, counts and pending steps below apply
> only to the recorded revision. Published 6.0.2 and current release rules are
> described in the [documentation index](DOCUMENTATION.md). This record is not
> current publication status or evidence that a later revision passed.

## 1단계: 독립 job 병렬 실행과 제품 SDK build 선택

CI Plan 이후 서로의 artifact를 소비하지 않는 native jobs를 병렬 실행한다.
CI Required는 기존 모든 논리적 필수 job 결과를 계속 검사한다. lint, coverage,
테스트 실패나 취소는 최종 성공으로 바뀌지 않는다. Swift 테스트의 `--no-parallel`
및 기존 deterministic test 실행 옵션은 유지한다. release workflows는 변경하지 않는다.

docs-only 계획은 정확한 PR base/head와 Git 본문을 검증한 순수 prose diff에서만
policy/docs-required/lint/documentation을 선택하고 테스트 job을 생략한다.
전체 줄 fence로 코드 블록을 동결하여 문자열 안의 ```가 fence를 닫지 못하게 한다.
frontmatter, HTML, directive 문맥 안의 본문 수정, 변경된 code fence, 모호한 문법,
release/contract 문서 또는 증거 부재는 전체 검증으로 돌아간다. 두 aggregate는
같은 PR base/head의 Git 본문 증거를 다시 검증하며 main/release 전체 검증을 유지한다. 소스 안의 Markdown, 미분류 파일, 검증 contract, 변경된
Package.swift, 비-PR 실행은 full fallback을 유지한다.

`ci-build-products.py`는 검토한 Package.swift digest와 target dependency graph가
일치할 때, fast PR의 순수 Sources/*.swift 변경에만 SDK build scheme을 선택한다.
InnoFlowCore 변경은 모든 제품, InnoFlowMacros 변경은 이를 사용하는 InnoFlow,
SwiftUI/Testing/Inspector 변경은 해당 제품을 선택한다. 여러 변경의 영향을 합치며,
rename 양쪽 경로는 CI Plan에 이미 포함된다. scheme이 없거나 discovery가 실패하면
기존 InnoFlow-Package build를 실행한다. 실제 build 실패는 fallback으로 숨기지 않는다.

1단계 당시 선택 범위는 SDK build scheme이었다. 당시 InnoFlowTests는 InnoFlow,
Core, SwiftUI, Testing, Inspector를 함께 의존하므로 테스트 전체 target을 컴파일하고
실행했다. --filter로 실제 제품별 선택 컴파일이 되었다고 주장하지 않는다.
1단계 최초 작성 당시 실제 선택 graph와 실행시간은 미검증이었다. 후속 Mac graph
검증과 private package 측정은 아래 2단계 문서에 기록하며 hosted/전체 CI 성능과 구분한다.

metadata 이벤트는 validation과 별도 concurrency group에서 기존 증거를 기다린다.
metadata끼리는 cancel=false/queue=max를 유지한다. 기존 metadata provenance
정책이 취소된 metadata를 거부하므로 무조건적인 중복 metadata 취소는 하지 않는다.
대기는 각 job 최대21000초의 공유 deadline이며 CI aggregate job timeout은360분이다.
정확히 결합된 native validation이 진행 중인 경우만 재시도한다. PR 변경/종료,
완료된 검증 실패, 권한 오류는 즉시 실패한다. docs-required가 실패하면 후속
CI Required는 추가 대기 없이 한 번 검증하고 실패한다.

merged-pr-cleanup은 현재 read-only 후보 조회다. 정상 CI concurrency가 superseded
validation을 취소하는 동작은 유지하지만, merged PR 자동 취소는 별도 actions:write
승인 및 활성화 전까지 작동하지 않는다. release/main/manual 실행은 대상이 아니다.

## 2단계: fixture 및 테스트 target 분리

별도 후속 변경에서 기존 단일 InnoFlowTests를 Core/Testing/SwiftUI/Inspector 및
통합·authoring 계약 target으로 분리했다. test support는 실제 의존성에 따라 나누고
제품 배포 graph에서는 제외한다. 단일 Inspector/SwiftUI/Testing 소스 PR은 역의존
계약 전체를 포함하는 private package에서 실행한다. Core·공유·mixed 변경과
main/release는 full fallback을 유지한다. 실제 구조, 선택 graph, 선언 동등성 및
검증 환경은 [선택 테스트 target 문서](CI_SELECTIVE_TEST_TARGETS.md)를 참고한다.

## 검증

1단계의 로컬 Python 회귀는 제품 역의존, manifest 변경, unknown/mixed 경로,
잘못된 plan, scheme discovery 실패, 실제 build 실패 전파를 검사한다. metadata와
cleanup은 bounded wait, 정확한 PR/workflow/branch 범위, API 경합 및 부정 응답을
검사한다. CI efficiency mutation tests와 actionlint도 실행한다.

1단계 최초 작성 환경인 Linux VM에는 Swift/Xcode가 없어 Apple SDK build나 테스트를
수행하지 않았다. 이후 Mac 및 hosted 결과는 각 변경의 검증 보고에 기록한다. 로컬 mock 성공을 실제 빌드 성공이나
성능 향상 실측으로 보고하지 않는다.

Workflow linter 임시 실행 파일은 checkout 밖의 시스템 임시 폴더에 둔다.
실행 파일이 존재하는 동안 consumer가 `.github`를 copytree하는 회귀 검사를 두어
소비자 복사와 linter cleanup이 같은 저장소 경로에서 경쟁하지 않음을 확인한다.
