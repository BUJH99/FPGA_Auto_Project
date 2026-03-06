# FPGA Auto Manifest v0 (`fpga_auto.yml`)

## Goal
`fpga_auto.yml` fixes project file discovery as declaration, not heuristics. This supports deterministic behavior across BAT and future SH/Linux ports.

## Manifest Location
- Project root: `<project>/fpga_auto.yml`

## Project Root Policy
- New projects are created under `<repo>/Project/<name>/`.
- Canonical project-create entrypoint is `templates/contexts/project_bootstrap/adapters/bat/project_create.bat`.
- Project creation auto-generates `<project>/fpga_auto.yml` from `templates/manifest/fpga_auto.template.yml`.
- `MAIN.bat` discovers only `Project/*` projects with valid `fpga_auto.yml`.
- Legacy root projects can be copied to `Project/*` with `templates/contexts/project_bootstrap/adapters/bat/project_migrate_legacy.bat`.

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

## v0 Optional Fields (Reserved, No-op)
These sections are documented for expansion, but ignored in v0 runtime behavior:
- `sim.*`
- `vivado.*`
- `report.*`

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
  tool: "iverilog" # reserved in v0
vivado:
  mode: "xsim"     # reserved in v0
report:
  enable: true      # reserved in v0
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
