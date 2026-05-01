# Vitis Automation Expansion Plan

## Goal

Add a Vitis software automation layer to FPGA_AUTO while preserving the existing
hardware project contract:

- Vivado automation remains Tcl-based.
- Vitis automation uses the Vitis Python CLI.
- `MAIN.bat` remains the user-facing menu contract.
- Managed projects remain under sibling `../Project/*`.
- Project HDL layout stays stable: existing `src/`, `tb`, includes, and constraints
  are not moved.

The target flow is:

1. Export XSA from an existing Vivado bitstream/run.
2. Create a Vitis platform from XSA.
3. Create a Vitis application from the platform.
4. Build the platform.
5. Build the application.
6. Run the application.
7. Optionally run the full flow end to end.

XSA export intentionally does not synthesize, implement, or generate a bitstream.
That work belongs to the Vivado hardware automation. The Vitis XSA step selects a
completed `.bit`, opens the Vivado `.xpr` and implementation run that produced it,
then runs `write_hw_platform -include_bit` against the opened run. A raw `.bit`
without its Vivado project/run context is not enough for this path.

Generated XSA filenames keep the full `YYYYMMDD_HHMMSS` timestamp. Generated
platform names use a compact `MMDD_HHMMSS` suffix to reduce Windows/MicroBlaze
BSP path length risk while still avoiding accidental overwrites.

## Current Baseline

- Framework code lives in this repo:
  - `MAIN.bat`
  - `templates/contexts/*`
  - `templates/shared/*`
  - `Telegram/*`
  - `tests/*`
- Managed project workspaces live under sibling `../Project/*`.
- Valid projects must contain:
  - `src/`
  - `fpga_auto.yml`
- `fpga_auto.yml` is the project contract.
- Generated output is evidence or artifact, not primary source.

## Project Folder Extension

Each managed project should grow software input folders without disturbing the
existing HDL folders.

```text
../Project/<name>/
  fpga_auto.yml

  src/                 # Existing RTL source
  tb/                  # Existing testbench source
  include/             # Existing RTL/SV includes
  inc/                 # Existing alternate include root
  constrs/             # Existing XDC constraints

  sw/
    common/
      include/
      src/
    apps/
      <app_name>/
        src/
        include/
        data/
        lscript.ld     # Optional app linker script
        app.yml        # Optional app-local override

  vitis/
    launch/
      hardware.json    # Optional run/debug target settings
    bsp_overrides/     # Optional BSP/domain customization inputs

  output/
    vitis/
      xsa/
      workspace/
      platform/
      apps/
      summaries/

  log/
    vitis/
```

Folder ownership:

| Folder | Owner | Rule |
|---|---|---|
| `src/` | HDL source | Existing RTL rules apply. |
| `tb/` | HDL verification | Existing TB rules apply. |
| `include/`, `inc/` | HDL includes | Use according to the consumer: RTL or TB. |
| `constrs/` | Vivado constraints | Included by manifest XDC globs. |
| `sw/apps/*` | Vitis application source | Human-managed source. |
| `sw/common/*` | Shared application code | Human-managed source. |
| `vitis/*` | Vitis config overrides | Human-managed Vitis inputs. |
| `output/vitis/*` | Generated artifacts | Regenerable output. |
| `log/vitis/*` | Runtime logs | Evidence only. |

Do not treat `.xsa`, `.xpfm`, Vitis workspaces, generated BSPs, or compiled
application products as primary source.

## Manifest Extension

Add an optional `vitis` section to `fpga_auto.yml`. The manifest validator should
shape-check this section and Toolkit Doctor should surface warnings, but existing
HDL-only projects must remain valid.

```yaml
vitis:
  workspace: "output/vitis/workspace"

  xsa:
    path: "output/vitis/xsa/${project.name}.xsa"
    bit_path: ""
    bit_globs:
      - "output/*.bit"
      - "output/vivado/**/*.runs/impl_1/*.bit"
      - "output/vivado/**/*.runs/*/*.bit"
    vivado_project: ""
    impl_run: "impl_1"
    include_bitstream: true
    fixed: true
    validate: true

  platform:
    name: "${project.name}_platform"
    xpfm: "output/vitis/workspace/${platform.name}/export/${platform.name}/${platform.name}.xpfm"
    os: "standalone"
    cpu: "auto"
    domain_name: "standalone_domain"

  applications:
    - name: "hello_world"
      template: "empty_application"
      domain: "standalone_domain"
      sources:
        - "sw/apps/hello_world/src/**/*"
        - "sw/common/src/**/*"
      includes:
        - "sw/apps/hello_world/include"
        - "sw/common/include"
      linker_script: "sw/apps/hello_world/lscript.ld"
      target: "hw"

  run:
    mode: "hardware"
    hw_server: "localhost:3121"
    device_index: 1
```

Initial validator rules:

- `vitis.workspace`: optional non-empty string.
- `vitis.xsa.path`: optional non-empty string.
- `vitis.xsa.bit_path`: optional string. When set, this bitstream is preferred.
- `vitis.xsa.bit_globs`: optional string array for bitstream discovery.
- `vitis.xsa.vivado_project`: optional string. Required when it cannot be inferred
  by walking up from the selected bitstream.
- `vitis.xsa.impl_run`: optional non-empty string, default `impl_1`.
- `vitis.xsa.include_bitstream`: optional boolean.
- `vitis.xsa.fixed`: optional boolean.
- `vitis.xsa.validate`: optional boolean.
- `vitis.platform.name`: optional non-empty string.
- `vitis.platform.xpfm`: optional non-empty string.
- `vitis.platform.os`: optional non-empty string.
- `vitis.platform.cpu`: optional non-empty string. Allow `auto`.
- `vitis.platform.domain_name`: optional non-empty string.
- `vitis.applications`: optional array of application objects.
- Application `sources` and `includes`: optional string arrays.
- Application `target`: optional non-empty string, default `hw`.
- `vitis.run`: optional object; validate only shape in the first pass.

Do not resolve software globs through the existing HDL resolver at first. Keep HDL
file resolution and Vitis software file resolution separate.

## Framework Folder Structure

Create a dedicated Vitis context:

```text
templates/contexts/vitis/
  adapters/
    bat/
      vitis_export_xsa.bat
      vitis_create_platform.bat
      vitis_create_application.bat
      vitis_build_platform.bat
      vitis_build_application.bat
      vitis_run_application.bat
      vitis_run_full_flow.bat
    tcl/
      vivado_export_xsa.tcl
      vivado_validate_xsa.tcl
    python/
      vitis_common.py
      vitis_create_platform.py
      vitis_create_application.py
      vitis_build_platform.py
      vitis_build_application.py
      vitis_run_application.py
    cli/
      vitis_plan_cli.js
      vitis_summary_cli.js
  application/
    vitis_plan_service.js
    vitis_summary_service.js
  domain/
    vitis_contracts.js
    vitis_defaults.js
```

Add shared tool discovery:

```text
templates/shared/adapters/bat/
  ensure_vitis_on_path.bat
```

Rationale:

- BAT files remain Windows-first entrypoints.
- Tcl files own Vivado/XSA actions.
- Python files own Vitis Python CLI actions.
- Node CLI/application/domain files own manifest-derived planning and summary JSON.
- Shared helper discovers the Vitis executable without coupling it to Vivado.

## Tool Responsibility Boundary

| Step | Tool | Driver | Notes |
|---|---|---|---|
| Export XSA | Vivado | Tcl launched by BAT | Open existing `.xpr`/implementation run from selected `.bit`; use `write_hw_platform`; never synthesize, implement, launch runs, or write a new bitstream. |
| Validate XSA | Vivado | Tcl launched by BAT | Use `validate_hw_platform` when enabled. |
| Create platform | Vitis | Python CLI launched by BAT | Use `vitis -s` or equivalent source option. |
| Build platform | Vitis | Python CLI launched by BAT | Use platform component `build()`. |
| Create app | Vitis | Python CLI launched by BAT | Use `create_app_component`. |
| Build app | Vitis | Python CLI launched by BAT | Use app component `build(target="hw")` by default. |
| Run app | Vitis/XSDB | Python CLI launched by BAT | Requires explicit or discovered hardware target. |

## Menu Expansion

Add a new `Vitis Software Flow` section after the current menu 21:

```text
22. Export XSA from existing bitstream
23. Create Vitis Platform from XSA
24. Create Vitis Application Component from Platform
25. Build Vitis Platform
26. Build Vitis Application
27. Run Vitis Application
28. Full Vitis Flow
```

Planned mappings:

```bat
set "CMD_22=contexts\vitis\adapters\bat\vitis_export_xsa.bat"
set "CMD_23=contexts\vitis\adapters\bat\vitis_create_platform.bat"
set "CMD_24=contexts\vitis\adapters\bat\vitis_create_application.bat"
set "CMD_25=contexts\vitis\adapters\bat\vitis_build_platform.bat"
set "CMD_26=contexts\vitis\adapters\bat\vitis_build_application.bat"
set "CMD_27=contexts\vitis\adapters\bat\vitis_run_application.bat"
set "CMD_28=contexts\vitis\adapters\bat\vitis_run_full_flow.bat"
```

Every project BAT receives the absolute project path as argument 1, matching the
current `MAIN.bat` contract.

## BAT Contracts

All Vitis BAT entrypoints should:

1. Resolve `TEMPLATES_ROOT`.
2. Load `console_ui.bat`.
3. Validate `%~1` target project path.
4. Call `bootstrap_manifest_context.bat`.
5. Call `ensure_vitis_on_path.bat` or `ensure_vivado_on_path.bat` as needed.
6. Call `vitis_plan_cli.js` to resolve paths and defaults.
7. Run one tool action.
8. Write a summary JSON through `vitis_summary_cli.js`.
9. Exit non-zero on failed required steps.

State-changing flows must not be parallelized.

## Flow Details

### 1. Export XSA

Entrypoint:

- `templates/contexts/vitis/adapters/bat/vitis_export_xsa.bat`

Internal flow:

1. Load manifest.
2. Discover/select an existing `.bit` from `vitis.xsa.bit_path` or `vitis.xsa.bit_globs`.
3. Ensure Vivado is available.
4. Prepare XSA plan with a timestamped output filename.
5. Run `vivado_export_xsa.tcl`.
6. Optionally run `vivado_validate_xsa.tcl`.
7. Write `output/vitis/summaries/xsa_export_summary.json`.

Tcl behavior:

- Open the Vivado `.xpr` and implementation run associated with the selected bitstream.
- Use `write_hw_platform -force` against a timestamped XSA filename so prior exports remain intact.
- Add `-include_bit` when `vitis.xsa.include_bitstream` is true.
- Add `-fixed` when `vitis.xsa.fixed` is true.
- Keep output under `output/vitis/xsa/`.
- Do not call `synth_design`, `launch_runs`, implementation commands, or `write_bitstream`.

### 2. Create Platform

Entrypoint:

- `templates/contexts/vitis/adapters/bat/vitis_create_platform.bat`

Python CLI behavior:

- Create Vitis client.
- Set workspace to `vitis.workspace`.
- Let the caller select an existing XSA, defaulting to the latest export when running non-interactively.
- Create a timestamped platform component name so prior platforms remain intact.
- Use bare-metal defaults when OS/domain are not provided.
- Add domain if the selected Vitis API requires a separate domain step.
- Write `output/vitis/summaries/platform_create_summary.json`.

### 3. Create Application

Entrypoint:

- `templates/contexts/vitis/adapters/bat/vitis_create_application.bat`

Python CLI behavior:

- Resolve platform `.xpfm` from the selected platform, defaulting to the latest platform component when running non-interactively.
- If the selected platform component exists but its `.xpfm` export is missing, build the platform component before creating the application component.
- Ask for a new application component name in the interactive BAT flow.
- Accept `--app <name>` for a new application name; manifest-backed app settings are reused when the name exists in `vitis.applications`.
- Create app component from platform, domain, and template.
- Import source files from `sw/apps/<app>/src` and shared `sw/common/src`.
- Apply includes and linker script if configured.
- Write `output/vitis/summaries/app_create_summary.json`.

### 4. Build Platform

Entrypoint:

- `templates/contexts/vitis/adapters/bat/vitis_build_platform.bat`

Python CLI behavior:

- Open or locate platform component in workspace.
- Run component `build()`.
- Verify expected `.xpfm`.
- Write `output/vitis/summaries/platform_build_summary.json`.

### 5. Build Application

Entrypoint:

- `templates/contexts/vitis/adapters/bat/vitis_build_application.bat`

Python CLI behavior:

- Open or locate app component in workspace.
- Run `build(target=<target>)`, default `hw`.
- Verify `workspace/<app>/build/<target>` exists.
- Write `output/vitis/summaries/app_build_summary.json`.

### 6. Run Application

Entrypoint:

- `templates/contexts/vitis/adapters/bat/vitis_run_application.bat`

Initial policy:

- Require explicit run config or a successful target discovery summary.
- Do not silently pick a board if multiple candidates exist.
- Support hardware run first; QEMU/emulation can be a later extension.
- Write `output/vitis/summaries/app_run_summary.json`.

Run may require launch configuration, XSDB commands, or Vitis run/debug APIs
depending on the installed Vitis version. The implementation must check the local
Vitis CLI/API surface before hard-coding a run method.

### 7. Full Flow

Entrypoint:

- `templates/contexts/vitis/adapters/bat/vitis_run_full_flow.bat`

Full flow order:

1. Export XSA.
2. Create platform.
3. Build platform.
4. Create application.
5. Build application.
6. Optionally run application when `--run` is passed or `vitis.run.auto: true`.

Do not run the final hardware step by default.

## Summary Contracts

Each Vitis step writes a structured JSON summary under:

```text
../Project/<name>/output/vitis/summaries/
```

Recommended common fields:

```json
{
  "schemaVersion": 1,
  "tool": "vitis",
  "step": "platform_build",
  "projectRoot": "...",
  "status": "ok",
  "startedAt": "...",
  "finishedAt": "...",
  "inputs": {},
  "outputs": {},
  "warnings": [],
  "errors": []
}
```

Toolkit Doctor and Telegram collectors should prefer these summaries over raw logs.

## Toolkit Doctor Extension

Add checks:

- Vitis executable found.
- Vitis version captured.
- `vitis.workspace` parent writable.
- XSA exists when platform/app/build steps need it.
- Platform `.xpfm` exists when app steps need it.
- Application source globs match at least one file.
- Run config is complete before hardware run.

Missing Vitis should be a warning for HDL-only projects and an error only when a
Vitis action is requested.

## Telegram Extension

Required changes:

- Extend `/task` menu range from `1~21` to `1~28`.
- Add `MENU_USAGE` entries for 22 through 28.
- Let direct no-extra-token flows run for 22, 23, 25, 26, and 28.
- Allow menu 24 and 27 to accept app name or run target options later.
- Add result collector aliases for Vitis summary JSON.
- Add help text for Vitis flows.

Keep Telegram behavior generated from `MAIN.bat` mappings where possible.

## Test Plan

Add focused tests before real tool execution:

- Manifest shape tests:
  - valid `vitis` section
  - bad scalar/array/boolean fields
  - missing optional Vitis section remains OK
- BAT template tests:
  - every Vitis BAT calls manifest bootstrap
  - XSA export BAT calls Vivado helper and accepts bitstream selection
  - XSA export Tcl opens an existing run and does not synthesize, implement, launch runs, or write a bitstream
  - Vitis BATs call Vitis helper
  - all Vitis BATs write summaries
- Planner tests:
  - default paths resolve under `output/vitis`
  - XSA export selects discovered bitstreams and infers `.xpr`/implementation run
  - app source globs are project-relative
  - app selection fails clearly when ambiguous
- Telegram tests:
  - menu registry covers 22 through 28
  - `/task 22 <project> --bit latest` resolves to XSA export with bit selection
  - `/task 28 <project>` resolves to full flow
- Summary collector tests:
  - Vitis summaries are preferred over raw logs
  - failed summaries produce actionable triage text

Tool-backed validation on Windows:

- `vitis -version`
- `vivado -mode batch -source vivado_validate_xsa.tcl`
- `vitis -s <generated script>`

## Implementation Order

1. Add docs and manifest schema extension.
2. Add `ensure_vitis_on_path.bat`.
3. Add Vitis context skeleton and summary/plan CLIs.
4. Add XSA export and validation.
5. Add platform create/build.
6. Add application create/build.
7. Add run application.
8. Add full-flow wrapper.
9. Extend `MAIN.bat`.
10. Extend Telegram routing and collectors.
11. Add tests and update runner skill reference menu map.

## Open Decisions

- Default CPU/domain auto-discovery strategy for Zynq, ZynqMP, Versal, and MicroBlaze.
- Whether application `app.yml` overrides should be supported in the first implementation.
- Whether hardware run should use Vitis launch configuration APIs, Python XSDB, or generated launch files for the installed Vitis version.
- Whether Linux/PetaLinux domains are in scope for the first pass or deferred after bare-metal standalone support.

## Reference Sources

- Vitis Python script execution: <https://docs.amd.com/r/en-US/ug1702-vitis-accelerated-reference/Launching-Vitis-Unified-IDE>
- Vitis platform component Python API: <https://docs.amd.com/r/en-US/ug1702-vitis-accelerated-reference/Create-and-Build-Platform-Component>
- Vitis application component Python API: <https://docs.amd.com/r/en-US/ug1702-vitis-accelerated-reference/Create-and-Build-Application-Component>
- Vivado XSA export command: <https://docs.amd.com/r/2021.2-English/ug835-vivado-tcl-commands/write_hw_platform>
- Vivado XSA validation command: <https://docs.amd.com/r/2024.1-English/ug835-vivado-tcl-commands/validate_hw_platform>
