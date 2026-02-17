# FPGA Automation Toolkit

<div align="center">

![FPGA](https://img.shields.io/badge/FPGA-Verilog%20%2F%20SystemVerilog-blue) 
![Platform](https://img.shields.io/badge/Platform-Windows-lightgrey)
![License](https://img.shields.io/badge/License-MIT-green)

**Batch-based Automation Toolkit for Verilog/SystemVerilog Development**

[English Version](#english-version) | [한국어 버전](#한국어-버전)

</div>

---

<div id="english-version"></div>

## 🇬🇧 English Version

### Overview
This project is a batch-script-based automation toolkit designed to streamline **Verilog/SystemVerilog FPGA development**. 
The workflow is centralized around `MAIN.bat`, with project-specific tasks executed via scripts located in `templates/bat/*.bat`.

### 📂 Directory Structure
The automation system follows a strict directory structure:
- **`MAIN.bat`**: The central launcher located at the repository root.
- **`templates/`**: Contains all shared scripts, tools, and configurations.
  - **`bat/`**: Core execution scripts.
  - **`tools/`**: Helper scripts (Powershell, Python, etc.).

### 🚀 Quick Start

#### 1. Prerequisites
Ensure the following tools are installed and added to your system `PATH`:
- **Xilinx Vivado**: For synthesis and implementation.
- **Node.js (+ npm)**: For schematic generation tools.
- **Python 3**: For various automation tasks.

**Optional Extras for Full Functionality:**
- **Icarus Verilog (`iverilog`)**: For lightweight simulation.
- **GTKWave**: For viewing waveforms.
- **Yosys** (or `yowasp-yosys`): For schematic generation.
- **Pandoc**: For converting reports (Markdown → HTML/DOCX).

#### 2. Installation (Dependencies)
Before using Node-based tools (like `draw_schematic.bat`), run the installation once:
```batch
cd templates
npm install
```

#### 3. How to Use
1. Run **`MAIN.bat`** in the repository root.
2. Select your target project.
3. Choose a task from the menu:
   - **Code & Schematic Generation**: Create module templates, TBs, diagrams.
   - **Simulation**: Run simulations with Icarus Verilog.
   - **Report Automation**: Generate comprehensive documentation.
   - **Vivado Flow**: synthesis, implementation, and programming.

### 🛠️ Key Workflows

#### A. One Source Reporting (Recommended)
Generates high-quality HTML/DOCX reports from a single Markdown source (`report.md`), combining source code, testbenches, and waveforms.
1. `annotate_hdl_info.bat`
2. `generate_report_md.bat`
3. `mdToReport.bat`

#### B. Vivado Build & Program
- **Step-by-step**: Run `run_vivado_build_flow.bat`, then `program_fpga_device.bat`.
- **One-click**: Run `auto_build_and_program.bat`.

#### C. Simulation
- **Interactive**: `run_icarus_simulation.bat` lets you select a testbench and view waveforms.
- **Automated**: `auto_sim_and_report.bat` runs simulations and generates result reports automatically.

### 📁 Project Layout
When you create a new project using `Setup.bat`, the following structure is generated:
```text
[ProjectName]/
├── src/                # Design sources (.v, .sv)
├── tb/                 # Testbenches
├── constrs/            # Constraint files (.xdc)
├── ip/                 # IP cores
├── output/             # Build outputs (Bitstreams, Reports)
│   ├── docs/           # Generated documentation
│   ├── Diagram/        # Schematics (Simple/Detailed)
│   └── FINALReport/    # Vivado reports
└── Presentation/       # Presentation slides data
```

### ❓ Troubleshooting
- **`netlistsvg not found`**: Run `npm install` inside the `templates` directory.
- **DOCX Generation Failed**: Close Microsoft Word if `report.docx` is open.
- **Vivado/Icarus not found**: Verify that their `bin` directories are added to your System Environment `PATH`.

---
<br>

<div id="한국어-버전"></div>

## 🇰🇷 한국어 버전

### 개요
이 프로젝트는 **Verilog/SystemVerilog FPGA 개발**을 효율화하기 위한 배치 스크립트 기반 자동화 툴킷입니다.
모든 작업은 `MAIN.bat`를 중심으로 이루어지며, 실제 기능은 `templates/bat/*.bat` 경로의 스크립트들을 통해 실행됩니다.

[English Version](#english-version) 으로 돌아가기

### 📂 디렉토리 구조
자동화 시스템은 다음 구조를 따릅니다:
- **`MAIN.bat`**: 저장소 루트에 위치한 통합 실행 런처입니다.
- **`templates/`**: 공용 스크립트, 툴, 설정 파일이 중앙화된 폴더입니다.
  - **`bat/`**: 핵심 실행 스크립트
  - **`tools/`**: 보조 스크립트 (Powershell, Python 등)

### 🚀 빠른 시작 (Quick Start)

#### 1. 필수 준비물
다음 도구들이 설치되어 있고 시스템 `PATH`에 등록되어 있어야 합니다:
- **Xilinx Vivado**: 합성 및 구현용
- **Node.js (+ npm)**: 회로도 생성 툴용
- **Python 3**: 다목적 자동화용

**권장 추가 도구:**
- **Icarus Verilog (`iverilog`)**: 시뮬레이션용
- **GTKWave**: 파형 확인용
- **Pandoc**: 문서 변환용 (Markdown → HTML/DOCX)

#### 2. 의존성 설치
`draw_schematic.bat` 등 Node 기반 툴을 사용하기 전 1회 실행이 필요합니다:
```cmd
cd templates
npm install
```

#### 3. 사용 방법
1. 저장소 루트에서 **`MAIN.bat`**를 실행합니다.
2. 작업할 프로젝트를 선택합니다.
3. 원하는 메뉴를 선택하여 작업을 수행합니다:
   - **Code & Schematic**: 모듈/TB 템플릿 생성, 다이어그램 작성
   - **Simulation**: Icarus Verilog 시뮬레이션 수행
   - **Report Automation**: 통합 문서 생성
   - **Vivado Flow**: 비트스트림 생성 및 FPGA 프로그래밍

### 🛠️ 주요 워크플로우

#### A. One Source 리포트 (권장)
소스 코드, 테스트벤치, 파형 등을 하나의 Markdown(`report.md`)으로 통합하여 HTML/DOCX 리포트를 생성합니다.
1. `annotate_hdl_info.bat`
2. `generate_report_md.bat`
3. `mdToReport.bat`

#### B. Vivado 빌드 및 프로그램
- **단계별 실행**: `run_vivado_build_flow.bat` 실행 후 `program_fpga_device.bat` 실행
- **원클릭 실행**: `auto_build_and_program.bat` (빌드 후 자동 업로드)

#### C. 시뮬레이션
- **대화형**: `run_icarus_simulation.bat` - 테스트벤치 선택 및 Waveform 확인
- **자동화**: `auto_sim_and_report.bat` - 시뮬레이션 수행 후 결과 리포트 자동 생성

### 📁 프로젝트 폴더 구조
`Setup.bat`로 프로젝트 생성 시 아래와 같은 구조가 생성됩니다:
```text
[ProjectName]/
├── src/                # 설계 소스 (.v, .sv)
├── tb/                 # 테스트벤치
├── constrs/            # 제약 조건 파일 (.xdc)
├── ip/                 # IP 코어
├── output/             # 빌드 결과물 (Bitstream 등)
│   ├── docs/           # 생성된 문서 (Report)
│   ├── Diagram/        # 회로도 (Simple/Detailed)
│   └── FINALReport/    # Vivado 최종 리포트
└── Presentation/       # 프레젠테이션 데이터
```

### ❓ 트러블슈팅
- **`netlistsvg not found` 오류**: `templates` 폴더에서 `npm install`을 실행하세요.
- **DOCX 생성 실패 (Permission denied)**: `report.docx` 파일이 Word에서 열려 있다면 종료 후 다시 시도하세요.
- **Vivado/Icarus 미탐지**: 설치 경로의 `bin` 폴더가 환경 변수 `PATH`에 등록되었는지 확인하세요.
