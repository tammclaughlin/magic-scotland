import sys
from pathlib import Path

# Make the `magic` package importable when running pytest from app/
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
