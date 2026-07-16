#!/usr/bin/env python3
################################################################################
##
## Copyright (C) 2026 Fredrik Åkerlund
##
## Permission is hereby granted, free of charge, to any person obtaining a copy
## of this software and associated documentation files (the "Software"), to deal
## in the Software without restriction, including without limitation the rights
## to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
## copies of the Software, and to permit persons to whom the Software is
## furnished to do so, subject to the following conditions:
##
## The above copyright notice and this permission notice shall be included in
## all copies or substantial portions of the Software.
##
## THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
## IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
## FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
## AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
## LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
## OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
## SOFTWARE.
##
## Description:
## Version-drift guard for the vip_dram Python ports.
##
## Each ported component carries its version in a <component>_version.py marker
## (__version__ + CORE_NAME). The authoritative version lives in that component's
## SV .core (name: "akerlund::<name>:<ver>"). This script asserts the two agree,
## so the Python port can never silently drift from the RTL it mirrors.
##
## Standalone on purpose -- imports NO cocotb/pyuvm, so it runs as a cheap
## pre-flight (run_all_tcs.py calls it) or on its own in CI:
##
##   python3 check_versions.py            # exit 0 = in sync, 1 = drift
##
################################################################################

import glob
import importlib
import os
import re
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))


def _find_vip_root(start):
  """Locate this repo's root by walking up to the .git marker. Override with
  $VIP_ROOT; fall back to 2-levels-up."""
  env = os.environ.get("VIP_ROOT")
  if env:
    return os.path.abspath(env)
  d = start
  while True:
    if os.path.exists(os.path.join(d, ".git")):
      return d
    parent = os.path.dirname(d)
    if parent == d:
      return os.path.abspath(os.path.join(start, "..", ".."))
    d = parent


# component name -> (repo-root-relative dir holding its .core and py/,
#                    version-marker module name).
# vip_dram is this repo itself; vip_memory is a git submodule.
_COMPONENTS = {
    "vip_dram": (".", "vip_dram_version"),
    "vip_memory": (os.path.join("submodules", "vip_memory"), "vip_memory_version"),
}


def _core_version(core_path):
  """Extract the version (last colon field) from a .core `name:` line."""
  with open(core_path) as f:
    for line in f:
      m = re.match(r'\s*name:\s*"([^"]+)"', line)
      if m:
        vlnv = m.group(1)          # e.g. akerlund::vip_dram:1.0.0
        return vlnv, vlnv.rsplit(":", 1)[-1]
  raise RuntimeError(f"no `name:` VLNV found in {core_path}")


def check(root=None):
  """Return a list of human-readable drift errors (empty == all in sync)."""
  root = root or _find_vip_root(_HERE)
  errors = []
  for comp, (comp_root_rel, mod_name) in _COMPONENTS.items():
    comp_root = os.path.join(root, comp_root_rel)
    py_dir = os.path.join(comp_root, "py")
    cores = glob.glob(os.path.join(comp_root, "*.core"))
    if not cores:
      errors.append(f"{comp}: no SV .core found under {comp_root_rel}/")
      continue
    if len(cores) > 1:
      errors.append(f"{comp}: expected 1 .core, found {len(cores)}: {cores}")
      continue

    core_vlnv, core_ver = _core_version(cores[0])

    if py_dir not in sys.path:
      sys.path.insert(0, py_dir)
    try:
      mod = importlib.import_module(mod_name)
    except ImportError as e:
      errors.append(f"{comp}: cannot import {mod_name}.py ({e})")
      continue

    py_ver = getattr(mod, "__version__", None)
    py_core = getattr(mod, "CORE_NAME", None)
    if py_ver != core_ver:
      errors.append(
          f"{comp}: py __version__={py_ver!r} != SV core version {core_ver!r} "
          f"({os.path.relpath(cores[0], root)})")
    if py_core != core_vlnv:
      errors.append(
          f"{comp}: py CORE_NAME={py_core!r} != SV core VLNV {core_vlnv!r}")
    if py_ver == core_ver and py_core == core_vlnv:
      print(f"  OK  {comp:16s} {core_vlnv}")
  return errors


def main():
  print("Version check (py __version__ vs SV .core):")
  errors = check()
  if errors:
    print("\nVERSION DRIFT:", file=sys.stderr)
    for e in errors:
      print(f"  - {e}", file=sys.stderr)
    return 1
  print("All component py ports match their SV cores.")
  return 0


if __name__ == "__main__":
  sys.exit(main())
