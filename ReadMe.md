[🇺🇸 English](#fpga-automation-toolkit) | [🇰🇷 Korean (한국어)](#fpga-verilog-%EC%9E%90%EB%8F%99%ED%99%94-%ED%88%B4%ED%82%B7-fpga-automation-toolkit)

# FPGA Automation Toolkit

This project provides a **comprehensive automated environment** for Verilog-based FPGA development.
It aims to maximize development productivity by automating the entire process from project creation, simulation, synthesis, implementation, to schematic visualization using scripts.

## 🚀 Key Features

*   **Automated Project Creation**: Instantly create a workspace with a standardized directory structure and scripts via `Setup.bat`.
*   **One-Click Build**: Executes synthesis, implementation, and bitstream generation at once by controlling Vivado in batch mode.
*   **Powerful Visualization (Schematic)**: Analyzes Verilog code and automatically converts it into **SVG** and **Draw.io** formats.
    *   **Simple Mode**: Block diagram focused on I/O ports (for Leaf modules).
    *   **Detailed Mode**: Detailed representation of internal logic and signal flow (Yosys-based, including submodules).
    *   *Latest Feature: Dynamic sizing and optimized arrow routing applied.*
*   **Code Template Generation**: Quickly generates basic code for modules (.v) and testbenches (.tb) via an interactive interface.
*   **Open Source Simulation**: Provides a lightweight and fast verification environment through Icarus Verilog + GTKWave integration.
*   **Hierarchy Exploration**: Visualizes dependencies and hierarchy between modules in the project as a tree structure.

---

## 🛠️ Prerequisites

To fully utilize this toolkit, the following tools need to be installed.

1.  **Xilinx Vivado**: Essential for FPGA synthesis and bitstream generation (Must be in PATH).
2.  **Icarus Verilog**: Recommended for a lightweight simulation environment.
3.  **GTKWave**: For viewing simulation waveforms.
4.  **Node.js & npm**: Required for schematic generation features (`netlistsvg`, `svg2drawio`).
5.  **Yosys** (Optional): Required for generating Detailed Schematics (Recommended: `yowasp-yosys`).

---

## 🚦 Getting Started

### 1. Create Project
Run the `Setup.bat` file in the repository root.
```cmd
> Setup.bat
Enter project name: MyFPGAProject
```
A folder with the entered name will be created with **project-only working directories**.
Automation scripts/tools remain centralized under `templates/` in the repository root.

### 2. Development Workflow

Use the launcher from the repository root.

*   **`MAIN.bat`**: Interactive launcher in repository root. It scans project folders and runs scripts from `templates/bat/` for the selected project.

#### 🏗️ Build & Implementation
*   **`bat\run_vivado_build_flow.bat`**: Generates a Vivado project and builds up to the bitstream in one go. Results are saved in `output/`. At the end, it asks whether to run device programming (`Y/N`).
*   **`bat\program_fpga_device.bat`**: Downloads the generated bitstream to the board.
*   **`bat\launch_ipi_gui.bat`**: Opens the configured project in the Vivado GUI environment.

#### 🎨 Visualization (Schematic)
*   **`bat\draw_schematic.bat`**: Analyzes source code to generate diagrams.
    *   **Input**: Verilog files in the `src/` folder.
    *   **Output**: `Diagram/Simple/` (Block diagram), `Diagram/Detailed/` (Detailed schematic).
    *   **Feature**: The generated `.drawio` files can be opened and edited directly in [draw.io](https://app.diagrams.net/).

#### 🧪 Simulation
*   **`bat\run_icarus_simulation.bat`**: Compiles the testbench and performs simulation. GTKWave automatically runs upon completion.

#### 📝 Code Assistance
*   **`bat\generate_verilog_module.bat`**: Create a new module file (assists with port definition, etc.).
*   **`bat\generate_verilog_testbench.bat`**: Analyze an existing module to automatically generate a testbench shell.
*   **`bat\browse_verilog_hierarchy.bat`**: Check the module hierarchy of the project.

---

## 📂 Directory Structure

The structure of the project created by `Setup.bat` is as follows:

```
[ProjectName]/
├── constrs/         # XDC constraints
├── Diagram/         # Generated schematic images
├── ip/              # Exported/managed IP files (.xci)
├── md/              # Markdown outputs/notes
├── output/          # Build logs, bitstreams, reports storage
├── report_assets/   # Reserved project asset folder
├── src/             # Verilog source code (.v/.sv) - User written
├── skills/          # Project-specific skill notes/assets
└── tb/              # Testbench code (.v/.sv) - User written
```

## ⚙️ Configuration

You can change the FPGA part number or project settings in `templates/tcl/project_build_config.tcl`.

```tcl
set part_number "xc7a35tcpg236-1"  ; # Target FPGA Part
set top_module "Top"               ; # Top Module Name
```

<br><br><br>

---
---

<br><br><br>

[🇺🇸 English](#fpga-automation-toolkit) | [🇰🇷 Korean (한국어)](#fpga-verilog-%EC%9E%90%EB%8F%99%ED%99%94-%ED%88%B4%ED%82%B7-fpga-automation-toolkit)

# FPGA Verilog 자동화 툴킷 (FPGA Automation Toolkit)

이 프로젝트는 Verilog 기반 FPGA 개발을 위한 **종합 자동화 환경**입니다.
프로젝트 생성부터 시뮬레이션, 합성, 구현, 그리고 회로도(Schematic) 시각화까지의 전 과정을 스크립트로 자동화하여 개발 효율성을 극대화합니다.

## 🚀 주요 기능 (Key Features)

*   **프로젝트 자동 생성**: `Setup.bat`을 통해 표준화된 디렉토리 구조와 스크립트가 포함된 작업 공간을 즉시 생성합니다.
*   **원클릭 빌드 (One-Click Build)**: Vivado를 배치 모드로 제어하여 합성(Synthesis), 구현(Implementation), 비트스트림(Bitstream) 생성을 한 번에 수행합니다.
*   **강력한 시각화 (Schematic Visualization)**: Verilog 코드를 분석하여 회로도를 **SVG** 및 **Draw.io** 포맷으로 자동 변환합니다.
    *   **Simple Mode**: 모듈의 입출력 포트 위주의 블록 다이어그램 (Leaf 모듈용)
    *   **Detailed Mode**: 내부 로직과 신호 흐름을 상세히 표현 (Yosys 기반, 서브모듈 포함 시)
    *   *최신 기능: 동적 사이즈 조절 및 최적화된 화살표 라우팅 적용*
*   **코드 템플릿 생성**: 대화형 인터페이스로 모듈(.v)과 테스트벤치(.tb) 기본 코드를 빠르게 생성합니다.
*   **오픈소스 시뮬레이션**: Icarus Verilog + GTKWave 연동을 통해 가볍고 빠른 검증 환경을 제공합니다.
*   **계층 구조 탐색**: 프로젝트 내 모듈 간의 의존성 및 계층 구조를 트리 형태로 시각화합니다.

---

## 🛠️ 필수 도구 (Prerequisites)

이 툴킷을 100% 활용하기 위해 다음 도구들의 설치가 필요합니다.

1.  **Xilinx Vivado**: FPGA 합성 및 비트스트림 생성을 위해 필수 (PATH 등록 필요).
2.  **Icarus Verilog**: 가벼운 시뮬레이션 환경을 위해 권장.
3.  **GTKWave**: 시뮬레이션 파형 확인용.
4.  **Node.js & npm**: 회로도 생성(`netlistsvg`, `svg2drawio`) 기능을 위해 필요.
5.  **Yosys** (선택): 상세 회로도(Detailed Schematic) 생성을 위해 필요 (`yowasp-yosys` 권장).

---

## 🚦 시작하기 (Getting Started)

### 1. 프로젝트 생성
레포지토리 루트의 `Setup.bat` 파일을 실행합니다.
```cmd
> Setup.bat
Enter project name: MyFPGAProject
```
입력한 이름으로 폴더가 생성되며, **프로젝트 작업용 디렉토리만** 만들어집니다.
자동화 실행 파일은 레포지토리 루트의 `templates/`에 중앙화되어 유지됩니다.

### 2. 개발 워크플로우

레포지토리 루트에서 런처를 사용하세요.

*   **`MAIN.bat`**: 레포지토리 루트의 대화형 런처입니다. 프로젝트 폴더를 선택하면 `templates/bat/`의 스크립트를 해당 프로젝트 컨텍스트로 실행합니다.

#### 🏗️ 빌드 및 구현
*   **`bat\run_vivado_build_flow.bat`**: Vivado 프로젝트를 생성하고 비트스트림까지 일괄 빌드합니다. 결과는 `output/`에 저장되며, 마지막에 디바이스 프로그래밍 실행 여부를 `Y/N`으로 묻습니다.
*   **`bat\program_fpga_device.bat`**: 생성된 비트스트림을 보드에 다운로드합니다.
*   **`bat\launch_ipi_gui.bat`**: 설정된 프로젝트를 Vivado GUI 환경에서 엽니다.

#### 🎨 시각화 (Schematic)
*   **`bat\draw_schematic.bat`**: 소스 코드를 분석하여 다이어그램을 생성합니다.
    *   **입력**: `src/` 폴더 내의 Verilog 파일들
    *   **출력**: `Diagram/Simple/` (블록도), `Diagram/Detailed/` (상세 회로도)
    *   **특징**: 생성된 `.drawio` 파일은 [draw.io](https://app.diagrams.net/)에서 바로 열어 수정 가능합니다.

#### 🧪 시뮬레이션
*   **`bat\run_icarus_simulation.bat`**: 테스트벤치를 컴파일하고 시뮬레이션을 수행합니다. 완료 후 GTKWave가 자동 실행됩니다.

#### 📝 코드 작성 보조
*   **`bat\generate_verilog_module.bat`**: 새 모듈 파일 생성 (포트 정의 등 보조).
*   **`bat\generate_verilog_testbench.bat`**: 기존 모듈을 분석하여 테스트벤치 껍데기 자동 생성.
*   **`bat\browse_verilog_hierarchy.bat`**: 프로젝트의 모듈 계층 구조 확인.

---

## 📂 디렉토리 구조 (Directory Structure)

`Setup.bat`으로 생성된 프로젝트의 구조는 다음과 같습니다.

```
[ProjectName]/
├── constrs/         # XDC 제약 파일
├── Diagram/         # 생성된 회로도 이미지
├── ip/              # IP 파일(.xci) 저장소
├── md/              # Markdown 결과/노트
├── output/          # 빌드 로그, 비트스트림, 레포트 저장소
├── report_assets/   # 프로젝트 예약 에셋 폴더
├── src/             # Verilog 소스 코드 (.v/.sv) - 사용자가 작성
├── skills/          # 프로젝트별 스킬/메모 자산
└── tb/              # 테스트벤치 코드 (.v/.sv) - 사용자가 작성
```

## ⚙️ 환경 설정

`templates/tcl/project_build_config.tcl` 파일에서 FPGA 부품 번호나 프로젝트 설정을 변경할 수 있습니다.

```tcl
set part_number "xc7a35tcpg236-1"  ; # Target FPGA Part
set top_module "Top"               ; # Top Module Name
```
