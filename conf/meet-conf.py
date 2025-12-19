# See https://github.com/suitenumerique/meet/blob/main/docker/files/usr/local/etc/gunicorn/meet.py for the list of variables

# Gunicorn-django settings
bind = ["127.0.0.1:__PORT_BACKEND__"]
name = "meet"
python_path = "__INSTALL_DIR__/src/backend"

# Run
graceful_timeout = 90
timeout = 90
workers = 3

# Logging
# Using '-' for the access log file makes gunicorn log accesses to stdout
accesslog = "-"
# Using '-' for the error log file makes gunicorn log errors to stderr
errorlog = "-"
loglevel = "info"
