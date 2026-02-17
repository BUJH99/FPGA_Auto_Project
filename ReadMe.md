# FPGA Automation Toolkit

Verilog/SystemVerilog FPGA 개발을 위한 배치 기반 자동화 툴킷입니다.  
현재 구조는 `MAIN.bat`를 중심으로, 프로젝트별 작업은 `templates/bat/*.bat` 스크립트를 통해 실행됩니다.

## 1. 현재 자동화 구조

실행 진입점
- `MAIN.bat`: 저장소 루트의 통합 런처
- `templates/bat/Setup.bat`: 신규 프로젝트 생성

`MAIN.bat` 메뉴 그룹(실제 반영 기준)
- `Code & Schematic Generation`
- `Simulation`
- `Report Automation (One Source)`
- `Legacy Report (Vivado HTML / Old Docs)`
- `Vivado Flow & FPGA`

핵심 원칙
- 스크립트/툴은 저장소 `templates/`에 중앙화
- 프로젝트별 산출물은 각 프로젝트 폴더 하위에 저장
- One Source 리포트 흐름(`report.md` 중심) 우선 사용

---

## 2. 빠른 시작

### 2.1 필수 준비

필수 도구
- Xilinx Vivado (PATH 등록)
- Node.js + npm
- Python 3

기능별 추가 도구
- Icarus Verilog (`iverilog`, `vvp`)
- GTKWave (`gtkwave`)
- Yosys 또는 yowasp-yosys (회로도 생성)
- Pandoc (HTML/DOCX 리포트 생성)
- Python `jinja2` (프레젠테이션 생성)

### 2.2 템플릿 의존성 설치

`draw_schematic.bat` 등 Node 기반 스크립트 사용 전 1회 실행:

```cmd
cd templates
npm install
```

### 2.3 프로젝트 생성

권장: `MAIN.bat` 실행 후 `S`(Setup New Project) 선택  
직접 실행도 가능:

```cmd
templates\bat\Setup.bat
```

### 2.4 기본 사용 방식

1. 저장소 루트에서 `MAIN.bat` 실행
2. 프로젝트 선택
3. 필요한 메뉴 번호 선택 후 스크립트 실행

---

## 3. 권장 워크플로우

### 3.1 One Source 리포트 (권장)

목적
- `src/`, `tb/`, 다이어그램/파형 자산을 기반으로
- 하나의 원본 `output/docs/report.md`에서
- `report.html`, `report.docx`를 생성

순서
1. `annotate_hdl_info.bat`
2. `generate_report_md.bat`
3. `mdToReport.bat`

직접 실행 예시

```cmd
templates\bat\annotate_hdl_info.bat <ProjectPath>
templates\bat\generate_report_md.bat <ProjectPath>
templates\bat\mdToReport.bat <ProjectPath>
```

주요 출력
- `output/docs/report.md`
- `output/docs/github.css`
- `output/docs/report.html`
- `output/docs/report.docx`

참고
- `mdToReport.bat`는 DOCX 생성 시 표지 중복을 자동 정리해 앞부분을 단일 표지 구조로 맞춥니다.
- `report.docx`가 열려 있으면 Word 변환이 실패할 수 있습니다(파일 잠금).

### 3.2 Vivado 빌드/구현/프로그램

단계형
1. `run_vivado_build_flow.bat`
2. 필요 시 `program_fpga_device.bat`

원클릭
- `auto_build_and_program.bat` (빌드 후 자동 프로그램)

주요 출력
- 비트스트림 및 빌드 산출물: `output/`
- 최종 HTML 리포트: `output/FINALReport/Final_Build_Report.html`
- 로그: `log/`

### 3.3 시뮬레이션

- `run_icarus_simulation.bat`: TB 선택, 컴파일/시뮬레이션, VCD/GTKWave, WaveDrom JSON 생성(설정 시)
- `auto_sim_and_report.bat`: TB 시나리오 파싱 기반 자동 시뮬레이션 + 리포트 생성

### 3.4 코드/다이어그램/프레젠테이션

- `generate_verilog_module.bat`: 모듈 템플릿 생성
- `create_tb_template.bat`: TB 템플릿 생성
- `draw_schematic.bat`: Simple/Detailed/JSON 다이어그램 생성
- `draw_fsm.bat`: FSM 다이어그램 생성
- `browse_verilog_hierarchy.bat`, `print_verilog_hierarchy.bat`: 계층 확인
- `generate_presentation.bat`: `Presentation/` HTML/JSON 생성

---

## 4. 배치 스크립트 맵 (`templates/bat`)

Code & Schematic
- `generate_verilog_module.bat`
- `create_tb_template.bat`
- `draw_schematic.bat`
- `browse_verilog_hierarchy.bat`
- `print_verilog_hierarchy.bat`
- `draw_fsm.bat`
- `generate_presentation.bat`

Simulation
- `run_icarus_simulation.bat`
- `auto_sim_and_report.bat`

Report Automation (One Source)
- `annotate_hdl_info.bat`
- `generate_report_md.bat`
- `mdToReport.bat`

Legacy Report
- `generate_report.bat`
- `generate_docs.bat`

Vivado Flow & FPGA
- `launch_ipi_gui.bat`
- `run_vivado_build_flow.bat`
- `finalize_block_design.bat`
- `retarget_ip_to_part.bat`
- `program_fpga_device.bat`
- `auto_build_and_program.bat`

---

## 5. 프로젝트 디렉터리 구조 (`Setup.bat` 기준)

```text
[ProjectName]/
  constrs/
  ip/
  md/
  log/
  report_assets/
  skills/
  src/
  tb/
  Presentation/                 # 템플릿이 있으면 복사됨
  output/
    docs/
    Diagram/
      Simple/
      Detailed/
      JSON/
    fsm/
      svg/
      drawio/
    FINALReport/
```

---

## 6. 설정 포인트

FPGA/프로젝트 빌드 설정
- `templates/tcl/project_build_config.tcl`
  - `part_number`
  - `top_module`
  - 기타 Vivado 프로젝트 파라미터

프로젝트 동기화 경로(선택)
- `SyncProjectsToSourceProject.bat`
  - `DEST_ROOT`가 로컬 환경 경로로 고정되어 있으므로 필요 시 수정

---

## 7. 트러블슈팅

`draw_schematic.bat`에서 `netlistsvg not found`
- `cd templates && npm install` 실행

`mdToReport.bat`에서 DOCX 생성 실패(permission denied)
- `output/docs/report.docx`를 열고 있는 프로그램(Word 등) 종료 후 재실행

`run_vivado_build_flow.bat`에서 Vivado 미탐지
- Vivado `bin` 경로 PATH 등록 확인

`run_icarus_simulation.bat`에서 `iverilog` 미탐지
- Icarus Verilog 설치 및 PATH 등록 확인

---

## 8. 권장 운영 방식

- 일상 작업은 `MAIN.bat`에서 실행
- 리포트는 One Source 흐름(`annotate -> report_md -> mdToReport`) 사용
- Legacy 리포트(`generate_report.bat`, `generate_docs.bat`)는 유지보수/호환 용도로만 사용
