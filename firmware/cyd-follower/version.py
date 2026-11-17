# PlatformIO pre-build script: stamps the firmware with Beth's version.
#
#   BETH_VERSION  "1.0.0", from the app's pubspec.yaml (one version for both)
#   BETH_BUILD    git commit count, as the app's build number
#   BETH_COMMIT   short hash, "-dirty" with uncommitted changes to tracked
#                 files
#
# Matches tool/flutter_versioned.sh, so a CYD and a phone built from the
# same commit show the same build. Falls back to "dev" values without git.
import os
import re
import subprocess

Import("env")  # noqa: F821 (provided by PlatformIO)

root = os.path.abspath(os.path.join(env["PROJECT_DIR"], "..", ".."))  # noqa: F821


def git(*args):
    try:
        return subprocess.check_output(
            ["git", *args], cwd=root, stderr=subprocess.DEVNULL, text=True
        ).strip()
    except (OSError, subprocess.CalledProcessError):
        return None


version = "0.0.0"
try:
    with open(os.path.join(root, "pubspec.yaml"), encoding="utf-8") as f:
        m = re.search(r"^version:\s*([0-9.]+)", f.read(), re.M)
        if m:
            version = m.group(1)
except OSError:
    pass

build = git("rev-list", "--count", "HEAD") or "0"
commit = git("rev-parse", "--short=7", "HEAD") or "dev"
if commit != "dev" and git("status", "--porcelain", "--untracked-files=no"):
    commit += "-dirty"

env.Append(  # noqa: F821
    CPPDEFINES=[
        ("BETH_VERSION", env.StringifyMacro(version)),  # noqa: F821
        ("BETH_BUILD", build),
        ("BETH_COMMIT", env.StringifyMacro(commit)),  # noqa: F821
    ]
)
print(f"Beth firmware {version} (build {build}, {commit})")
