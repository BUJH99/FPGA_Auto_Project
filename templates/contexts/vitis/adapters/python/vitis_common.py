import datetime
import glob
import json
import os
import shutil
import subprocess
import sys
import traceback

_SUBST_DRIVES = []
_ACTIVE_WORKSPACE = ""
_ACTIVE_SERVER_PID = None


def iso_now():
    return datetime.datetime.now(datetime.timezone.utc).isoformat().replace("+00:00", "Z")


def normalize_slashes(value):
    return str(value or "").replace("\\", "/")


def parse_plan_args(argv):
    out = {"plan": "", "result": ""}
    args = list(argv)
    if args and args[0] == "--":
      args = args[1:]
    i = 0
    while i < len(args):
        arg = args[i]
        if arg == "--plan":
            i += 1
            out["plan"] = args[i] if i < len(args) else ""
        elif arg.startswith("--plan="):
            out["plan"] = arg.split("=", 1)[1]
        elif arg == "--result":
            i += 1
            out["result"] = args[i] if i < len(args) else ""
        elif arg.startswith("--result="):
            out["result"] = arg.split("=", 1)[1]
        i += 1
    if not out["plan"]:
        raise RuntimeError("--plan is required")
    return out


def load_plan(plan_path):
    with open(plan_path, "r", encoding="utf-8") as handle:
        return json.load(handle)


def ensure_dir(path):
    if path:
        os.makedirs(path, exist_ok=True)


def write_json(path, payload):
    ensure_dir(os.path.dirname(os.path.abspath(path)))
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(payload, handle, indent=2)
        handle.write("\n")
    return normalize_slashes(os.path.abspath(path))


def write_result(path, plan, status, outputs=None, warnings=None, errors=None, details=None):
    payload = {
        "schemaVersion": 1,
        "type": "vitis_result",
        "tool": "vitis",
        "step": plan.get("step", ""),
        "projectRoot": normalize_slashes(plan.get("projectRoot", "")),
        "status": status,
        "generatedAt": iso_now(),
        "outputs": outputs or {},
        "warnings": warnings or [],
        "errors": errors or [],
        "details": details or {},
    }
    write_json(path, payload)
    return payload


def fail_result(result_path, plan, exc):
    message = str(exc)
    details = {
        "exception": exc.__class__.__name__,
        "traceback": traceback.format_exc().splitlines()[-20:],
    }
    write_result(result_path, plan, "failed", errors=[message], details=details)
    print("[ERROR] " + message)
    return 1


def import_vitis_module():
    try:
        import vitis  # type: ignore
        return vitis
    except Exception as exc:
        raise RuntimeError(
            "Unable to import the Vitis Python CLI module. Run this script through 'vitis -s', "
            "not a stock Python interpreter."
        ) from exc


def create_client(plan):
    global _ACTIVE_SERVER_PID, _ACTIVE_WORKSPACE
    vitis = import_vitis_module()
    client = vitis.create_client()
    server = getattr(client, "_serverObj", None)
    process = getattr(server, "cp", None)
    _ACTIVE_SERVER_PID = getattr(process, "pid", None)
    workspace = plan.get("workspace", "")
    if workspace:
        ensure_dir(workspace)
        _ACTIVE_WORKSPACE = os.path.abspath(workspace)
        workspace = maybe_subst_windows_workspace(plan, workspace)
        try:
            client.set_workspace(path=workspace)
        except Exception:
            close_client(client)
            raise
    return client


def path_is_inside(child, parent):
    try:
        return os.path.commonpath([os.path.abspath(child), os.path.abspath(parent)]) == os.path.abspath(parent)
    except Exception:
        return False


def maybe_subst_windows_workspace(plan, workspace):
    if os.name != "nt":
        return workspace
    if str(os.environ.get("FPGA_AUTO_VITIS_SUBST", "")).lower() in ("0", "false", "no", "off"):
        return workspace

    workspace_abs = os.path.abspath(workspace)
    min_len = int(os.environ.get("FPGA_AUTO_VITIS_SUBST_MIN_LEN", "50") or "50")
    if len(workspace_abs) < min_len:
        return workspace

    project_root = os.path.abspath(plan.get("projectRoot", "") or "")
    if project_root and os.path.isdir(project_root) and path_is_inside(workspace_abs, project_root):
        subst_target = project_root
        subst_rel = os.path.relpath(workspace_abs, project_root)
    else:
        subst_target = workspace_abs
        subst_rel = ""

    drive_letters = os.environ.get("FPGA_AUTO_VITIS_SUBST_DRIVES", "V U T S R Q P").split()
    for letter in drive_letters:
        drive = f"{str(letter).strip().upper().rstrip(':')}:"
        if not drive or os.path.exists(drive + "\\"):
            continue
        try:
            subprocess.run(
                ["subst", drive, subst_target],
                check=True,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
        except Exception:
            continue
        _SUBST_DRIVES.append(drive)
        short_workspace = drive + "\\"
        if subst_rel and subst_rel != ".":
            short_workspace = os.path.join(short_workspace, subst_rel)
        print(f"[INFO] Using short Vitis workspace path: {short_workspace}")
        return short_workspace
    return workspace


def release_subst_drives():
    while _SUBST_DRIVES:
        drive = _SUBST_DRIVES.pop()
        try:
            subprocess.run(
                ["subst", drive, "/D"],
                check=False,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
        except Exception:
            pass


def taskkill_windows_process_tree(pid):
    if os.name != "nt" or not pid:
        return False
    try:
        result = subprocess.run(
            ["taskkill", "/PID", str(pid), "/T", "/F"],
            check=False,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        return result.returncode == 0
    except Exception:
        return False


def remove_active_workspace_lock():
    global _ACTIVE_SERVER_PID, _ACTIVE_WORKSPACE
    try:
        if _ACTIVE_SERVER_PID and _ACTIVE_WORKSPACE:
            lock_path = os.path.join(_ACTIVE_WORKSPACE, "_ide", ".wsdata", ".lock")
            if os.path.isfile(lock_path):
                os.remove(lock_path)
    except Exception:
        pass
    finally:
        _ACTIVE_SERVER_PID = None
        _ACTIVE_WORKSPACE = ""


def active_server_pid(client):
    server = getattr(client, "_serverObj", None)
    process = getattr(server, "cp", None)
    return getattr(process, "pid", None) or _ACTIVE_SERVER_PID


def close_client(client):
    try:
        if client is None:
            return
        server_pid = active_server_pid(client)
        if taskkill_windows_process_tree(server_pid):
            remove_active_workspace_lock()
            return
        vitis = sys.modules.get("vitis")
        dispose = getattr(vitis, "dispose", None)
        if callable(dispose):
            try:
                dispose()
                return
            except Exception:
                pass
        for name in ("close", "disconnect", "dispose", "shutdown", "stop"):
            method = getattr(client, name, None)
            if not callable(method):
                continue
            try:
                method()
                return
            except Exception:
                continue
    finally:
        remove_active_workspace_lock()
        release_subst_drives()


def method_names(obj):
    return sorted(name for name in dir(obj) if not name.startswith("_"))


def call_first(obj, method_names_to_try, *args, **kwargs):
    for name in method_names_to_try:
        method = getattr(obj, name, None)
        if callable(method):
            return method(*args, **kwargs)
    raise RuntimeError(
        "None of the expected methods exist: " + ", ".join(method_names_to_try)
    )


def get_component(client, component_name):
    tries = (
        ("get_component", (component_name,), {}),
        ("get_component", (), {"name": component_name}),
        ("open_component", (component_name,), {}),
        ("open_component", (), {"name": component_name}),
        ("get_platform_component", (component_name,), {}),
        ("get_app_component", (component_name,), {}),
    )
    for method_name, args, kwargs in tries:
        method = getattr(client, method_name, None)
        if not callable(method):
            continue
        try:
            component = method(*args, **kwargs)
            if component is not None:
                return component
        except Exception:
            continue
    raise RuntimeError(
        f"Unable to locate Vitis component '{component_name}'. Available client methods: "
        + ", ".join(method_names(client)[:80])
    )


def copy_if_needed(src_path, dst_path):
    if not src_path or not dst_path:
        return ""
    src_abs = os.path.abspath(src_path)
    dst_abs = os.path.abspath(dst_path)
    if src_abs == dst_abs or not os.path.exists(src_abs):
        return ""
    ensure_dir(os.path.dirname(dst_abs))
    shutil.copy2(src_abs, dst_abs)
    return normalize_slashes(dst_abs)


def workspace_platform_xpfm(plan):
    workspace = plan.get("workspace", "")
    platform = plan.get("platform", {}) or {}
    name = platform.get("name", "")
    if not workspace or not name:
        return ""
    return os.path.join(workspace, name, "export", name, f"{name}.xpfm")


def workspace_platform_dir(plan):
    workspace = plan.get("workspace", "")
    platform = plan.get("platform", {}) or {}
    name = platform.get("name", "")
    if not workspace or not name:
        return ""
    return os.path.join(workspace, name)


def read_platform_component_config(plan):
    component_json = os.path.join(workspace_platform_dir(plan), "vitis-comp.json")
    try:
        with open(component_json, "r", encoding="utf-8") as handle:
            payload = json.load(handle)
    except Exception:
        return {}
    return payload.get("configuration", {}) or {}


def platform_domains(plan):
    config = read_platform_component_config(plan)
    domains = config.get("domains", [])
    return domains if isinstance(domains, list) else []


def infer_platform_cpu(plan):
    platform = plan.get("platform", {}) or {}
    configured = str(platform.get("cpu", "") or "").strip()
    if configured and configured.lower() != "auto":
        return configured

    config = read_platform_component_config(plan)
    processors = config.get("processorsMap", {}) or {}
    if isinstance(processors, dict) and processors:
        for preferred in ("microblaze_0", "psu_cortexa53_0", "ps7_cortexa9_0", "psv_cortexa72_0"):
            if preferred in processors:
                return preferred
        return sorted(str(name) for name in processors.keys())[0]
    return ""


def ensure_platform_domain(component, plan, warnings=None):
    warnings = warnings if warnings is not None else []
    existing_domains = platform_domains(plan)
    if existing_domains:
        return False

    platform = plan.get("platform", {}) or {}
    cpu = infer_platform_cpu(plan)
    os_name = str(platform.get("os", "standalone") or "standalone")
    configured_domain = str(platform.get("domainName", "") or "").strip()
    domain_name = configured_domain or (f"{os_name}_{cpu}" if cpu else os_name)
    if not cpu:
        warnings.append("platform_domain_auto_cpu_unresolved")
        return False

    method = getattr(component, "add_domain", None)
    if not callable(method):
        warnings.append("platform_add_domain_unavailable")
        return False

    try:
        method(name=domain_name, cpu=cpu, os=os_name)
        warnings.append(f"platform_domain_added:{domain_name}:{cpu}:{os_name}")
        return True
    except Exception as exc:
        warnings.append(f"platform_add_domain_failed:{domain_name}:{cpu}:{os_name}:{exc}")
    return False


def workspace_app_build_dir(plan):
    workspace = plan.get("workspace", "")
    app = plan.get("application", {}) or {}
    name = app.get("name", "")
    target = app.get("target", "hw")
    if not workspace or not name:
        return ""
    return os.path.join(workspace, name, "build", target)


def expand_source_files(app):
    files = []
    for pattern in app.get("sourceFiles", []) or []:
        if glob.has_magic(pattern):
            files.extend(glob.glob(pattern, recursive=True))
        elif os.path.isfile(pattern):
            files.append(pattern)
    return sorted(set(os.path.abspath(path) for path in files if os.path.isfile(path)))
