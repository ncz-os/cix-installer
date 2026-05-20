"""mnemos-embedkit — open embedding devkit for heterogeneous silicon.

Quick start:

    import embedkit
    eng = embedkit.Engine.auto()
    vec = eng.embed("Hello world")

See docs/DESIGN.md for architecture.
"""
from __future__ import annotations

from .engine import Engine

__version__ = "0.1.0-dev"
__all__ = ["Engine", "__version__"]
