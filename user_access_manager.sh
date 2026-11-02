#!/bin/bash
#=====================================================================
#  LINUX USER AND ACCESS MANAGEMENT SYSTEM  -  Linux Micro Project
#  Language : Bash shell scripting + standard Linux commands
#  Run as   : sudo ./user_access_manager.sh   (root rights are needed)
#  Files    : logs/audit.log  (every action)   reports/  (exported reports)
#=====================================================================

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="$BASE_DIR/logs"
REPORT_DIR="$BASE_DIR/reports"
AUDIT_LOG="$LOG_DIR/audit.log"
ACTOR="${SUDO_USER:-$(whoami)}"          # the person who ran the script
MIN_UID=1000                             # normal (human) users start here
MIN_PASS_LEN=8
RED=$'\e[31m'; GREEN=$'\e[32m'; YELLOW=$'\e[33m'; CYAN=$'\e[36m'; BOLD=$'\e[1m'; RESET=$'\e[0m'

# ---------- Setup ----------
init() {
    if [[ $EUID -ne 0 ]]; then
        echo "${RED}[ERROR] This tool changes system accounts and must run with root rights.${RESET}"
        echo "        Run it like this:  sudo ./user_access_manager.sh"
        exit 1
    fi
    mkdir -p "$LOG_DIR" "$REPORT_DIR"
    touch "$AUDIT_LOG"
}

# ---------- Small helpers ----------
msg_ok()   { echo -e "${GREEN}[OK]    $1${RESET}"; }
msg_err()  { echo -e "${RED}[ERROR] $1${RESET}"; }
msg_info() { echo -e "${YELLOW}[INFO]  $1${RESET}"; }
pause()    { read -rp "Press Enter to continue..." _ || exit 0; }
confirm()  { local c; read -rp "$1 (y/n): " c; [[ $c == [yY] ]]; }

log_action() {                           # ACTION TARGET RESULT
    printf '%s | by=%s | %-20s | %-20s | %s\n' \
        "$(date '+%Y-%m-%d %H:%M:%S')" "$ACTOR" "$1" "$2" "$3" >> "$AUDIT_LOG"
}

# ---------- Validation ----------
valid_name()   { [[ $1 =~ ^[a-z_][a-z0-9_-]{2,31}$ ]]; }       # user / group names
valid_mode()   { [[ $1 =~ ^[0-7]{3,4}$ ]]; }                   # e.g. 750, 2770
valid_text()   { [[ $1 =~ ^[A-Za-z\ ]{0,40}$ ]]; }             # full name
user_exists()  { id "$1" &>/dev/null; }
group_exists() { getent group "$1" &>/dev/null; }
is_normal_user() { local u; u=$(id -u "$1" 2>/dev/null) || return 1; (( u >= MIN_UID && u < 65534 )); }

# a user the script must never delete or lock
is_protected() { [[ $1 == "$ACTOR" || $1 == root ]] || ! is_normal_user "$1"; }

# paths that must never be changed by option 11
is_critical_path() {
    case "$1" in
        /|/etc|/bin|/sbin|/usr|/lib|/lib64|/boot|/dev|/proc|/sys|/var|/root|/home|/run|/opt) return 0 ;;
        *) return 1 ;;
    esac
}

status_of() {                            # password status in words
    case "$(passwd -S "$1" 2>/dev/null | awk '{print $2}')" in
        P)  echo "Active" ;;
        L)  echo "Locked" ;;
        NP) echo "No password" ;;
        *)  echo "Unknown" ;;
    esac
}

read_password() {                        # sets PASS, never logs it
    local p1 p2
    read -rsp "Enter password (min $MIN_PASS_LEN chars): " p1; echo
    [[ ${#p1} -ge $MIN_PASS_LEN ]] || { msg_err "Password must be at least $MIN_PASS_LEN characters."; return 1; }
    read -rsp "Confirm password: " p2; echo
    [[ "$p1" == "$p2" ]] || { msg_err "Passwords do not match."; return 1; }
    PASS="$p1"
}

ask_user() {                             # prompt -> sets TARGET, checks it exists
    read -rp "$1" TARGET
    valid_name "$TARGET" || { msg_err "Invalid username (lowercase letters, digits, - _ ; 3-32 chars)."; return 1; }
    user_exists "$TARGET" || { msg_err "User '$TARGET' does not exist."; return 1; }
}

# ---------- 1. Create user ----------
create_user() {
    echo -e "\n${BOLD}--- Create New User ---${RESET}"
    local u fn sh
    read -rp "New username          : " u
    valid_name "$u"  || { msg_err "Invalid username (lowercase letters, digits, - _ ; 3-32 chars)."; return; }
    user_exists "$u" && { msg_err "User '$u' already exists."; return; }
    read -rp "Full name (optional)  : " fn
    valid_text "$fn" || { msg_err "Full name may contain only letters and spaces."; return; }
    read -rp "Login shell [/bin/bash]: " sh; sh=${sh:-/bin/bash}
    grep -qx "$sh" /etc/shells || { msg_err "Shell '$sh' is not listed in /etc/shells."; return; }
    read_password || return
    if useradd -m -s "$sh" -c "$fn" "$u" 2>/dev/null && echo "$u:$PASS" | chpasswd 2>/dev/null; then
        msg_ok "User '$u' created (UID $(id -u "$u"), home /home/$u)."
        log_action CREATE_USER "$u" SUCCESS
        confirm "Force password change at first login?" && chage -d 0 "$u" && msg_ok "Password must be changed at first login."
    else
        msg_err "Could not create user '$u'."
        log_action CREATE_USER "$u" FAILED
    fi
    unset PASS
}

# ---------- 2. Delete user ----------
delete_user() {
    echo -e "\n${BOLD}--- Delete User ---${RESET}"
    ask_user "Username to delete: " || return
    local u=$TARGET
    is_protected "$u" && { msg_err "'$u' is protected (system account or the account you are using)."; return; }
    pgrep -u "$u" >/dev/null && { msg_err "'$u' has running processes. Log the user out first."; return; }
    id "$u"
    confirm "Delete user '$u'?" || { msg_info "Deletion cancelled."; return; }
    local opt=()
    confirm "Also remove the home directory and mail?" && opt=(-r)
    if userdel "${opt[@]}" "$u" 2>/dev/null; then
        msg_ok "User '$u' deleted."; log_action DELETE_USER "$u" SUCCESS
    else
        msg_err "Could not delete '$u'."; log_action DELETE_USER "$u" FAILED
    fi
}

# ---------- 3. Lock / unlock ----------
lock_unlock() {
    echo -e "\n${BOLD}--- Lock / Unlock User ---${RESET}"
    ask_user "Username: " || return
    local u=$TARGET
    is_protected "$u" && { msg_err "'$u' is protected and cannot be locked or unlocked here."; return; }
    echo "Current status: $(status_of "$u")"
    echo "1) Lock account   2) Unlock account"
    local c; read -rp "Choice: " c
    case $c in
        1) usermod -L "$u" && { msg_ok "'$u' is now $(status_of "$u")."; log_action LOCK_USER "$u" SUCCESS; } || msg_err "Lock failed." ;;
        2) usermod -U "$u" && { msg_ok "'$u' is now $(status_of "$u")."; log_action UNLOCK_USER "$u" SUCCESS; } || msg_err "Unlock failed." ;;
        *) msg_err "Invalid choice." ;;
    esac
}

# ---------- 4. Reset password ----------
reset_password() {
    echo -e "\n${BOLD}--- Reset Password ---${RESET}"
    ask_user "Username: " || return
    local u=$TARGET
    is_normal_user "$u" || { msg_err "Only normal users (UID >= $MIN_UID) can be changed here."; return; }
    read_password || return
    if echo "$u:$PASS" | chpasswd 2>/dev/null; then
        msg_ok "Password changed for '$u'."; log_action RESET_PASSWORD "$u" SUCCESS
    else
        msg_err "Could not change the password."; log_action RESET_PASSWORD "$u" FAILED
    fi
    unset PASS
}

# ---------- 5. Password policy ----------
password_policy() {
    echo -e "\n${BOLD}--- Password Policy ---${RESET}"
    ask_user "Username: " || return
    local u=$TARGET
    is_normal_user "$u" || { msg_err "Only normal users (UID >= $MIN_UID) can be changed here."; return; }
    echo "1) Force password change at next login   2) Set maximum password age (days)"
    local c d; read -rp "Choice: " c
    case $c in
        1) chage -d 0 "$u" && { msg_ok "'$u' must change the password at next login."; log_action FORCE_CHANGE "$u" SUCCESS; } ;;
        2) read -rp "Maximum days (1-365): " d
           [[ $d =~ ^[0-9]{1,3}$ ]] && (( d >= 1 && d <= 365 )) || { msg_err "Enter a number from 1 to 365."; return; }
           chage -M "$d" "$u" && { msg_ok "Password of '$u' now expires every $d days."; log_action SET_MAX_AGE "$u" "$d days"; } ;;
        *) msg_err "Invalid choice." ;;
    esac
}

# ---------- 6. Create group ----------
create_group() {
    echo -e "\n${BOLD}--- Create Group ---${RESET}"
    local g; read -rp "New group name: " g
    valid_name "$g"  || { msg_err "Invalid group name (lowercase letters, digits, - _ ; 3-32 chars)."; return; }
    group_exists "$g" && { msg_err "Group '$g' already exists."; return; }
    if groupadd "$g" 2>/dev/null; then
        msg_ok "Group '$g' created (GID $(getent group "$g" | cut -d: -f3))."; log_action CREATE_GROUP "$g" SUCCESS
    else
        msg_err "Could not create group."; log_action CREATE_GROUP "$g" FAILED
    fi
}

# ---------- 7 & 8. Group membership ----------
group_member() {                         # add | remove
    local title; [[ $1 == add ]] && title="Add User to Group" || title="Remove User from Group"
    echo -e "\n${BOLD}--- $title ---${RESET}"
    ask_user "Username: " || return
    local u=$TARGET g
    is_normal_user "$u" || { msg_err "Only normal users (UID >= $MIN_UID) can be changed here."; return; }
    read -rp "Group name: " g
    valid_name "$g"   || { msg_err "Invalid group name."; return; }
    group_exists "$g" || { msg_err "Group '$g' does not exist."; return; }
    if [[ $1 == add ]]; then
        usermod -aG "$g" "$u" && { msg_ok "'$u' added to '$g'."; log_action ADD_TO_GROUP "$u" "$g"; } || msg_err "Failed."
    else
        id -nG "$u" | tr ' ' '\n' | grep -qx "$g" || { msg_err "'$u' is not a member of '$g'."; return; }
        gpasswd -d "$u" "$g" &>/dev/null && { msg_ok "'$u' removed from '$g'."; log_action REMOVE_FROM_GROUP "$u" "$g"; } || msg_err "Cannot remove (is '$g' the primary group?)."
    fi
    echo "Groups of $u: $(id -nG "$u")"
}

# ---------- 9. List users ----------
list_users() {
    echo
    printf "${CYAN}${BOLD}%-14s %-6s %-22s %-14s %-12s${RESET}\n" "USER" "UID" "HOME" "SHELL" "STATUS"
    echo "------------------------------------------------------------------"
    local n=0 u uid home sh
    while IFS=: read -r u _ uid _ _ home sh; do
        (( uid >= MIN_UID && uid < 65534 )) || continue
        printf "%-14s %-6s %-22s %-14s %-12s\n" "$u" "$uid" "$home" "$sh" "$(status_of "$u")"
        n=$((n+1))
    done < /etc/passwd
    echo "------------------------------------------------------------------"
    echo "Normal users: $n"
}

# ---------- 10. User details ----------
user_details() {
    echo -e "\n${BOLD}--- User Details ---${RESET}"
    ask_user "Username: " || return
    local u=$TARGET
    echo "Account  : $(getent passwd "$u" | cut -d: -f1,5,6,7)"
    echo "IDs      : $(id "$u")"
    echo "Status   : $(status_of "$u")"
    echo "Home dir : $(ls -ld "$(getent passwd "$u" | cut -d: -f6)" 2>/dev/null | awk '{print $1, $3, $4, $9}')"
    echo "--- Password ageing ---"
    chage -l "$u" 2>/dev/null
    if command -v lastlog &>/dev/null; then echo "--- Last login ---"; lastlog -u "$u" 2>/dev/null; fi
}

# ---------- 11. Permissions and ownership ----------
set_permissions() {
    echo -e "\n${BOLD}--- Set Permissions and Ownership ---${RESET}"
    local path mode owner grp rec=() spec
    read -rp "Path (file or directory): " path
    [[ -n $path && -e $path ]] || { msg_err "Path does not exist."; return; }
    path=$(realpath "$path")
    is_critical_path "$path" && { msg_err "'$path' is a protected system path and cannot be changed."; return; }
    echo "Current: $(stat -c '%A %a %U:%G %n' "$path")"
    read -rp "New permission mode (e.g. 750, 2770): " mode
    valid_mode "$mode" || { msg_err "Mode must be 3 or 4 octal digits."; return; }
    read -rp "New owner (blank = keep)          : " owner
    read -rp "New group (blank = keep)          : " grp
    [[ -z $owner ]] || user_exists  "$owner" || { msg_err "User '$owner' does not exist."; return; }
    [[ -z $grp   ]] || group_exists "$grp"   || { msg_err "Group '$grp' does not exist."; return; }
    [[ -d $path ]] && confirm "Apply to everything inside the directory (recursive)?" && rec=(-R)
    confirm "Apply these changes to '$path'?" || { msg_info "Cancelled."; return; }
    if chmod "${rec[@]}" "$mode" "$path"; then
        spec="${owner}:${grp}"
        [[ $spec == ":" ]] || chown "${rec[@]}" "$spec" "$path"
        msg_ok "Updated.  Now: $(stat -c '%A %a %U:%G %n' "$path")"
        log_action SET_PERMISSIONS "$path" "mode=$mode owner=${owner:--} group=${grp:--}"
    else
        msg_err "Could not change permissions."; log_action SET_PERMISSIONS "$path" FAILED
    fi
}

# ---------- 12. Check access ----------
check_access() {
    echo -e "\n${BOLD}--- Check User Access to a Path ---${RESET}"
    ask_user "Username: " || return
    local u=$TARGET path p r
    read -rp "Path: " path
    [[ -n $path && -e $path ]] || { msg_err "Path does not exist."; return; }
    path=$(realpath "$path")
    echo "Path     : $(stat -c '%A %a %U:%G %n' "$path")"
    echo "Groups of $u: $(id -nG "$u")"
    printf "${CYAN}${BOLD}%-10s %-8s${RESET}\n" "ACCESS" "ALLOWED"
    for p in r w x; do
        case $p in r) r=Read ;; w) r=Write ;; x) r=Execute ;; esac
        if runuser -u "$u" -- test -$p "$path" 2>/dev/null; then printf "%-10s ${GREEN}YES${RESET}\n" "$r"
        else printf "%-10s ${RED}NO${RESET}\n" "$r"; fi
    done
    log_action CHECK_ACCESS "$u" "$path"
}

# ---------- 13. Failed logins ----------
failed_logins() {
    echo -e "\n${BOLD}--- Failed Login Summary ---${RESET}"
    if [[ -r /var/log/auth.log ]] && grep -q "Failed password" /var/log/auth.log; then
        echo "Source: /var/log/auth.log"
        printf "${CYAN}${BOLD}%-8s %-18s %-16s${RESET}\n" "COUNT" "USER" "FROM"
        grep "Failed password" /var/log/auth.log | sed 's/invalid user //' \
          | awk '{for(i=1;i<=NF;i++){if($i=="for")u=$(i+1); if($i=="from")ip=$(i+1)} print u, ip}' \
          | sort | uniq -c | sort -nr | head -10 | awk '{printf "%-8s %-18s %-16s\n",$1,$2,$3}'
    elif command -v lastb &>/dev/null && [[ -s /var/log/btmp ]]; then
        echo "Source: lastb (/var/log/btmp)"
        lastb -n 20 2>/dev/null
    else
        msg_info "No failed login records were found on this system."
    fi
    log_action VIEW_FAILED_LOGINS "-" SUCCESS
}

# ---------- 14. Audit log ----------
view_audit() {
    echo -e "\n${BOLD}--- Audit Log (last 20 actions) ---${RESET}"
    if [[ ! -s $AUDIT_LOG ]]; then msg_info "The audit log is empty."; return; fi
    tail -n 20 "$AUDIT_LOG"
    echo "Total entries: $(wc -l < "$AUDIT_LOG")"
}

# ---------- 15. Export report ----------
export_report() {
    local f="$REPORT_DIR/access_report_$(date +%Y%m%d_%H%M%S).txt"
    {
        echo "USER AND ACCESS REPORT  -  Generated: $(date '+%d-%b-%Y %H:%M')  by $ACTOR  on $(hostname)"
        echo "--------------------------------------------------------------------"
        echo "NORMAL USERS"
        awk -F: -v m="$MIN_UID" '$3>=m && $3<65534 {printf "  %-14s UID %-6s %s\n",$1,$3,$7}' /etc/passwd
        echo
        echo "LOCKED ACCOUNTS"
        local l=0 u
        for u in $(awk -F: -v m="$MIN_UID" '$3>=m && $3<65534 {print $1}' /etc/passwd); do
            [[ $(status_of "$u") == Locked ]] && { echo "  $u"; l=$((l+1)); }
        done
        (( l == 0 )) && echo "  none"
        echo
        echo "GROUPS (GID >= $MIN_UID) AND MEMBERS"
        awk -F: -v m="$MIN_UID" '$3>=m && $3<65534 {printf "  %-14s GID %-6s members: %s\n",$1,$3,($4==""?"-":$4)}' /etc/group
        echo
        echo "LAST 10 AUDIT ENTRIES"
        tail -n 10 "$AUDIT_LOG" | sed 's/^/  /'
    } > "$f"
    msg_ok "Report exported to ${f#$BASE_DIR/} ($(wc -l < "$f") lines)."
    log_action EXPORT_REPORT "${f##*/}" SUCCESS
}

# ---------- Menu ----------
show_menu() {
    clear 2>/dev/null
    echo -e "${CYAN}${BOLD}==============================================${RESET}"
    echo -e "${CYAN}${BOLD}   LINUX USER AND ACCESS MANAGEMENT SYSTEM    ${RESET}"
    echo -e "${CYAN}${BOLD}==============================================${RESET}"
    echo " Logged in as: $ACTOR   Host: $(hostname)"
    echo " Date: $(date '+%d-%b-%Y %H:%M')"
    echo "----------------------------------------------"
    echo " 1. Create user          9. List users"
    echo " 2. Delete user         10. User details"
    echo " 3. Lock / unlock user  11. Set permissions"
    echo " 4. Reset password      12. Check user access"
    echo " 5. Password policy     13. Failed logins"
    echo " 6. Create group        14. View audit log"
    echo " 7. Add user to group   15. Export report"
    echo " 8. Remove from group    0. Exit"
    echo "----------------------------------------------"
}

trap 'echo; msg_info "Interrupted. Exiting safely."; exit 130' INT

init
while true; do
    show_menu
    read -rp "Enter your choice [0-15]: " choice || { echo; exit 0; }
    case $choice in
        1)  create_user ;;
        2)  delete_user ;;
        3)  lock_unlock ;;
        4)  reset_password ;;
        5)  password_policy ;;
        6)  create_group ;;
        7)  group_member add ;;
        8)  group_member remove ;;
        9)  list_users ;;
        10) user_details ;;
        11) set_permissions ;;
        12) check_access ;;
        13) failed_logins ;;
        14) view_audit ;;
        15) export_report ;;
        0)  echo "Thank you. Goodbye!"; exit 0 ;;
        *)  msg_err "Invalid choice '$choice'. Enter a number from 0 to 15." ;;
    esac
    echo; pause
done
