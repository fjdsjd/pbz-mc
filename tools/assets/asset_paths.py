"""Isolated, caller-selected asset build workspace."""
import os
from pathlib import Path

ROOT = Path(os.environ['PBZMC_ASSET_WORK']).resolve()
