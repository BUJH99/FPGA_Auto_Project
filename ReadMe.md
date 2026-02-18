# FPGA Automation Toolkit

<div align="center">

![FPGA](https://img.shields.io/badge/FPGA-Verilog%20%2F%20SystemVerilog-blue)
![Platform](https://img.shields.io/badge/Platform-Windows-lightgrey)
![License](https://img.shields.io/badge/License-MIT-green)

**Batch-based Automation Toolkit for Verilog/SystemVerilog Development**

[English Version](#english-version) | [한국어](#korean-version)

</div>

---

<div id="english-version"></div>

## English Version

### Overview
This project is a batch-script-based automation toolkit for **Verilog/SystemVerilog FPGA development**.
The workflow is centered on `MAIN.bat`, and project tasks are executed through scripts under `templates/bat/*.bat`.

### Directory Structure
- **`MAIN.bat`**: Main launcher at repository root.
- **`templates/`**: Shared scripts, tools, and configuration.
- **`templates/bat/`**: Task entry scripts.
- **`templates/tools/`**: Helper scripts (Node.js, PowerShell, Python).
- **`templates/tcl/`**: Vivado Tcl automation scripts.

### Quick Start

#### 1. Prerequisites
Install and expose the following tools in system `PATH`:
- **Xilinx Vivado**
- **Node.js (+ npm)**
- **Python 3**

Optional for full flow:
- **Pandoc** (for `md -> html/docx`)
- **Yosys** / `yowasp-yosys` (for schematic generation)

#### 2. Install dependencies
Run once:

```batch
cd templates
npm install
```

#### 3. Run
1. Execute `MAIN.bat`.
2. Select a target project.
3. Run the task you need from menu.

### Key Workflows

#### A. One Source Reporting (Recommended)
Generate report assets from HDL/TB and build deliverables from one Markdown source (`report.md`):
1. `report_hdl_info_annotate.bat`
2. `report_markdown_generate.bat`
3. `report_markdown_to_docx.bat`

`report_markdown_generate.bat` behavior:
- Supports module selection (`--modules=` or interactive selection).
- **Selection applies only to `1.3 Sub block` section**.
- Overall architecture sections (`1.1`, `1.2`) are always generated from all modules.
- `Top` is always included first in sub-block section.

#### B. Interactive Simulation (Vivado GUI)
- `sim_vivado_run.bat` scans testbenches, lets you choose sim top, and opens Vivado simulation GUI.
- Vivado simulation artifacts are contained inside project:
  - `<ProjectDir>/vivado_project/`
  - `<ProjectDir>/vivado_project/vivado_sim_log/`

#### C. Build & Program
- Step-by-step: `vivado_build_flow_run.bat` -> `vivado_fpga_program.bat`
- One-click: `vivado_build_and_program_auto.bat`

### Project Layout
Example project structure after setup:

```text
[ProjectName]/
|-- src/                          # Design sources (.v, .sv)
|-- tb/                           # Testbenches
|-- constrs/                      # Constraint files (.xdc)
|-- ip/                           # IP cores
|-- output/                       # Build/report outputs
|   |-- docs/                     # report.md / html / docx
|   |-- Diagram/                  # Simple/Detailed diagrams
|   `-- FINALReport/              # Vivado report assets
|-- vivado_project/               # Vivado simulation workspace
|   |-- project/                  # Generated Vivado sim project(s)
|   `-- vivado_sim_log/           # vivado log/journal/backup files
`-- Presentation/                 # Presentation assets
```

### Troubleshooting
- `netlistsvg not found`: run `npm install` in `templates`.
- DOCX generation failed: close `report.docx` if it is open in Word.
- `vivado` not found: verify Vivado `bin` directory is in system `PATH`.

---

<div id="korean-version"></div>

## 한국어

### 개요
이 프로젝트는 **Verilog/SystemVerilog FPGA 개발**을 위한 배치 기반 자동화 툴킷입니다.
전체 흐름은 `MAIN.bat`를 중심으로 동작하며, 실제 기능은 `templates/bat/*.bat` 스크립트로 실행됩니다.

### 디렉터리 구조
- **`MAIN.bat`**: 저장소 루트의 메인 실행기
- **`templates/`**: 공용 스크립트/툴/설정
- **`templates/bat/`**: 작업별 진입 스크립트
- **`templates/tools/`**: 보조 스크립트(Node.js/PowerShell/Python)
- **`templates/tcl/`**: Vivado Tcl 자동화 스크립트

### 빠른 시작

#### 1. 필수 도구
아래 도구를 설치하고 `PATH`에 등록하세요:
- **Xilinx Vivado**
- **Node.js (+ npm)**
- **Python 3**

권장(전체 기능):
- **Pandoc** (`md -> html/docx` 변환)
- **Yosys / yowasp-yosys** (회로도 생성)

#### 2. 의존성 설치
최초 1회 실행:

```cmd
cd templates
npm install
```

#### 3. 실행 방법
1. `MAIN.bat` 실행
2. 대상 프로젝트 선택
3. 메뉴에서 원하는 작업 실행

### 주요 워크플로우

#### A. One Source 보고서 (권장)
HDL/TB/다이어그램 정보를 하나의 Markdown(`report.md`)로 모은 뒤 최종 문서를 생성합니다.
1. `report_hdl_info_annotate.bat`
2. `report_markdown_generate.bat`
3. `report_markdown_to_docx.bat`

`report_markdown_generate.bat` 동작 규칙:
- 모듈 선택 가능(`--modules=` 또는 인터랙티브 선택)
- 선택 적용 범위는 **`1.3 서브 블록 설명`만**
- `1.1`, `1.2` 전체 구조/계층은 항상 전체 모듈 기준
- `Top` 모듈은 서브 블록에서 항상 첫 번째로 고정

#### B. Vivado GUI 시뮬레이션
- `sim_vivado_run.bat` 실행 시 테스트벤치 목록에서 Top을 선택 후 Vivado GUI를 엽니다.
- 시뮬레이션 산출물은 프로젝트 내부로 고정됩니다:
  - `<ProjectDir>/vivado_project/`
  - `<ProjectDir>/vivado_project/vivado_sim_log/`

#### C. 빌드/프로그래밍
- 단계 실행: `vivado_build_flow_run.bat` -> `vivado_fpga_program.bat`
- 원클릭: `vivado_build_and_program_auto.bat`

### 프로젝트 구조
프로젝트 생성 후 예시 구조:

```text
[ProjectName]/
|-- src/                          # 설계 소스 (.v, .sv)
|-- tb/                           # 테스트벤치
|-- constrs/                      # 제약 파일 (.xdc)
|-- ip/                           # IP 코어
|-- output/                       # 빌드/리포트 산출물
|   |-- docs/                     # report.md / html / docx
|   |-- Diagram/                  # Simple/Detailed 다이어그램
|   `-- FINALReport/              # Vivado 리포트
|-- vivado_project/               # Vivado 시뮬레이션 작업 폴더
|   |-- project/                  # 생성된 Vivado 시뮬 프로젝트
|   `-- vivado_sim_log/           # vivado 로그/저널/백업 파일
`-- Presentation/                 # 발표 자료 자산
```

### 트러블슈팅
- `netlistsvg not found`: `templates`에서 `npm install` 실행
- DOCX 생성 실패: Word에서 `report.docx` 열려 있으면 닫고 재시도
- `vivado` 인식 실패: Vivado `bin` 경로의 `PATH` 등록 상태 확인
