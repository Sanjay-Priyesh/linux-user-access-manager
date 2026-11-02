# Linux User and Access Management System

A menu-driven Bash script for managing Linux users, groups, passwords, permissions, access checks, audit logs, and reports.

## Features

- Create, delete, lock, and unlock users
- Reset passwords and configure password ageing
- Create groups and manage group membership
- Set file/directory permissions and ownership
- Check user read, write, and execute access
- View failed-login summaries
- Maintain an audit log
- Export access reports

## Requirements

- Linux VM or system
- Bash
- Root/sudo access

## How to Run

```bash
chmod +x script.sh
sudo ./script.sh
```

## Important

Use this script only on a test VM or a system you are authorized to administer. It can create, modify, lock, or delete user accounts and change file permissions.

## Project Logic

The script uses a `while true` menu loop. Each menu option calls a Bash function that validates input, runs the required Linux command, displays the result, and records the action in `logs/audit.log`.
