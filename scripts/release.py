"""Check, package and install the Factorio mod using the Python standard library."""
import argparse
import json
import os
import re
import shutil
import subprocess
import tempfile
from pathlib import Path
from zipfile import ZIP_DEFLATED, ZipFile, ZipInfo

ROOT = Path(__file__).resolve().parents[1]
INFO = "mod/info.json"


def git(*args):
    return subprocess.check_output(["git", "-C", str(ROOT), *args])


def version_of(data):
    info = json.loads(data)
    if info["name"] != "auto-factory-planner":
        raise ValueError("The mod ID must match existing saves.")
    version = info["version"]
    if not re.fullmatch(r"\d+\.\d+\.\d+", version):
        raise ValueError("Expected a three-part Factorio version in mod/info.json.")
    return version


def check(staged=False):
    def read(path):
        return git("show", ":" + path) if staged else (ROOT / path).read_bytes()

    version = version_of(read(INFO))
    if f"## [{version}]" not in read("CHANGELOG.md").decode().splitlines():
        raise ValueError(f"CHANGELOG.md needs an entry for {version}.")
    if staged:
        # The historical release tags put the same payload at the repo root.
        head = git("ls-tree", "--name-only", "HEAD").decode().splitlines()
        previous_root = "HEAD:mod" if "mod" in head else "HEAD^{tree}"
        staged_root = git("write-tree").decode().strip() + ":mod"
        if git("rev-parse", previous_root) != git("rev-parse", staged_root):
            old_path = "HEAD:" + (INFO if "mod" in head else "info.json")
            previous = version_of(git("show", old_path))
            if tuple(map(int, version.split("."))) <= tuple(map(int, previous.split("."))):
                raise ValueError(f"Packaged files changed. Bump mod/info.json above {previous}.")
    return version


def build():
    version = check()
    prefix = f"auto-factory-planner_{version}"
    output = ROOT / "dist" / (prefix + ".zip")
    output.parent.mkdir(exist_ok=True)
    files = git("ls-files", "-z", "--", "mod/").decode().split("\0")
    with tempfile.TemporaryDirectory(dir=output.parent) as temp:
        candidate = Path(temp) / output.name
        with ZipFile(candidate, "w") as archive:
            for path in sorted(filter(None, files)):
                relative = Path(path).relative_to("mod").as_posix()
                entry = ZipInfo(f"{prefix}/{relative}")
                entry.create_system = 3
                entry.external_attr = 0o100644 << 16
                archive.writestr(entry, (ROOT / path).read_bytes(), ZIP_DEFLATED)
        with ZipFile(candidate) as archive:
            if archive.testzip() is not None:
                raise ValueError("Package failed its ZIP integrity check.")
        os.replace(candidate, output)
    return output


def same_contents(left, right):
    with ZipFile(left) as a, ZipFile(right) as b:
        names_a = sorted(i.filename for i in a.infolist() if not i.is_dir())
        names_b = sorted(i.filename for i in b.infolist() if not i.is_dir())
        return names_a == names_b and all(a.read(n) == b.read(n) for n in names_a)


def install(package, mods):
    mods.mkdir(parents=True, exist_ok=True)
    target = mods / package.name
    with tempfile.TemporaryDirectory(dir=mods) as temp:
        incoming = Path(temp) / package.name
        shutil.copyfile(package, incoming)
        try:
            # Publish only a complete file, preserving an existing version.
            if os.name == "nt":
                os.rename(incoming, target)
            else:
                os.link(incoming, target)
        except FileExistsError:
            if not same_contents(package, target):
                raise ValueError(f"{target} already exists with different contents.")
    return target


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="action", required=True)
    commands.add_parser("check").add_argument("--staged", action="store_true")
    commands.add_parser("build")
    commands.add_parser("install").add_argument("--mods-dir", type=Path)
    args = parser.parse_args()
    if args.action == "check":
        print("Release metadata OK for", check(args.staged))
    elif args.action == "build":
        print(build())
    else:
        mods = args.mods_dir
        if mods is None:
            if "APPDATA" not in os.environ:
                parser.error("Provide --mods-dir for this Factorio installation.")
            mods = Path(os.environ["APPDATA"]) / "Factorio" / "mods"
        print(install(build(), mods))


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError) as exc:
        raise SystemExit(str(exc)) from exc
