#!/bin/bash
# Remove the user
userdel -r template

# Disable and stop the service
systemctl disable remove-user.service

# Remove the script and service file
rm -f /usr/local/bin/remove_user.sh
rm -f /etc/systemd/system/remove-user.service

# Reload systemd to reflect changes
systemctl daemon-reload
