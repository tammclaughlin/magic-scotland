import logging

from flask import (
    Blueprint,
    abort,
    current_app,
    redirect,
    render_template,
    request,
    url_for,
)

from . import limiter
from .data import get_club, get_clubs, get_events
from .forms import ContactForm
from .storage import build_record, notify, save_submission

bp = Blueprint("main", __name__)
log = logging.getLogger(__name__)


@bp.get("/")
def index():
    return render_template("index.html", clubs=get_clubs())


@bp.get("/clubs/<slug>")
def club(slug):
    found = get_club(slug)
    if found is None:
        abort(404)
    return render_template("club.html", club=found)


@bp.get("/events")
def events():
    return render_template("events.html", events=get_events())


@bp.route("/contact", methods=["GET", "POST"])
@limiter.limit("5 per minute; 30 per day", methods=["POST"])
def contact():
    form = ContactForm()
    if form.validate_on_submit():
        if form.website.data:
            # Honeypot filled in: pretend it worked, store nothing.
            log.info("Honeypot triggered from %s", request.remote_addr)
            return redirect(url_for("main.thanks"))
        settings = current_app.config["SETTINGS"]
        record = build_record(form.data, request.remote_addr)
        try:
            save_submission(settings, record, current_app.instance_path)
            notify(settings, record)
        except Exception:  # noqa: BLE001 - show a friendly page, log details
            log.exception("Failed to handle contact submission")
            return render_template("contact.html", form=form, failed=True), 503
        return redirect(url_for("main.thanks"))
    return render_template("contact.html", form=form)


@bp.get("/contact/thanks")
def thanks():
    return render_template("thanks.html")


@bp.get("/privacy")
def privacy():
    return render_template("privacy.html")


@bp.get("/healthz")
@limiter.exempt
def healthz():
    return {"status": "ok"}
