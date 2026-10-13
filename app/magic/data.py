"""Read club and event data from YAML files in DATA_DIR."""

import datetime as dt
import os
from functools import lru_cache
from pathlib import Path

import yaml

DEFAULT_DATA_DIR = Path(__file__).resolve().parent.parent / "data"


def _data_dir():
    return Path(os.environ.get("DATA_DIR", DEFAULT_DATA_DIR))


@lru_cache(maxsize=None)
def _load(name):
    with open(_data_dir() / name, encoding="utf-8") as fh:
        return yaml.safe_load(fh) or []


def get_clubs():
    return sorted(_load("clubs.yaml"), key=lambda c: c["name"].lower())


def get_club(slug):
    return next((c for c in get_clubs() if c["slug"] == slug), None)


def get_events(today=None):
    """Upcoming events (end date today or later), soonest first."""
    today = today or dt.date.today()
    events = []
    for event in _load("events.yaml"):
        end = event.get("end_date") or event["start_date"]
        if end >= today:
            events.append(event)
    return sorted(events, key=lambda e: e["start_date"])


def clear_cache():
    _load.cache_clear()
