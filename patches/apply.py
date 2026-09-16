#!/usr/bin/env python3
"""Apply the ccs-plugin control API patch to a cc-switch source tree.

Usage: apply.py <cc-switch-repo-root> [--updater-endpoint URL]

--updater-endpoint replaces the in-app updater feed so the patched build never
offers to overwrite itself with an unpatched official release.

Idempotent: re-running on an already patched tree is a no-op.
"""
import json
import shutil
import sys
from pathlib import Path

MOD_ANCHOR = "mod proxy;\n"
MOD_LINE = "mod control_api;\n"
START_ANCHOR = "restore_proxy_state_on_startup(&state).await;\n"
START_LINE = "control_api::start(app_handle.clone());\n"


def patch_lib(lib: Path) -> None:
    text = lib.read_text(encoding="utf-8")
    if MOD_LINE not in text:
        if MOD_ANCHOR not in text:
            raise SystemExit("anchor 'mod proxy;' not found in lib.rs")
        text = text.replace(MOD_ANCHOR, MOD_ANCHOR + MOD_LINE, 1)

    if START_LINE.strip() not in text:
        idx = text.find(START_ANCHOR)
        if idx < 0:
            raise SystemExit("anchor 'restore_proxy_state_on_startup(&state).await;' not found in lib.rs")
        line_start = text.rfind("\n", 0, idx) + 1
        indent = text[line_start:idx]
        insert_at = idx + len(START_ANCHOR)
        text = text[:insert_at] + "\n" + indent + START_LINE + text[insert_at:]

    lib.write_text(text, encoding="utf-8")


def patch_updater(conf: Path, endpoint: str) -> None:
    data = json.loads(conf.read_text(encoding="utf-8"))
    updater = data.setdefault("plugins", {}).setdefault("updater", {})
    updater["endpoints"] = [endpoint]
    data.setdefault("bundle", {})["createUpdaterArtifacts"] = False
    conf.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def main() -> int:
    args = sys.argv[1:]
    endpoint = None
    if "--updater-endpoint" in args:
        i = args.index("--updater-endpoint")
        endpoint = args[i + 1]
        del args[i : i + 2]
    if len(args) != 1:
        print(__doc__, file=sys.stderr)
        return 2

    root = Path(args[0]).resolve()
    src = root / "src-tauri" / "src"
    lib = src / "lib.rs"
    if not lib.is_file():
        print(f"not a cc-switch checkout: {lib} missing", file=sys.stderr)
        return 1

    shutil.copyfile(Path(__file__).with_name("control_api.rs"), src / "control_api.rs")
    patch_lib(lib)
    if endpoint:
        patch_updater(root / "src-tauri" / "tauri.conf.json", endpoint)
    print("patched", root)
    return 0


if __name__ == "__main__":
    sys.exit(main())
