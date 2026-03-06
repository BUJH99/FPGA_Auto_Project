# Report BAT Guide

## Status
- One Source report automation scripts were removed from this repository:
  - `report_hdl_info_annotate.bat`
  - `report_waveform_folders_prepare.bat`
  - `report_markdown_generate.bat`
  - `report_markdown_to_docx.bat`

## Current Alternatives
- Use legacy report/documentation scripts if needed:
  - Canonical: `templates\contexts\reporting\adapters\bat\report_generate_legacy_html.bat`
  - Canonical: `templates\contexts\reporting\adapters\bat\report_generate_docs.bat`
- Use simulation/build outputs directly under each project:
  - `output/`
  - `log/`
