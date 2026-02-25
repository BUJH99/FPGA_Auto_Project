# SystemVerilog 광범위 지원 전환 중간 점검 (2026-02-24)

## 1. 목적 / 현재 판단
- 목표: 기존 Verilog 중심 자동화 툴킷을 `.sv/.svh`까지 광범위하게 지원
- 현재 상태: `핵심 사용 경로(시뮬/리포트/FSM/계층/생성기)`는 상당 부분 반영 완료
- 남은 큰 축: `AST 기반 완전파싱 활성화(환경 준비 필요)` + `일부 도구의 비대화식/인덱서 심화 연동`

요약 판단:
- 실사용 관점: 이미 `SV 프로젝트로 기본 사용 가능`
- 완성도 관점: `고급 SV + 파서 정확도`는 AST 환경 세팅 후 추가 검증 필요

---

## 2. 이번까지 완료된 주요 변경 사항 (영역별)

## 2.1 시뮬레이션 경로 (Vivado / Icarus)

### 완료
- `.sv` TB 선택 지원 확장
- `sim_config.json`에 TB 파일/확장자/언어 정보 추가
- TB 파일명과 TB 모듈명이 달라도 Icarus top 지정 가능하도록 개선
- include/header(`.svh`) 경로를 Vivado/Icarus 경로 생성 로직에 반영

### 변경 파일
- `templates/bat/sim_iverilog_vcd_run.bat`
- `templates/bat/sim_report_auto_run.bat`
- `templates/tools/parse_tb.js`
- `templates/tools/generate_report.js`
- `templates/tcl/run_vivado_simulation.tcl`

### 핵심 효과
- `tb_test1.sv` 같은 케이스에서 파일명 기준(`tb_test1`)이 아니라 실제 TB 모듈명(`tb_adder_sv`)을 top으로 잡음
- 실패 원인이 스크립트 문제가 아니라 시뮬레이터 문법 지원 한계인지 분리해서 볼 수 있게 됨

---

## 2.2 공통 HDL 인덱서 (`hdl_indexer`)

### 완료
- 공통 HDL 인덱서 도입 (`.v/.sv/.svh` 수집/분류)
- 선언 인덱싱: `module`, `package`, `interface`, `program`
- include 수집, include dir 추론
- 파일별 SV feature 힌트 수집 (`always_ff`, `typedef enum`, `logic`, `modport` 등)
- 간단 인스턴스 그래프 생성
- `output/cache/hdl_index.json` 생성 가능

### 변경/추가 파일
- `templates/tools/hdl_indexer.js` (신규)

### AST 관련 현재 동작
- AST provider (`tree-sitter-verilog`)가 설치되어 있으면 사용
- 미설치 시 휴리스틱/정규식 기반으로 fallback + 경고 기록

### strict 모드 강화 (이번 라운드)
- `--strict` 사용 시 아래도 실패 처리:
- `ast_provider_missing`
- `ast_parse_failed`
- `ast_syntax_error`

즉, 이제 `strict = 진짜 AST 기반 검증` 의미가 더 명확함

---

## 2.3 계층 / FSM / 도식화 경로

### 완료
- `.v` 고정 스캔 제거 (또는 완화), `.sv` 포함
- 계층 print/browse가 `hdl_indexer` 우선 사용
- `package/interface`를 별도 섹션으로 표시
- FSM 파서에서 `always_ff`, `always_latch` 패턴 인식 보강
- schematic job 입력 수집에서 `.sv`/include 경로 처리 강화

### 변경 파일
- `templates/bat/code_verilog_hierarchy_print.bat`
- `templates/bat/code_verilog_hierarchy_browse.bat`
- `templates/bat/code_fsm_draw.bat`
- `templates/bat/code_schematic_draw.bat`
- `templates/tools/generate_fsm_from_verilog.js`
- `templates/tools/run_schematic_jobs.ps1`

### 추가 개선 (이번 라운드 이전 포함)
- `code_verilog_hierarchy_browse.bat`에 `--once` 비대화식 테스트 모드 추가

---

## 2.4 리포트 / 프레젠테이션 경로

### 완료
- `report_markdown_generate` 경로에서 `.sv` src/tb 반영
- `generate_one_source_report.js`가 `hdl_index.json` 캐시 생성
- `code_presentation_generate.bat` 실행 전 인덱스 캐시 생성 연결
- `generate_presentation.py`가 `hdl_index.json` 읽어 요약/선언정보를 프레젠테이션 config에 포함

### 이번 라운드 추가 완료
- `generate_presentation.py --non-interactive` 추가
  - 프롬프트 없이 기본값으로 끝까지 생성 가능
  - unmatched TB는 경고 후 스킵
- `report_markdown_generate.bat`의 배치 출력 문자열 버그 수정
  - `echo` 내 `&` 미이스케이프 문제 해결

### 변경 파일
- `templates/tools/generate_one_source_report.js`
- `templates/bat/code_presentation_generate.bat`
- `templates/tools/generate_presentation.py`
- `templates/bat/report_markdown_generate.bat`

---

## 2.5 생성기 / 프로젝트 초기화 (`setup`, module/TB 템플릿)

### 완료
- `setup_project.bat --hdl-ext v|sv`
- `code_verilog_module_generate.bat --hdl-ext v|sv`
- `sim_tb_template_create.bat --tb-ext v|sv`
- `.sv` 생성 시 `logic` 기반 템플릿 지원
- `.sv` 모듈 생성기 출력 품질 개선:
  - `input/output logic`
  - `always_ff`, `always_comb`
  - `[MODULE_INFO_*]` 헤더 유지
- TB 생성기 reset/clock 매핑 버그 수정 (`iRst` / `iRstn`)
- TB 생성기 `@WAVE` 중복 제거

### 변경 파일
- `templates/bat/setup_project.bat`
- `templates/bat/code_verilog_module_generate.bat`
- `templates/bat/sim_tb_template_create.bat`

---

## 2.6 문서 / UX 텍스트

### 완료
- README에 `.sv/.svh` 정책 반영
- 지원 매트릭스 문서 추가
- 메뉴 일부 명칭 개선 (`HDL Hierarchy`)
- Icarus 고급 SV 한계와 AST 설치 전제 문서화

### 변경/추가 파일
- `ReadMe.md`
- `MAIN.bat`
- `templates/docs/systemverilog_support_matrix.md` (신규)

---

## 3. 실제 검증 결과 (중요)

## 3.1 테스트 프로젝트 / 샘플

### 사용자 확인용 프로젝트
- `SV_DEMO_CHECK`
  - `setup_project.bat ... --hdl-ext sv`로 생성
  - 기본 예제 `.sv` 생성 확인
  - 추가 SV FSM 예제(`fsm_demo.sv`, `tb_fsm_demo.sv`) 삽입 후 테스트 수행

### 회귀/샘플 프로젝트
- `templates/examples/sv_regression_project`
  - `package`, `interface`, `.svh`, 혼합 언어 케이스 검증용

### 내부 생성기 검증 프로젝트 (테스트용)
- `SV_REMAIN_CHECK`
- `SV_REMAIN_GEN2`

---

## 3.2 통과한 테스트 (PASS)

### A. Icarus 시뮬레이션 (SV FSM 데모)
- 명령: `templates\bat\sim_iverilog_vcd_run.bat SV_DEMO_CHECK --tb tb_fsm_demo --no-pause`
- 결과: `PASS`
- 확인 포인트:
  - `.sv` TB 선택/실행 가능
  - `logic`, `always_ff/always_comb`, `typedef enum logic` 포함 DUT/TB 처리됨

### B. Icarus top 모듈 추론 개선 검증
- 명령: `templates\bat\sim_iverilog_vcd_run.bat SV_DEMO_CHECK --tb tb_test1 --no-pause`
- 결과: `Compile FAIL (의도된 원인 분리)`
- 확인 포인트:
  - 로그에 `top=tb_adder_sv` 표시 (파일명 아님, 실제 TB 모듈명 추론 성공)
  - 실패 원인: Icarus의 `class/mailbox` 문법 미지원

### C. FSM Draw (SV 문법)
- 대상: `SV_DEMO_CHECK/src/fsm_demo.sv`
- 결과: 성공
- 생성 산출물:
  - `SV_DEMO_CHECK/output/fsm/svg/fsm_demo_fsm.svg`
  - `SV_DEMO_CHECK/output/fsm/drawio/fsm_demo_fsm.drawio`

### D. HDL 정보 어노테이션
- 명령: `templates\bat\report_hdl_info_annotate.bat SV_DEMO_CHECK --no-pause`
- 결과: 성공
- 확인 포인트:
  - `.sv` src/tb 파일 인식
  - `tb_test1.sv -> tb_adder_sv / target:adder` 식으로 TB 모듈명/타깃 인식

### E. Markdown 리포트 생성
- 명령: `templates\bat\report_markdown_generate.bat SV_DEMO_CHECK --no-pause`
- 결과: 성공
- 생성 산출물:
  - `SV_DEMO_CHECK/output/docs/report.md`
  - `SV_DEMO_CHECK/output/docs/github.css`
- 추가 확인:
  - waveform 폴더 준비 정상
  - 배치 마지막 출력 문자열 오류(`Design not recognized`) 제거됨

### F. 계층 도구 (인덱서 기반)
- 대상: `templates/examples/sv_regression_project`
- 결과: 성공
- 확인 포인트:
  - `Project Hierarchy (AST/Indexer)` 경로 사용
  - `Packages`, `Interfaces` 섹션 출력

### G. 프레젠테이션 생성 (비대화식)
- 명령(파이썬 직접):
- `py -3 templates\tools\generate_presentation.py --project SV_DEMO_CHECK --template templates\Presentation\Presentation_template1.html --top adder --top-testbench-pages 0 --non-interactive`
- 결과: 성공
- 생성 산출물:
  - `SV_DEMO_CHECK/Presentation/presentation_*.html`
  - `SV_DEMO_CHECK/Presentation/presentation_*.json`
- 확인 포인트:
  - `hdl_index.json` 읽어서 요약 출력
  - unmatched TB(`tb_test1.sv`)는 경고 후 스킵 (프롬프트 없이 진행)

---

## 3.3 의도된 실패 / 환경 제약 (버그와 구분 필요)

## A. Icarus 고급 SystemVerilog TB 한계
- `tb_test1.sv`는 `class`, `mailbox`, constrained random 등 사용
- Icarus Verilog에서 문법/기능 미지원으로 컴파일 실패 가능 (실제 발생 확인)
- 이 경우 권장 경로:
- `sim_vivado_run.bat` / Vivado xsim 사용

## B. AST 파서 미활성 (환경 의존)
- `tree-sitter-verilog` 설치 시 Windows에서 `node-gyp` + Visual Studio C++ Build Tools 필요
- 현재 환경에 C++ Build Tools 미설치로 AST 미활성
- 현재 `hdl_indexer`는 휴리스틱 모드로 동작

검증 결과:
- 일반 모드: `node templates/tools/hdl_indexer.js SV_DEMO_CHECK --write` -> 성공
- strict 모드: `node templates/tools/hdl_indexer.js SV_DEMO_CHECK --strict --write` -> 실패 (`ast_provider_missing`)

=> strict 동작 자체는 정상, 환경만 미준비

---

## 4. 현재 구현 범위의 의미 (실사용 관점)

## 이미 가능한 것
- `.sv` 파일 기반 프로젝트 생성/모듈 생성/TB 생성
- `.sv` TB 선택 후 Icarus/Vivado 시뮬레이션 경로 진입
- SV FSM 코드(`enum`, `always_ff`)에 대한 FSM draw
- `.sv` 기반 리포트/어노테이션/프레젠테이션(일부 비대화식 자동화 포함)
- 계층 도구에서 `package/interface` 선언 표시

## 아직 "완전파싱 지향" 단계로 남은 것
- AST 파서 실제 활성화 후 strict 검증
- 모든 파서 기반 기능이 AST 결과를 1차 데이터로 사용하도록 더 깊은 연동
- 고급 SV 문법(package/interface/import 포함)에서 계층/FSM/리포트 정확도 정량 검증 확대

---

## 5. 남은 작업 (권장 우선순위)

## 5.1 1순위: AST 환경 세팅 + strict 검증
- 목적: 휴리스틱 기반에서 AST 기반으로 정확도/안정성 업그레이드
- 필요:
- Visual Studio Build Tools (C++ workload) 설치
- `templates`에서 `npm install` 재실행
- 검증:
- `hdl_indexer --strict --write` 통과
- `sv_regression_project`에서 package/interface/include 케이스 재검증

## 5.2 2순위: 프레젠테이션 배치(`code_presentation_generate.bat`)에 비대화식 옵션 노출
- 현재:
- 파이썬 툴은 `--non-interactive` 지원
- 배치 스크립트는 여전히 프롬프트 중심
- 작업 제안:
- `--non-interactive`
- `--top <module>`
- `--project-title`, `--author`
- `--design 1|2`
- `--auto-tb y|n`
- 자동 테스트/CI/회귀 스크립트에 유리

## 5.3 3순위: `generate_presentation.py`의 non-interactive 기본 규칙 개선
- 현재 기본값:
- DataPath 슬라이드 1개 (모듈 전체 나열)
- detail module = top 제외 전체
- unmatched TB 스킵
- 개선 여지:
- 인덱서 그래프 기반 DataPath 후보 자동 구성
- package/interface 정보 슬라이드 또는 부가 메타 페이지 반영

## 5.4 4순위: 지원 매트릭스 기반 회귀 체크리스트 자동화
- 수동 검증은 많이 했지만 자동화는 미흡
- 간단한 smoke test runner(배치/PowerShell) 추가 가능

---

## 6. 리스크 / 주의사항

## A. AST 미설치 상태에서의 품질 한계
- 기능은 돌아도 복잡한 문법에서 누락/오탐 가능
- 특히 정규식 기반 인스턴스 추출/선언 인식은 코드 스타일 영향 받을 수 있음

## B. 시뮬레이터 차이
- `툴킷 스크립트 지원`과 `시뮬레이터 문법 지원`은 별개
- Icarus 실패를 툴킷 버그로 오판하지 않도록 문서화/로그 메시지 유지 필요

## C. 배치 스크립트의 상호작용성
- 일부 배치는 기본이 대화형이라 자동 테스트 시 입력 처리 필요
- `--no-pause` 외에 `--non-interactive` 계열 옵션 확장 가치 큼

---

## 7. 사용자(당신) 입장에서 지금 바로 확인해볼 체크포인트

## 빠른 체감 확인
1. `SV_DEMO_CHECK/src/fsm_demo.sv` 확인 (`logic`, `enum`, `always_ff/always_comb`)
2. `templates\bat\code_fsm_draw.bat SV_DEMO_CHECK` 실행 후 SVG/DRAWIO 생성 확인
3. `templates\bat\report_markdown_generate.bat SV_DEMO_CHECK --no-pause` 실행 후 `report.md` 확인
4. `templates\bat\sim_iverilog_vcd_run.bat SV_DEMO_CHECK --tb tb_test1 --no-pause` 실행해 `top=tb_adder_sv` 로그 확인

## Vivado 쪽 확인 (고급 SV TB)
1. `templates\bat\sim_vivado_run.bat SV_DEMO_CHECK`
2. `tb_test1.sv` 선택
3. `class/interface/mailbox` TB가 xsim에서 정상 진입하는지 확인

---

## 8. 결론 (중간 점검 판단)
- 계획 대비 진행률 체감:
- `핵심 플로우/사용성`: 높음 (이미 SV로 쓰기 가능)
- `완전파싱/정확도`: 중간 (AST 환경 세팅 전까지 제한)
- 현재 가장 큰 기술적 블로커는 코드 자체보다 `Windows AST 빌드 환경`

추천 다음 단계:
- `AST 환경 세팅 -> strict 검증 -> 프레젠테이션 배치 비대화식 옵션 노출`

