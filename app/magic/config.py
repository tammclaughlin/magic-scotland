"""Load runtime settings.

Local development: settings come from environment variables
(SECRET_KEY, CONTACT_TABLE, SES_SENDER, NOTIFY_EMAIL) or stay empty.

On AWS (EC2 or Fargate): set SSM_PARAM_PREFIX, e.g. /magic-scotland/dev,
and the app reads the same settings from SSM Parameter Store using the
instance or task IAM role. Terraform creates those parameters.
"""

import logging
import os

log = logging.getLogger(__name__)

KEYS = ("secret_key", "contact_table", "ses_sender", "notify_email")


def load_settings():
    settings = {key: os.environ.get(key.upper(), "") for key in KEYS}

    prefix = os.environ.get("SSM_PARAM_PREFIX", "").rstrip("/")
    if not prefix:
        return settings

    import boto3  # imported lazily so local dev works without AWS

    region = os.environ.get("AWS_REGION") or os.environ.get("AWS_DEFAULT_REGION")
    ssm = boto3.client("ssm", region_name=region)
    names = [f"{prefix}/{key}" for key in KEYS]
    resp = ssm.get_parameters(Names=names, WithDecryption=True)
    for param in resp.get("Parameters", []):
        key = param["Name"].rsplit("/", 1)[1]
        settings[key] = param["Value"]
    if resp.get("InvalidParameters"):
        log.warning("SSM parameters not found: %s", resp["InvalidParameters"])
    return settings
