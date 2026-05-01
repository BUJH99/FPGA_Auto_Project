import inspect
import os
import sys

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
if SCRIPT_DIR not in sys.path:
    sys.path.insert(0, SCRIPT_DIR)

from vitis_common import close_client, create_client, fail_result, get_component, load_plan, method_names, parse_plan_args, write_result


def call_runtime_method(component, plan):
    app = plan.get("application", {}) or {}
    run = plan.get("run", {}) or {}
    candidate_names = ("run", "launch", "debug", "launch_run", "run_application")
    kwargs = {
        "target": app.get("target", "hw"),
        "hw_server": run.get("hwServer", ""),
        "device_index": run.get("deviceIndex", None),
    }
    for name in candidate_names:
        method = getattr(component, name, None)
        if not callable(method):
            continue
        try:
            signature = inspect.signature(method)
            filtered = {key: value for key, value in kwargs.items() if key in signature.parameters and value not in ("", None)}
            return name, method(**filtered)
        except (TypeError, ValueError):
            try:
                return name, method()
            except TypeError:
                continue
    raise RuntimeError(
        "No supported Vitis run/debug method was found on the application component. "
        "Available component methods: " + ", ".join(method_names(component)[:80])
    )


def main():
    args = parse_plan_args(sys.argv[1:])
    plan = load_plan(args["plan"])
    client = None
    try:
        run = plan.get("run", {}) or {}
        if str(run.get("mode", "hardware")).lower() != "hardware":
            raise RuntimeError("Only hardware Vitis application run mode is supported in this first pass.")
        if not run.get("hwServer") or run.get("deviceIndex") is None:
            raise RuntimeError("Hardware run requires vitis.run.hw_server and vitis.run.device_index.")

        client = create_client(plan)
        app = plan.get("application", {}) or {}
        component = get_component(client, app.get("name", ""))
        method_name, call_result = call_runtime_method(component, plan)
        write_result(
            args["result"],
            plan,
            "ok",
            outputs={"runMode": "hardware", "method": method_name},
            details={"callResult": str(call_result)},
        )
        return 0
    except Exception as exc:
        return fail_result(args["result"], plan, exc)
    finally:
        close_client(client)


if __name__ == "__main__":
    sys.exit(main())
