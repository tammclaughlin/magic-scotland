# syntax=docker/dockerfile:1
#
# The container version of ../../ansible/roles/nginx/tasks/main.yml:
#
#   Ansible role (EC2)                         Dockerfile (here)
#   apt: name=nginx                            FROM nginx:1.28-alpine
#   template: magic.conf.j2 -> sites-enabled   COPY default.conf /etc/nginx/conf.d/
#   file: remove sites-enabled/default         (the COPY overwrites the image's default.conf)
#   lineinfile: server_tokens off              (in default.conf)
#   command: nginx -t                          RUN nginx -t   (fails the build, not the deploy)
#   systemd: started, enabled                  CMD from the base image; ECS restarts it
#
# Ansible changes a running server in place, every time. This runs once, at build time,
# and the result is a read-only image you can run anywhere.

FROM nginx:1.28-alpine

COPY default.conf /etc/nginx/conf.d/default.conf

RUN nginx -t

EXPOSE 80

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD wget -q -O /dev/null http://127.0.0.1/healthz || exit 1

# CMD comes from nginx:alpine: nginx -g 'daemon off;'. It stays in the foreground
# because the container stops when PID 1 exits.
