#!/usr/bin/env python3
"""Pre-instrumented bytecode cache for the Atheris harness.

`atheris.instrument_imports()` rewrites the bytecode of every sqlglot module in pure Python on each
process start (~4 s), and a Mayhem/rlenv replay starts one process per input. build.sh runs `dump()`
once at build time, in a process that does exactly what the harness used to do at start-up, and
freezes the result next to the harness; `install()` serves those code objects back (with the same
counter ids) so a start-up only unmarshals them. Edge coverage is the same code, instrumented the
same way.
"""
import importlib.abc
import importlib.machinery
import marshal
import os
import sys
import types

import atheris
from atheris import import_hook

_PLACEHOLDER = "\0atheris-module:"
_CACHE_NAME = "sqlglot-instrumented.bin"


def _map_code(code, fn):
    consts = tuple(_map_code(c, fn) if isinstance(c, types.CodeType) else c for c in code.co_consts)
    return fn(code.replace(co_consts=consts))


def _freeze_consts(code):
    def fn(c):
        consts = tuple(_PLACEHOLDER + k.__name__ if isinstance(k, types.ModuleType) else k
                       for k in c.co_consts)
        return c.replace(co_consts=consts)
    return _map_code(code, fn)


def _thaw_consts(code):
    def fn(c):
        consts = tuple(sys.modules[k[len(_PLACEHOLDER):]]
                       if isinstance(k, str) and k.startswith(_PLACEHOLDER) else k
                       for k in c.co_consts)
        return c.replace(co_consts=consts)
    return _map_code(code, fn)


def dump(path):
    """Import sqlglot under instrumentation and write every instrumented module's code to `path`."""
    entries = {}
    wrapped = []
    for cls in (import_hook.AtherisSourceFileLoader, import_hook.AtherisSourcelessFileLoader):
        orig = cls.get_code

        def get_code(self, fullname, _orig=orig):
            code = _orig(self, fullname)
            if code is not None:
                entries[fullname] = (self.is_package(fullname), self.path, code)
            return code

        wrapped.append((cls, orig))
        cls.get_code = get_code

    first = atheris._reserve_counter()
    with atheris.instrument_imports():
        import sqlglot  # noqa: F401
    last = atheris._reserve_counter()
    for cls, orig in wrapped:
        cls.get_code = orig

    mods = {}
    for name, (is_pkg, origin, code) in entries.items():
        fname = name.replace(".", "/") + ("/__init__.py" if is_pkg else ".py")
        code = _map_code(code, lambda c, f=fname: c.replace(co_filename=f))
        mods[name] = (is_pkg, os.path.dirname(origin) if is_pkg else None, marshal.dumps(_freeze_consts(code)))
    with open(path, "wb") as fh:
        fh.write(marshal.dumps({"last_counter": last, "modules": mods}))
    print(f"instr_cache: {len(mods)} modules, counters {first}..{last} -> {path}")


class _Loader(importlib.abc.Loader):
    def __init__(self, modules):
        self._modules = modules

    def create_module(self, spec):
        return None

    def exec_module(self, module):
        code = _thaw_consts(marshal.loads(self._modules[module.__name__][2]))
        exec(code, module.__dict__)


class _Finder(importlib.abc.MetaPathFinder):
    def __init__(self, modules):
        self._modules = modules
        self._loader = _Loader(modules)

    def find_spec(self, fullname, path=None, target=None):
        ent = self._modules.get(fullname)
        if ent is None:
            return None
        is_pkg, recorded_dir, _ = ent
        base = getattr(sys, "_MEIPASS", None)
        pkg_dir = os.path.join(base, *fullname.split(".")) if base else recorded_dir
        origin = fullname.replace(".", "/") + ("/__init__.py" if is_pkg else ".py")
        spec = importlib.machinery.ModuleSpec(fullname, self._loader, origin=origin, is_package=is_pkg)
        if is_pkg:
            spec.submodule_search_locations = [pkg_dir]
        return spec


def install(path):
    """Serve the cached instrumented modules; False (nothing changed) if there is no cache."""
    if not os.path.exists(path):
        return False
    with open(path, "rb") as fh:
        data = marshal.loads(fh.read())
    while atheris._reserve_counter() < data["last_counter"]:
        pass
    sys.meta_path.insert(0, _Finder(data["modules"]))
    return True


def cache_path():
    return os.path.join(getattr(sys, "_MEIPASS", os.path.dirname(os.path.abspath(__file__))), _CACHE_NAME)


if __name__ == "__main__":
    dump(sys.argv[1])
