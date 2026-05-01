# FPGA Auto Manifest v0 (`fpga_auto.yml`)

## Goal
`fpga_auto.yml` fixes project file discovery as declaration, not heuristics. This supports deterministic behavior across BAT and future SH/Linux ports.

## Manifest Location
- Project root: `<project>/fpga_auto.yml`

## Project Root Policy
- New projects are created under `<repo-parent>/Project/<name>/`.
- Canonical project-create entrypoint is `templates/contexts/project_bootstrap/adapters/bat/project_create.bat`.
- Project creation auto-generates `<project>/fpga_auto.yml` from `templates/manifest/fpga_auto.template.yml`.
- `MAIN.bat` discovers only sibling `../Project/*` projects with valid `fpga_auto.yml`.
- Legacy root projects can be copied to sibling `../Project/*` with `templates/contexts/project_bootstrap/adapters/bat/project_migrate_legacy.bat`.
- Existing sibling projects can be upgraded in place with `templates/contexts/project_bootstrap/adapters/bat/project_upgrade_existing.bat`.
- In `MAIN.bat`, use `[U] Upgrade Existing Projects` from the project selection screen or `[U] Upgrade This Project` inside a selected project.

## v0 Required Fields
All fields below are required in v0:
- `version`
- `project.name`
- `hdl.top`
- `hdl.src_globs`
- `hdl.tb_globs`

## v0 Optional Fields (Implemented)
These are optional and used by the manifest resolver CLI:
- Canonical: `templates/contexts/manifest/adapters/cli/manifest_resolve_cli.js`
- `hdl.inc_globs` (default: `[]`)
- `hdl.xdc_globs` (default: `[]`)
- `hdl.exclude_globs` (default: `[]`)

## v0 Optional Fields (Validated / Doctor-visible)
These sections are optional. They are shape-validated by the manifest stack and surfaced by `toolkit_doctor`, but are not yet consumed uniformly by every BAT runtime flow:
- `sim.*`
- `vivado.*`
- `report.*`
- `vitis.*`

## Project Upgrade Contract
`project_upgrade_existing.bat` updates old managed projects without moving HDL files:
- creates missing scaffold folders such as `include/`, `inc/`, `constrs/`, `sw/common/*`, `sw/apps/hello_world/*`, `vitis/*`, `output/vitis/*`, and `log/vitis/`
- creates `sw/apps/hello_world/src/main.c` only when missing
- creates `vitis/launch/hardware.json` only when missing
- adds or completes the optional `vitis:` manifest section while preserving existing HDL, sim, Vivado, and report settings
- supports `--dry-run` for a no-write preview

Example:
```bat
templates\contexts\project_bootstrap\adapters\bat\project_upgrade_existing.bat --dry-run
templates\contexts\project_bootstrap\adapters\bat\project_upgrade_existing.bat MyProject
```

## Example Schema
```yaml
version: "0"
project:
  name: "ExampleProject"
hdl:
  top: "top"
  src_globs:
    - "src/**/*.v"
    - "src/**/*.sv"
  tb_globs:
    - "tb/tb_*.v"
    - "tb/tb_*.sv"
  inc_globs:
    - "include/**/*.vh"
  xdc_globs:
    - "constrs/**/*.xdc"
  exclude_globs:
    - "src/legacy/**"
sim:
  tool: "iverilog" # optional metadata, validated
vivado:
  mode: "xsim"     # optional metadata, validated
report:
  enable: true      # optional metadata, validated
```

## CLI Contract (`manifest_resolve_cli.js`)
- `--project <dir>`: required in resolver mode
- `--json`: print JSON to stdout
- `--write <path>`: write same JSON to file
- `--emit-lists <dir>`: write resolved list files (`manifest_src_files.lst`, `manifest_tb_files.lst`, `manifest_inc_dirs.lst`, `manifest_xdc_files.lst`)
- `--selftest`: run fixture smoke tests (`tests/manifest_smoke/*`)

## Exit Codes
- `0`: OK
- `1`: execution failure (exception/IO/selftest failure)
- `2`: input/usage failure (YAML parse, missing required fields, bad args)

## Missing Manifest Policy
If `<project>/fpga_auto.yml` does not exist:
- error includes `manifest_missing`
- command exits `2`
- strict policy applies (no fallback in resolver/runtime flows)

## BAT Integration Policy
- Canonical BAT entrypoints initialize manifest context through `templates/shared/adapters/bat/bootstrap_manifest_context.bat`.
- Scripts run in manifest-only mode and use manifest-resolved file lists.
- If manifest resolution fails (missing/parse/validation), scripts stop immediately (no fallback).

## Output JSON Schema (Fixed)
Top-level fields are fixed and must not change:
- `manifest_path: string | null`
- `project_root: string`
- `config: object`
- `resolved`:
  - `src_files: string[]`
  - `tb_files: string[]`
  - `inc_dirs: string[]`
  - `xdc_files: string[]`
- `errors: {code:string, message:string, path?:string}[]`
- `warnings: {code:string, message:string, path?:string}[]`

## Path and Ordering Policy
- All `resolved.*` entries are project-relative paths.
- Path separator is `/`.
- Results are deterministic lexicographic sort.
- Duplicates are removed.

## Glob Expansion Policy
- Zero-match glob pattern is warning: `glob_no_match`
- Runtime/validation failures become `errors[]` and produce exit code `2`

## Error/Warning Codes
Errors:
- `usage_error`
- `project_not_found`
- `manifest_missing`
- `manifest_parse_error`
- `manifest_required_field`
- `manifest_type_error`
- `glob_expand_failed`

Warnings:
- `glob_no_match`

## JSON Output Example
```json
{
  "manifest_path": "C:/repo/my_proj/fpga_auto.yml",
  "project_root": "C:/repo/my_proj",
  "config": { "version": "1" },
  "resolved": {
    "src_files": ["src/top.sv"],
    "tb_files": ["tb/tb_top.sv"],
    "inc_dirs": ["include"],
    "xdc_files": []
  },
  "errors": [],
  "warnings": []
}
```

## Examples
- Minimal: `templates/manifest/examples/fpga_auto.minimal.yml`
- Vivado/xsim-oriented: `templates/manifest/examples/fpga_auto.vivado_xsim.yml`
