#!/bin/sh
set -eu

DEST_ROOT="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/python-runtime"

choose_python() {
  if [ -n "${TAKEOUT_EMBED_PYTHON:-}" ] && [ -x "${TAKEOUT_EMBED_PYTHON}" ]; then
    echo "${TAKEOUT_EMBED_PYTHON}"
    return 0
  fi

  for c in \
    /opt/homebrew/bin/python3 \
    /usr/local/bin/python3 \
    "${HOME}/opt/miniconda3/bin/python3" \
    "${HOME}/miniconda3/bin/python3"
  do
    if [ -x "$c" ]; then
      echo "$c"
      return 0
    fi
  done

  if command -v python3 >/dev/null 2>&1; then
    CANDIDATE="$(command -v python3)"
    if [ "$CANDIDATE" != "/usr/bin/python3" ]; then
      echo "$CANDIDATE"
      return 0
    fi
  fi

  return 1
}

SRC_PY="$(choose_python || true)"
if [ -z "${SRC_PY}" ]; then
  echo "error: Could not find a non-system python3 to embed. Install Homebrew/Python.org Python or set TAKEOUT_EMBED_PYTHON." >&2
  exit 1
fi

SRC_PREFIX="$("${SRC_PY}" -c 'import sys; print(sys.prefix)')"
if [ ! -d "${SRC_PREFIX}" ]; then
  echo "error: Python prefix '${SRC_PREFIX}' does not exist." >&2
  exit 1
fi

"${SRC_PY}" -c 'import PIL' >/dev/null 2>&1 || {
  echo "error: Selected Python (${SRC_PY}) is missing Pillow. Install it before archiving: ${SRC_PY} -m pip install pillow" >&2
  exit 1
}

rm -rf "${DEST_ROOT}"
mkdir -p "${DEST_ROOT}"

# Copy the Python prefix, then aggressively prune non-runtime content that often
# breaks distribution validation (Conda helper binaries/scripts, package caches, etc.).
ditto "${SRC_PREFIX}" "${DEST_ROOT}"

if [ ! -x "${DEST_ROOT}/bin/python3" ]; then
  PY_FALLBACK="$(find "${DEST_ROOT}/bin" -maxdepth 1 -type f -name 'python3*' | head -n 1 || true)"
  if [ -n "${PY_FALLBACK}" ]; then
    ln -sf "$(basename "${PY_FALLBACK}")" "${DEST_ROOT}/bin/python3"
  fi
fi

if [ ! -x "${DEST_ROOT}/bin/python3" ]; then
  echo "error: Embedded runtime is missing bin/python3 after copy." >&2
  exit 1
fi

# Keep only Python executables in bin; remove toolchain/helper scripts/symlinks.
if [ -d "${DEST_ROOT}/bin" ]; then
  find "${DEST_ROOT}/bin" -mindepth 1 \
    ! -name 'python' \
    ! -name 'python3' \
    ! -name 'python3.*' \
    ! -name 'python-config' \
    ! -name 'python3-config' \
    -exec rm -rf {} + || true
fi

# Remove Conda/package-manager metadata and caches that are unnecessary at runtime.
rm -rf \
  "${DEST_ROOT}/conda-meta" \
  "${DEST_ROOT}/pkgs" \
  "${DEST_ROOT}/envs" \
  "${DEST_ROOT}/python.app" \
  "${DEST_ROOT}/include" \
  "${DEST_ROOT}/share/doc" \
  "${DEST_ROOT}/share/man" || true

# Drop any dangling symlinks left by the source distribution.
find -L "${DEST_ROOT}" -type l -delete || true

# Replace remaining symlinks with real files/dirs for stricter archive/distribution validation.
RESOLVED_ROOT="${DEST_ROOT}.resolved"
rm -rf "${RESOLVED_ROOT}"
cp -R -L "${DEST_ROOT}" "${RESOLVED_ROOT}"
rm -rf "${DEST_ROOT}"
mv "${RESOLVED_ROOT}" "${DEST_ROOT}"

# Strip executable bits from non-binary files so code-sign validation does not
# attempt Mach-O parsing for plain text files.
find "${DEST_ROOT}" -type f -perm -111 | while IFS= read -r f; do
  KIND="$(file -b "$f" || true)"
  case "$KIND" in
    *"Mach-O"*) ;;
    *"script text executable"*) ;;
    *)
      chmod a-x "$f" || true
      ;;
  esac
done

# Final sanity check: bundled runtime must be able to import Pillow.
"${DEST_ROOT}/bin/python3" -c 'import PIL' >/dev/null 2>&1 || {
  echo "error: Embedded runtime sanity check failed: Pillow import did not succeed." >&2
  exit 1
}

sign_with_runtime_if_possible() {
  BIN="$1"
  if [ ! -f "${BIN}" ] || [ ! -x "${BIN}" ]; then
    return 0
  fi
  if [ "${CODE_SIGNING_ALLOWED:-NO}" != "YES" ]; then
    return 0
  fi
  if [ -z "${EXPANDED_CODE_SIGN_IDENTITY:-}" ] || [ "${EXPANDED_CODE_SIGN_IDENTITY:-}" = "-" ]; then
    return 0
  fi
  /usr/bin/codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY}" --options runtime --timestamp=none "${BIN}"
}

# App Store Connect checks these embedded executables for hardened runtime support.
sign_with_runtime_if_possible "${DEST_ROOT}/bin/python"
sign_with_runtime_if_possible "${DEST_ROOT}/bin/python3"
sign_with_runtime_if_possible "${DEST_ROOT}/bin/python3.9"

echo "Embedded Python runtime from: ${SRC_PY}"
echo "Embedded runtime path: ${DEST_ROOT}"
