"""Scottish magic clubs website - Flask application factory."""

import logging
import os

from flask import Flask, render_template
from flask_limiter import Limiter
from flask_limiter.util import get_remote_address
from flask_wtf import CSRFProtect
from werkzeug.middleware.proxy_fix import ProxyFix

from .config import load_settings

csrf = CSRFProtect()
limiter = Limiter(key_func=get_remote_address, storage_uri="memory://")


def create_app(test_config=None):
    app = Flask(__name__, instance_relative_config=True)

    logging.basicConfig(
        level=os.environ.get("LOG_LEVEL", "INFO"),
        format="%(asctime)s %(levelname)s %(name)s %(message)s",
    )

    settings = load_settings()
    app.config.update(
        SECRET_KEY=settings["secret_key"] or "dev-only-not-secret",
        SETTINGS=settings,
        SITE_NAME=os.environ.get("SITE_NAME", "Magic Clubs of Scotland"),
        # Only trust X-Forwarded-* headers from one proxy (Nginx or the ALB).
        PROXY_HOPS=int(os.environ.get("PROXY_HOPS", "1")),
    )
    if test_config:
        app.config.update(test_config)

    if app.config["SECRET_KEY"] == "dev-only-not-secret" and not app.config.get(
        "TESTING"
    ):
        app.logger.warning("SECRET_KEY not set - using an insecure development key")

    if app.config["PROXY_HOPS"] > 0:
        app.wsgi_app = ProxyFix(
            app.wsgi_app, x_for=app.config["PROXY_HOPS"], x_proto=1, x_host=1
        )

    os.makedirs(app.instance_path, exist_ok=True)
    csrf.init_app(app)
    limiter.init_app(app)

    from .routes import bp

    app.register_blueprint(bp)

    @app.errorhandler(404)
    def not_found(_err):
        return render_template("404.html"), 404

    @app.context_processor
    def inject_site():
        return {"site_name": app.config["SITE_NAME"]}

    return app
