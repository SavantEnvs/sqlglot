#!/usr/bin/env bash
set -euo pipefail

# build.sh — build the Mayhem fuzz target and the functional-oracle CLI for sqlglot.
#
# Outputs (all under /mayhem):
#   fuzz-lang     — Atheris libFuzzer harness, frozen to a self-contained ELF (PyInstaller onefile).
#                   This is the Mayhem target. Post-processed to carry DWARF-3 debug info so Mayhem's
#                   triage can read it (item 10) — a stock PyInstaller bootloader is stripped.
#   sqlglot-cli   — a tiny transpile CLI frozen to an ELF; the test.sh oracle drives it with
#                   known-answer transpilations. Because it is a *project* executable (not the
#                   spared system interpreter), the anti-reward-hacking neuter bites it and the
#                   oracle FAILS when the program is stubbed to exit(0).
#
# Re-runnable + air-gapped: the first (online) run vendors the THIRD-PARTY dependencies only — build
# tooling, PyInstaller and a compiled atheris wheel — into an in-image wheelhouse. Every run
# (including the offline PATCH re-run) recreates the build venv from that wheelhouse with --no-index,
# touching the network for nothing.
#
# sqlglot itself is NEVER vendored: it is installed from the current checkout ($SRC) on EVERY run, so
# the frozen fuzz-lang and sqlglot-cli always carry the tree being graded (an edited sqlglot/*.py must
# reach both). A cached project wheel would survive `git clean -ffdX` (wheelhouse/ is untracked, not
# ignored) and freeze the pre-patch sources into every rebuild; step 3 fails the build if the frozen
# package ever differs from the checkout.

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer -g}"
# DWARF < 4 for Mayhem's triage (clang-19 -g defaults to DWARF-5). Injected into the frozen ELF below.
: "${DEBUG_FLAGS=-gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}"
: "${MAYHEM_JOBS:=$(nproc)}"
export CC CXX MAYHEM_JOBS
export PIP_DISABLE_PIP_VERSION_CHECK=1 PIP_NO_INPUT=1

cd "$SRC"

WHEELHOUSE=/mayhem/wheelhouse

# 1. Vendor deps ONCE (online). Re-runs reuse the baked wheelhouse offline.
if [ ! -f "$WHEELHOUSE/.ready" ]; then
  mkdir -p "$WHEELHOUSE"
  python3 -m venv /mayhem/seed-venv
  /mayhem/seed-venv/bin/pip install --upgrade pip setuptools wheel setuptools_scm
  # Build tooling (also the PEP517 build deps for the offline sqlglot/atheris installs).
  /mayhem/seed-venv/bin/pip wheel -w "$WHEELHOUSE" pip setuptools wheel setuptools_scm
  # PyInstaller + its dependency closure (altgraph, packaging, pyinstaller-hooks-contrib, ...).
  /mayhem/seed-venv/bin/pip wheel -w "$WHEELHOUSE" pyinstaller
  # atheris has no PyPI wheel — compile it (with the sanitizer flags) and cache the resulting wheel,
  # so the offline re-run reinstalls the prebuilt wheel instead of recompiling.
  CFLAGS="$SANITIZER_FLAGS" CXXFLAGS="$SANITIZER_FLAGS" LDFLAGS="$SANITIZER_FLAGS" \
    /mayhem/seed-venv/bin/pip wheel -w "$WHEELHOUSE" atheris
  touch "$WHEELHOUSE/.ready"
fi

# 2. Build venv, resolved ENTIRELY from the wheelhouse (offline-safe).
rm -rf /mayhem/build-venv
python3 -m venv /mayhem/build-venv
PIP=/mayhem/build-venv/bin/pip
PYI=/mayhem/build-venv/bin/pyinstaller
$PIP install --no-index --find-links="$WHEELHOUSE" --upgrade pip setuptools wheel
$PIP install --no-index --find-links="$WHEELHOUSE" atheris pyinstaller

# 3. sqlglot from the CURRENT checkout, every run (pure-Python, zero runtime deps). Installed by PATH,
# never resolved by name: setuptools_scm's no-local-version scheme gives a patched tree the same
# version string as the unpatched one. The PEP517 build deps (setuptools, setuptools_scm) resolve
# from the wheelhouse. build/ is our own (gitignored) setuptools output — drop it so a re-run without
# `git clean` cannot reuse stale build/lib copies.
rm -rf "$SRC/build"
$PIP install --no-index --find-links="$WHEELHOUSE" --no-deps "$SRC"
# Self-check (build FAILS, never repairs): the package PyInstaller freezes (--collect-all sqlglot,
# from build-venv site-packages) must be the checkout's sqlglot/*.py, byte for byte. Isolated mode (-I)
# from /tmp, so the checkout on cwd cannot shadow site-packages.
( cd /tmp && /mayhem/build-venv/bin/python -I - "$SRC/sqlglot" <<'PY'
import filecmp, os, sys
import sqlglot
src = os.path.realpath(sys.argv[1])
inst = os.path.dirname(os.path.realpath(sqlglot.__file__))
if inst == src:
    sys.exit("build.sh: sqlglot resolved to the checkout, not the build venv's site-packages")
def mods(root):
    return {os.path.relpath(os.path.join(d, f), root)
            for d, dirs, files in os.walk(root) if "__pycache__" not in d.split(os.sep)
            for f in files if f.endswith(".py")} - {"_version.py"}
a, b = mods(src), mods(inst)
bad = sorted(a ^ b) + sorted(m for m in a & b
                             if not filecmp.cmp(os.path.join(src, m), os.path.join(inst, m), shallow=False))
if not a or bad:
    sys.exit(f"build.sh: installed sqlglot ({inst}) != checkout ({src}): {bad[:10] or 'no modules'}")
print(f"build.sh: installed sqlglot == checkout ({len(a)} modules)")
PY
)

# 4. Freeze the Atheris fuzz harness to a self-contained ELF.
rm -rf /tmp/pyinst-out /tmp/pyinst-work /tmp/pyinst-spec
$PYI \
  --distpath /tmp/pyinst-out \
  --workpath /tmp/pyinst-work \
  --specpath /tmp/pyinst-spec \
  --onefile \
  --name fuzz-lang \
  --paths "$SRC/mayhem" \
  --collect-all sqlglot \
  --hidden-import fuzz_helpers \
  "$SRC/mayhem/fuzz_lang.py"
install -m 0755 /tmp/pyinst-out/fuzz-lang /mayhem/fuzz-lang

# 5. Freeze the transpile oracle CLI to an ELF (drives test.sh known-answer tests).
rm -rf /tmp/cli-out /tmp/cli-work /tmp/cli-spec
$PYI \
  --distpath /tmp/cli-out \
  --workpath /tmp/cli-work \
  --specpath /tmp/cli-spec \
  --onefile \
  --name sqlglot-cli \
  --paths "$SRC/mayhem" \
  --collect-all sqlglot \
  "$SRC/mayhem/sqlglot_cli.py"
install -m 0755 /tmp/cli-out/sqlglot-cli /mayhem/sqlglot-cli

# 6. Give the frozen fuzz-lang ELF DWARF-3 debug info (item 10).
# PyInstaller's bootloader ships stripped; Mayhem's triage needs a .debug_info section with
# DWARF < 4. Compile a stub with $DEBUG_FLAGS and graft its debug sections onto the frozen binary
# (objcopy leaves the appended PyInstaller CArchive intact, so the target still runs).
DWSTUB=/tmp/dwstub
printf 'int __mayhem_dwarf_anchor(void){return 0;}\nint main(void){return 0;}\n' > "$DWSTUB.c"
$CC $DEBUG_FLAGS -o "$DWSTUB" "$DWSTUB.c"
addargs=()
for s in info abbrev str line; do
  if objcopy --dump-section ".debug_$s=/tmp/dw_$s" "$DWSTUB" 2>/dev/null; then
    addargs+=(--add-section ".debug_$s=/tmp/dw_$s")
  fi
done
objcopy "${addargs[@]}" /mayhem/fuzz-lang /mayhem/fuzz-lang
chmod 0755 /mayhem/fuzz-lang

echo "build.sh: OK — /mayhem/fuzz-lang (DWARF-3) + /mayhem/sqlglot-cli built"
