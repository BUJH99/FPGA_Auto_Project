import glob
import os
import sys

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
if SCRIPT_DIR not in sys.path:
    sys.path.insert(0, SCRIPT_DIR)

from vitis_common import close_client, create_client, fail_result, get_component, load_plan, parse_plan_args, workspace_app_build_dir, write_result


def main():
    args = parse_plan_args(sys.argv[1:])
    plan = load_plan(args["plan"])
    client = None
    try:
        client = create_client(plan)
        selected_apps = plan.get("selectedApplications", []) or []
        if not selected_apps:
            selected_apps = [plan.get("application", {}) or {}]
        app_outputs = []
        for app in selected_apps:
            component = get_component(client, app.get("name", ""))
            target = app.get("target", "hw")
            component.build(target=target)
            app_plan = dict(plan)
            app_plan["application"] = app
            build_dir = workspace_app_build_dir(app_plan)
            fallback_build_dir = os.path.join(plan.get("workspace", ""), app.get("name", ""), "build")
            actual_build_dir = build_dir if build_dir and os.path.isdir(build_dir) else fallback_build_dir
            if actual_build_dir and not os.path.isdir(actual_build_dir):
                raise RuntimeError(
                    "Application build finished, but expected build directory was not found: "
                    f"{build_dir or fallback_build_dir}"
                )
            elf_files = sorted(glob.glob(os.path.join(actual_build_dir, "*.elf"))) if actual_build_dir else []
            app_outputs.append({
                "applicationName": app.get("name", ""),
                "buildDir": actual_build_dir,
                "target": target,
                "elfFiles": elf_files,
            })
        write_result(
            args["result"],
            plan,
            "ok",
            outputs={
                "applications": app_outputs,
                "applicationNames": [item["applicationName"] for item in app_outputs],
            },
        )
        return 0
    except Exception as exc:
        return fail_result(args["result"], plan, exc)
    finally:
        close_client(client)


if __name__ == "__main__":
    sys.exit(main())
