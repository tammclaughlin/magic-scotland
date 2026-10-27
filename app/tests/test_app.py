import datetime as dt
import json
import os

import pytest
from markupsafe import escape

from magic import create_app, data


@pytest.fixture()
def app(tmp_path, monkeypatch):
    for key in ("SSM_PARAM_PREFIX", "CONTACT_TABLE", "SES_SENDER", "NOTIFY_EMAIL"):
        monkeypatch.delenv(key, raising=False)
    app = create_app(
        {
            "TESTING": True,
            "WTF_CSRF_ENABLED": False,
            "RATELIMIT_ENABLED": False,
        }
    )
    app.instance_path = str(tmp_path)
    data.clear_cache()
    return app


@pytest.fixture()
def client(app):
    return app.test_client()


def test_healthz(client):
    resp = client.get("/healthz")
    assert resp.status_code == 200
    assert resp.get_json() == {"status": "ok"}


def test_index_lists_clubs(client):
    resp = client.get("/")
    assert resp.status_code == 200
    for club in data.get_clubs():
        # Jinja autoescapes, e.g. "Conjurers' Guild" -> "Conjurers&#39; Guild"
        assert escape(club["name"]).encode() in resp.data


def test_club_page_hides_contacts_without_consent(client):
    resp = client.get("/clubs/thistle-circle")
    assert resp.status_code == 200
    assert b"secretary@thistle-circle.example.org" in resp.data
    assert b"treasurer@thistle-circle.example.org" not in resp.data


def test_club_without_public_contacts_points_to_form(client):
    resp = client.get("/clubs/stirling-guild")
    assert resp.status_code == 200
    assert b"contact form" in resp.data


def test_every_club_page_renders(client):
    for club in data.get_clubs():
        assert client.get(f"/clubs/{club['slug']}").status_code == 200


def test_club_slugs_are_unique():
    slugs = [c["slug"] for c in data.get_clubs()]
    assert len(slugs) == len(set(slugs))


def test_unknown_club_is_404(client):
    assert client.get("/clubs/does-not-exist").status_code == 404


def test_events_hides_past_events(client):
    resp = client.get("/events")
    assert resp.status_code == 200
    assert b"Autumn Lecture That Already Happened" not in resp.data


def test_get_events_sorted_and_filtered():
    data.clear_cache()
    events = data.get_events(today=dt.date(2026, 1, 1))
    starts = [e["start_date"] for e in events]
    assert starts == sorted(starts)
    assert all(
        (e.get("end_date") or e["start_date"]) >= dt.date(2026, 1, 1) for e in events
    )


def test_contact_form_get(client):
    resp = client.get("/contact")
    assert resp.status_code == 200
    assert b"Send message" in resp.data


def test_contact_form_post_stores_locally(client, app):
    resp = client.post(
        "/contact",
        data={"name": "Tam", "email": "tam@example.org", "message": "Hello there"},
    )
    assert resp.status_code == 302
    assert resp.headers["Location"].endswith("/contact/thanks")
    path = os.path.join(app.instance_path, "submissions.jsonl")
    with open(path, encoding="utf-8") as fh:
        record = json.loads(fh.readline())
    assert record["name"] == "Tam"
    assert record["message"] == "Hello there"


def test_contact_form_validation_errors(client):
    resp = client.post("/contact", data={"name": "", "email": "nope", "message": ""})
    assert resp.status_code == 200
    assert b"error" in resp.data


def test_honeypot_stores_nothing(client, app):
    resp = client.post(
        "/contact",
        data={
            "name": "Bot",
            "email": "bot@example.org",
            "message": "Buy things",
            "website": "http://spam.example",
        },
    )
    assert resp.status_code == 302
    assert not os.path.exists(os.path.join(app.instance_path, "submissions.jsonl"))
