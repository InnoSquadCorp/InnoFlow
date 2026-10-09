# CI 개선 단계와 검증 범위

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

이 선택은 SDK build scheme 선택이다. 기존 InnoFlowTests는 InnoFlow, Core,
SwiftUI, Testing, Inspector를 함께 의존하므로 테스트는 여전히 전체 target을
컴파일하고 실행한다. --filter로 실제 제품별 선택 컴파일이 되었다고 주장하지 않는다.
Xcode의 실제 선택 graph와 실행시간 감소는 hosted 실행 전에는 확인된 결과가 아니다.

metadata 이벤트는 validation과 별도 concurrency group에서 기존 증거를 기다린다.
metadata끼리는 cancel=false/queue=max를 유지한다. 기존 metadata provenance
정책이 취소된 metadata를 거부하므로 무조건적인 중복 metadata 취소는 하지 않는다.
대기는 각 job 최대21000초의 공유 deadline이며 CI aggregate job timeout은360분이다.
정확히 결합된 native validation이 진행 중인 경우만 재시도한다. PR 변경/종료,
완료된 검증 실패, 권한 오류는 즉시 실패한다. docs-required가 실패하면 후속
CI Required는 추가 대기 없이 한 번 검증하고 실패한다.

merged-pr-cleanup은 신뢰할 수 있는 default branch의 전용 job에만 actions:write를
부여하고 --apply/CLEANUP_ENABLE_WRITES=enabled로 활성화한다. 이 workflow 변경이
merge된 뒤 발생하는 merged PR closed 이벤트부터 적용되며 저장소 설정 변경은 없다.
ci.yml의 queued/in_progress pull_request 실행 중 authoritative merged head, head branch,
native PR 연결과 API workflow ID가 모두 일치한 후보만 취소 직전에 다시 확인한다.
이전 head, main/default/release branch, manual 실행, 다른 PR/workflow, 완료된 실행과
merge 이후 의도적 rerun은 보존한다. 재개방, SHA/identity 불일치, API 오류 및 불완전한
조회에서는 취소하지 않는다. CLI 기본값은 dry-run이며 GitHub GET/POST는 원자적이지
않으므로 마지막 조회와 취소 사이의 경쟁 가능성은 남는다. 정상 CI concurrency의
superseded validation 취소는 유지한다.

## 2단계: fixture 및 테스트 target 분리 (이번 변경으로 완료되지 않음)

1. InnoFlowTests의 파일별 imports와 공유 declaration 사용을 조사한다. 단순 import
   분류만으로 target을 나누지 않는다. TestFixtures.swift 자체가 authoring macro,
   SwiftUI, Testing을 함께 import하고 TestSupport.swift도 Testing에 의존한다.
2. 먼저 StoreSwiftUIBindingTests처럼 자체 feature fixture만 사용하는 테스트를
   분리할 수 있다. Preview 테스트는 ManualTestClock, InstrumentationProbe,
   waitUntil/waitUntilAsync 의존을 함께 분리해야 한다. Scope/Presentation 테스트의
   integration 경계는 유지한다.
3. 각 새 test target은 실제 사용하는 최소 products만 의존하도록 선언한다.
   cross-product 통합 target을 별도로 유지하고, Core 또는 공유 fixture 변경은
   reverse dependency closure에 따라 전체 관련 target을 선택한다.
4. root `swift test --filter`는 충분하지 않다. 선택하지 않은 test target/product가
   build graph에서 제외되는 별도 CI package/명시적 test-product 경로를 구현하고
   실제 SwiftPM build graph/컴파일 로그로 확인해야 한다. 지원되지 않거나 미분류면
   full fallback한다. 새 Package.swift 경로가 배포 package graph를 바꾸지 않게 한다.
5. target/경로 변경에 따른 swift-test inventory, coverage inventory, 선언별 test ID,
   runtime filter를 실제 parser/toolchain으로 갱신·대조한다. 기존 테스트를 누락하거나
   minimum count를 낮춰 통과시키지 않는다. 이 작업은 릴리스 검증 contract에 영향을
   주므로 별도 diff와 검토가 필요하다.
6. hosted Swift6.3/6.4에서 Debug/Release 전체 suite 및 분리 suite의 test inventory
   동등성을 검증하고, SwiftUI-only/Testing-only/Core/mixed 변경 각각의 선택·역의존
   graph를 확인한다. 타깃이 제외됐다는 실제 compile evidence가 있어야 선택 테스트
   컴파일 완료로 보고한다. release gates는 기존 전체 범위를 유지한다.

## 검증

1단계의 로컬 Python 회귀는 제품 역의존, manifest 변경, unknown/mixed 경로,
잘못된 plan, scheme discovery 실패, 실제 build 실패 전파를 검사한다. metadata와
cleanup은 bounded wait, 정확한 PR/workflow/branch 범위, API 경합 및 부정 응답을
검사한다. CI efficiency mutation tests와 actionlint도 실행한다.

이 Linux VM에는 Swift/Xcode가 없어 실제 Apple SDK build나 테스트는 수행하지
않았다. PR의 hosted CI가 그 검증을 담당한다. 로컬 mock 성공을 실제 빌드 성공이나
성능 향상 실측으로 보고하지 않는다.

Workflow linter 임시 실행 파일은 checkout 밖의 시스템 임시 폴더에 둔다.
실행 파일이 존재하는 동안 consumer가 `.github`를 copytree하는 회귀 검사를 두어
소비자 복사와 linter cleanup이 같은 저장소 경로에서 경쟁하지 않음을 확인한다.
