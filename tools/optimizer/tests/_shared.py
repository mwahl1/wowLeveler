"""Shared fixtures: the export is loaded once per test process."""
import os
import sys

sys.dont_write_bytecode = True  # never write __pycache__ outside tools/.cache

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))

import model as M  # noqa: E402,F401
import baseline as B  # noqa: E402,F401

_WORLD = None


def world():
    global _WORLD
    if _WORLD is None:
        _WORLD = M.World()
    return _WORLD
