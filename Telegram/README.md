# Telegram FPGA Bot

This folder is the single source of truth for the Telegram chatbot integration.

## Files

- `telegram_fpga_bot.py`: Telegram long-polling bot for `MAIN.bat` menu actions.
- `telegram_fpga_bot_run.bat`: Windows launcher.
- `telegram_fpga_bot.env.example`: environment template.

## Setup

1. Copy `telegram_fpga_bot.env.example` to `telegram_fpga_bot.env`.
2. Fill `TELEGRAM_BOT_TOKEN`.
3. Fill either `TELEGRAM_ALLOWED_USER_IDS` or `TELEGRAM_ALLOWED_USERNAMES`.
4. By default the bot resolves the secret file relative to the repo layout: `..\FPGA_AGENT_TOKEN\TELEGRAMTOKEN_ID.txt` from the bot repo root.
5. For backward compatibility, it also checks `..\MOBILE_AGENT_TOKEN\TELEGRAMTOKEN_ID.txt` if the new folder is not present.
6. Optionally set `TELEGRAM_SECRET_FILE` if you want to override that path.

## Run

```bat
Telegram\telegram_fpga_bot_run.bat
```

- The Windows launcher accepts `py -3`, `python`, or `python3`.

## Supported commands

- `/help`
- `/projects`
- `/status`
- `/last`
- `/task <menu_no> <project> [args...]`
- `/setup_project <name> [v|sv]`
- `/build <project>`
- `/build_program <project>`
- `/program <project>`
- `/doctor <project>`
- `/schematic <project> <modules>`
- `/hierarchy <project> [src|tb]`
- `/fsm <project> <modules>`
- `/presentation <project> [clean_assets]`
- `/sim_vivado <project> <folder_idx> <tb_idx>`
- `/sim_auto_report <project> <tb_idx>`
- `/sim_iverilog <project> (--all | --tb <name>)`
- `/vcd_svg <project>`
- `/vcd_wavedrom <project> [--step N] [--max-signals N] [--html|--no-html]`
- `/report_html <project>`
- `/report_docs <project>`
- `/vivado_gui <project>`
- `/finalize_bd <project>`
- `/retarget_ip <project>`
- `/open_presentation <project>`
- `/tb_scaffold <project> (--all | --dut <name>) [--force]`

## Notes

- The bot derives its executable menu map from `MAIN.bat`.
- Menu 5 and menu 6 buttons are built from manifest-resolved TB files instead of hardcoded folder or index assumptions.
- `/doctor` runs the existing Toolkit Doctor flow and summarizes `output/doctor_summary.json`.
- Runtime execution is intended for Windows because the automation stack depends on `cmd.exe`, PowerShell, and Vivado tooling.
