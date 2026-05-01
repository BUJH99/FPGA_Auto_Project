import os
import sys
from collections import defaultdict
import json

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
if SCRIPT_DIR not in sys.path:
    sys.path.insert(0, SCRIPT_DIR)

from vitis_common import (
    close_client,
    create_client,
    ensure_platform_domain,
    expand_source_files,
    fail_result,
    get_component,
    load_plan,
    parse_plan_args,
    write_result,
)


def ensure_platform_xpfm(client, plan, platform, warnings):
    xpfm = platform.get("xpfm", "")
    if os.path.isfile(xpfm):
        return xpfm

    platform_name = platform.get("name", "")
    selected = platform.get("selected", {}) or {}
    component_dir = selected.get("componentDir", "")
    if not platform_name:
        raise RuntimeError(f"Platform XPFM not found: {xpfm}")

    warnings.append(f"platform_xpfm_missing_auto_build:{platform_name}")
    if component_dir and not os.path.isdir(component_dir):
        warnings.append(f"selected_platform_component_dir_missing:{component_dir}")

    component = get_component(client, platform_name)
    ensure_platform_domain(component, plan, warnings)
    build = getattr(component, "build", None)
    if not callable(build):
        raise RuntimeError(
            f"Selected platform '{platform_name}' has no exported XPFM and cannot be built by this Vitis API."
        )
    build()
    if os.path.isfile(xpfm):
        return xpfm
    raise RuntimeError(
        f"Selected platform build finished, but expected XPFM was not found: {xpfm}"
    )


def try_set_config(component, key, values, warnings):
    method = getattr(component, "set_app_config", None)
    if not callable(method):
        warnings.append(f"set_app_config_unavailable:{key}")
        return
    try:
        method(key=key, values=values)
    except TypeError:
        try:
            method(key, values)
        except Exception as exc:
            warnings.append(f"set_app_config_failed:{key}:{exc}")
    except Exception as exc:
        warnings.append(f"set_app_config_failed:{key}:{exc}")


def import_sources(component, source_files, warnings):
    method = getattr(component, "import_files", None)
    if not callable(method):
        warnings.append("import_files_unavailable")
        return 0

    grouped = defaultdict(list)
    for file_path in source_files:
        grouped[os.path.dirname(file_path)].append(os.path.basename(file_path))

    imported = 0
    for directory, names in grouped.items():
        method(from_loc=directory, files=sorted(names), dest_dir_in_cmp="src")
        imported += len(names)
    return imported


def read_workspace_app_platform(workspace, app_name):
    component_json = os.path.join(workspace or "", app_name or "", "vitis-comp.json")
    try:
        with open(component_json, "r", encoding="utf-8") as handle:
            payload = json.load(handle)
    except Exception:
        return ""
    return str(payload.get("platform", "") or "")


def main():
    args = parse_plan_args(sys.argv[1:])
    plan = load_plan(args["plan"])
    client = None
    try:
        client = create_client(plan)
        selected_apps = plan.get("selectedApplications", []) or []
        if not selected_apps:
            selected_apps = [plan.get("application", {}) or {}]
        platform = plan.get("platform", {}) or {}

        warnings = []
        xpfm = ensure_platform_xpfm(client, plan, platform, warnings)
        outputs = []
        for app in selected_apps:
            kwargs = {
                "name": app.get("name", "app"),
                "platform": xpfm,
                "template": app.get("template", "empty_application"),
            }
            domain = app.get("domain", "")
            if domain:
                kwargs["domain"] = domain
            try:
                component = client.create_app_component(**kwargs)
            except TypeError:
                kwargs.pop("domain", None)
                component = client.create_app_component(**kwargs)
            except Exception as exc:
                if "already exists" not in str(exc).lower():
                    raise
                component = get_component(client, app.get("name", "app"))

            existing_platform = read_workspace_app_platform(plan.get("workspace", ""), app.get("name", ""))
            if existing_platform and existing_platform != platform.get("name", ""):
                raise RuntimeError(
                    f"Application '{app.get('name', '')}' already exists for platform "
                    f"'{existing_platform}', not selected platform '{platform.get('name', '')}'. "
                    "Use a unique application name or remove the generated application component."
                )

            source_files = expand_source_files(app)
            imported_count = import_sources(component, source_files, warnings)
            includes = [path for path in app.get("includes", []) or [] if os.path.isdir(path)]
            if includes and imported_count > 0:
                try_set_config(component, "USER_INCLUDE_DIRECTORIES", includes, warnings)
            linker_script = app.get("linkerScript", "")
            if linker_script:
                try_set_config(component, "USER_LINKER_SCRIPT", linker_script, warnings)
            outputs.append({
                "applicationName": app.get("name", ""),
                "importedSourceCount": imported_count,
            })

        write_result(
            args["result"],
            plan,
            "ok",
            outputs={
                "applicationNames": [item["applicationName"] for item in outputs],
                "applications": outputs,
                "workspace": plan.get("workspace", ""),
                "platformName": platform.get("name", ""),
                "platformXpfm": xpfm,
            },
            warnings=warnings,
        )
        return 0
    except Exception as exc:
        return fail_result(args["result"], plan, exc)
    finally:
        close_client(client)


if __name__ == "__main__":
    sys.exit(main())
