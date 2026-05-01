import os
import sys

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
if SCRIPT_DIR not in sys.path:
    sys.path.insert(0, SCRIPT_DIR)

from vitis_common import (
    close_client,
    copy_if_needed,
    create_client,
    ensure_platform_domain,
    fail_result,
    get_component,
    load_plan,
    parse_plan_args,
    workspace_platform_xpfm,
    write_result,
)


def platform_export_has_bsp_artifacts(xpfm_path, plan):
    if not xpfm_path:
        return False
    platform = plan.get("platform", {}) or {}
    domain = platform.get("domainName", "")
    if not domain:
        return False
    export_root = os.path.dirname(os.path.abspath(xpfm_path))
    required = [
        os.path.join(export_root, "sw", domain, "lib", "libxil.a"),
        os.path.join(export_root, "sw", domain, "lib", "libxilstandalone.a"),
    ]
    return all(os.path.isfile(path) for path in required)


def main():
    args = parse_plan_args(sys.argv[1:])
    plan = load_plan(args["plan"])
    client = None
    try:
        platform = plan.get("platform", {}) or {}
        configured_xpfm = platform.get("xpfm", "")
        workspace_xpfm = workspace_platform_xpfm(plan)
        expected = configured_xpfm or workspace_xpfm
        existing_xpfm = expected if expected and os.path.isfile(expected) else ""
        if not existing_xpfm and workspace_xpfm and os.path.isfile(workspace_xpfm):
            copied = copy_if_needed(workspace_xpfm, configured_xpfm)
            existing_xpfm = configured_xpfm or workspace_xpfm
        if existing_xpfm and platform_export_has_bsp_artifacts(existing_xpfm, plan):
            write_result(
                args["result"],
                plan,
                "ok",
                outputs={
                    "workspaceXpfm": workspace_xpfm,
                    "xpfm": existing_xpfm,
                    "copiedXpfm": "" if existing_xpfm == expected else copied,
                    "reusedExistingExport": True,
                },
            )
            return 0

        client = create_client(plan)
        warnings = []
        component = get_component(client, platform.get("name", ""))
        ensure_platform_domain(component, plan, warnings)
        component.build()

        copied = copy_if_needed(workspace_xpfm, configured_xpfm)
        if expected and not os.path.isfile(expected):
            raise RuntimeError(f"Platform build finished, but expected XPFM was not found: {expected}")

        write_result(
            args["result"],
            plan,
            "ok",
            outputs={
                "workspaceXpfm": workspace_xpfm,
                "xpfm": expected,
                "copiedXpfm": copied,
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
