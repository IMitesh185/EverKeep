"""Allow `python -m everkeep_lab`."""

import sys

from everkeep_lab.cli import main

if __name__ == "__main__":
    sys.exit(main())
