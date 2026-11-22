#!/usr/bin/env -S python3 -I
import hashlib
import json
import pathlib
import sys

GM_COMMIT = "2db01da"
SHARED = {
    "vendor.mjs": "00316a7a1d7b8d7c5f35b4bb62a8de269086c5aefa7b2b08dfcc6bae59c6775e",
    "pins.json": "5c1eb77bcebdbd77f4a0313c7f3dfbf961283fed91d0c2ee9793ffa3ab9104eb",
}
DEFAULT_ROOT = pathlib.Path(__file__).resolve().parent / "txiki"


def digest(path: pathlib.Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def problems(root: pathlib.Path) -> list[str]:
    found = []
    for name, wanted in SHARED.items():
        path = root / name
        if not path.is_file():
            found.append(f"{path}: missing, wanted the shared sha256 {wanted}")
        elif (actual := digest(path)) != wanted:
            found.append(f"{path}: sha256 {actual} differs from the shared {wanted} (gm {GM_COMMIT} tools/txiki/{name})")
    if found:
        return found
    for patch in json.loads((root / "pins.json").read_text(encoding="utf-8"))["patches"]:
        path = root / "patches" / patch["file"]
        if not path.is_file():
            found.append(f"{path}: missing, pinned at {patch['sha256']}")
        elif (actual := digest(path)) != patch["sha256"]:
            found.append(f"{path}: sha256 {actual} differs from the pin {patch['sha256']}")
    return found


def main(argv: list[str]) -> int:
    roots = [pathlib.Path(arg) for arg in argv] or [DEFAULT_ROOT]
    found = [line for root in roots for line in problems(root)]
    for line in found:
        print(line, file=sys.stderr)
    if not found:
        print(f"check_vendor_txiki: {', '.join(str(root) for root in roots)} match gm {GM_COMMIT} tools/txiki")
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
