#!/usr/bin/env bash
# Runs the plugin tests against the pretalx release pinned in ../statefulset.yaml,
# so bumping the image tag and re-running this is the upgrade check.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
version=$(grep -m1 -o 'pretalx/standalone:v[0-9.]*' "$here/../statefulset.yaml" | cut -d: -f2)
src=${PRETALX_SRC:-${XDG_CACHE_HOME:-$HOME/.cache}/pretalx-src-$version}

if [ ! -d "$src" ]; then
  git clone -q --depth 1 --branch "$version" https://github.com/pretalx/pretalx.git "$src"
fi
# The Python this pretalx release pins: the newest one can lack wheels
# (CPython 3.15 broke minify-html's PyO3 build).
if [ ! -x "$src/.venv/bin/pytest" ]; then
  (cd "$src" && uv venv -q --python "$(cat .github/workflows/python-version.txt)" \
    && uv pip install -q -e ".[dev]")
fi

cd "$here"
PYTHONPATH="$src/src" exec "$src/.venv/bin/pytest" "$@"
