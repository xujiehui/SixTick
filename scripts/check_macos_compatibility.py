"""Check the shipped app and all native libraries, not just the Xcode target."""

import pathlib
import plistlib
import re
import subprocess
import sys


def version(value):
    parts = tuple(int(part) for part in value.split("."))
    return parts + (0,) * (3 - len(parts))


def output(*command):
    return subprocess.check_output(command, text=True).strip()


def check(app):
    with (app / "Contents/Info.plist").open("rb") as source:
        info = plistlib.load(source)
    minimum = info["LSMinimumSystemVersion"]
    assert version(minimum) == version("12.0"), minimum
    executable = app / "Contents/MacOS" / info["CFBundleExecutable"]
    assert executable.is_file(), executable
    checked = []
    for path in sorted(app.rglob("*")):
        if path.is_symlink() or not path.is_file():
            continue
        if "Mach-O" not in output("file", "-b", str(path)):
            continue
        architectures = output("lipo", "-archs", str(path)).split()
        assert {"x86_64", "arm64"}.issubset(architectures), (path, architectures)
        for architecture in ("x86_64", "arm64"):
            commands = output("otool", "-arch", architecture, "-l", str(path))
            minima = re.findall(r"\bminos\s+([\d.]+)", commands)
            minima += re.findall(
                r"cmd LC_VERSION_MIN_MACOSX\s+cmdsize \d+\s+version ([\d.]+)",
                commands,
            )
            assert minima, (path, architecture, "no minimum OS load command")
            assert all(version(v) <= version("12.0") for v in minima), (
                path, architecture, minima
            )
        checked.append(str(path.relative_to(app)))
    assert str(executable.relative_to(app)) in checked, "App executable not checked"
    print("\n".join(checked))
    print(
        f"::notice title=macOS compatibility::Verified {len(checked)} native binaries: "
        "x86_64 + arm64, minimum macOS <= 12.0; app minimum macOS 12.0."
    )


if __name__ == "__main__":
    check(pathlib.Path(sys.argv[1]).resolve())
