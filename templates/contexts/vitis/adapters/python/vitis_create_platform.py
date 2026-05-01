import os
import sys

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
if SCRIPT_DIR not in sys.path:
    sys.path.insert(0, SCRIPT_DIR)

from vitis_common import (
    close_client,
    create_client,
    ensure_platform_domain,
    fail_result,
    load_plan,
    parse_plan_args,
    write_result,
)


def main():
    args = parse_plan_args(sys.argv[1:])
    plan = load_plan(args["plan"])
    client = None
    try:
        client = create_client(plan)
        platform = plan.get("platform", {}) or {}
        xsa = plan.get("xsa", {}) or {}
        if not os.path.isfile(xsa.get("path", "")):
            raise RuntimeError(f"XSA not found: {xsa.get('path', '')}")

        kwargs = {
            "name": platform.get("name", "platform"),
            "hw_design": xsa.get("path", ""),
        }
        cpu = str(platform.get("cpu", "auto") or "auto")
        if cpu.lower() != "auto":
            kwargs.update({
                "cpu": cpu,
                "os": platform.get("os", "standalone"),
                "domain_name": platform.get("domainName", "standalone_domain"),
            })

        component = client.create_platform_component(**kwargs)
        warnings = []
        ensure_platform_domain(component, plan, warnings)
        outputs = {
            "workspace": plan.get("workspace", ""),
            "platformName": platform.get("name", ""),
            "xpfm": platform.get("xpfm", ""),
        }
        write_result(args["result"], plan, "ok", outputs=outputs, warnings=warnings, details={"component": str(component)})
        return 0
    except Exception as exc:
        return fail_result(args["result"], plan, exc)
    finally:
        close_client(client)


if __name__ == "__main__":
    sys.exit(main())
