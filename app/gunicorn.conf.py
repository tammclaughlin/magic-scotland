import os

bind = os.environ.get("BIND", "0.0.0.0:8000")
workers = int(os.environ.get("WEB_CONCURRENCY", "2"))
threads = 2
timeout = 30
accesslog = "-"
errorlog = "-"
forwarded_allow_ips = "*"  # only reachable from Nginx / the ALB
