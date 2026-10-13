"""Store contact form submissions and send a notification email.

- With CONTACT_TABLE set: write to DynamoDB. Otherwise append to a local
  JSON-lines file in the Flask instance folder (local development).
- With SES_SENDER and NOTIFY_EMAIL set: email a notification via SES.
"""

import datetime as dt
import json
import logging
import os
import uuid

log = logging.getLogger(__name__)


def build_record(form_data, remote_addr):
    return {
        "id": str(uuid.uuid4()),
        "created_at": dt.datetime.now(dt.timezone.utc).isoformat(),
        "name": form_data["name"],
        "email": form_data["email"],
        "club": form_data.get("club") or "",
        "message": form_data["message"],
        "remote_addr": remote_addr or "",
    }


def save_submission(settings, record, instance_path):
    table = settings.get("contact_table")
    if table:
        import boto3

        boto3.resource("dynamodb").Table(table).put_item(Item=record)
        log.info("Stored contact submission %s in DynamoDB", record["id"])
        return
    path = os.path.join(instance_path, "submissions.jsonl")
    with open(path, "a", encoding="utf-8") as fh:
        fh.write(json.dumps(record) + "\n")
    log.info("Stored contact submission %s in %s", record["id"], path)


def notify(settings, record):
    sender = settings.get("ses_sender")
    recipient = settings.get("notify_email")
    if not (sender and recipient):
        log.info("SES not configured - skipping notification email")
        return
    import boto3

    body = (
        f"New message from the website\n\n"
        f"Name:  {record['name']}\n"
        f"Email: {record['email']}\n"
        f"Club:  {record['club']}\n\n"
        f"{record['message']}\n\n"
        f"Ref: {record['id']}"
    )
    boto3.client("ses").send_email(
        Source=sender,
        Destination={"ToAddresses": [recipient]},
        ReplyToAddresses=[record["email"]],
        Message={
            "Subject": {"Data": f"Website contact: {record['name']}"},
            "Body": {"Text": {"Data": body}},
        },
    )
    log.info("Sent notification email for %s", record["id"])
