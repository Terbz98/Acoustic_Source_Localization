"""
use_project_python.py -- make every script run on the project's own Python.

The packages this project needs (numpy, scipy, sounddevice, opencv, ...) are
installed in INSTA360/.venv, not in the Mac's built-in Python. If a
script is started with any other Python (VS Code's Run button, `python3
live_tracker.py`, ...), importing this module restarts the same script,
with the same arguments, on .venv/bin/python. Standard library only, so it
works before numpy is importable.
"""

import os
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
_VENV = os.path.join(_HERE, '.venv')
_PY = os.path.join(_VENV, 'bin', 'python')

if os.path.realpath(sys.prefix) != os.path.realpath(_VENV) and os.path.exists(_PY) \
        and not os.environ.get('INSTA360_REEXEC'):
    os.environ['INSTA360_REEXEC'] = '1'          # never loop
    os.execv(_PY, [_PY, os.path.abspath(sys.argv[0])] + sys.argv[1:])
