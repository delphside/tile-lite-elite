"""The Python model's tests, run by unittest (docs/4.3.3 §2.2):

    python3 -m unittest discover -s scripts/programme -t scripts/programme
"""

from board.tests.profiles import use_fakes

# Every test reads the fake profiles, never the real application's (#485).
use_fakes()
