#!/bin/sh
# Runs flutter with Beth's build number and commit filled in:
#
#   tool/flutter_versioned.sh build apk --release
#   tool/flutter_versioned.sh run --release -d <device-id>
#
# The build number is the git commit count (it only goes up, so Android
# accepts each build as an update) and the commit is the short hash, with
# "-dirty" when tracked files have uncommitted changes. The version itself
# (1.0.0) comes from pubspec.yaml. See lib/app_version.dart.
set -e
cd "$(dirname "$0")/.."

build=$(git rev-list --count HEAD)
commit=$(git rev-parse --short=7 HEAD)
if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
  commit="$commit-dirty"
fi

case "$1" in
  build)
    # flutter build <target> ... --build-number sets Android's versionCode
    # and iOS/macOS CFBundleVersion.
    exec flutter "$@" --build-number="$build" \
      --dart-define=BETH_COMMIT="$commit"
    ;;
  run)
    # flutter run has no --build-number: pass it to the app instead.
    exec flutter "$@" --dart-define=BETH_BUILD="$build" \
      --dart-define=BETH_COMMIT="$commit"
    ;;
  *)
    echo "usage: $0 build <target> [flags] | run [flags]" >&2
    exit 64
    ;;
esac
