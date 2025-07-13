#!/bin/bash

# --- [ Input Function Helpers ] ---
prompt_input() {
    local var_name=$1
    local prompt=$2
    local validator=$3
    local error_msg=$4

    while true; do
        echo "$prompt"
        read -r value
        if [[ -z "$value" || "$value" == $'\0' ]]; then
            echo "Invalid input. $error_msg"
            continue
        fi
        if [[ -n "$validator" && ! "$value" =~ $validator ]]; then
            echo "$value is invalid. $error_msg"
            continue
        fi
        eval "$var_name=\"\$value\""
        break
    done
}

# --- [ Initial Setup ] ---
set -e  # Stop script execution on any error

if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root"
    exit 1
fi

# --- [ Inputs ] ---
prompt_input tk "Bot token: " "" "Token cannot be empty."
prompt_input chatid "Chat id: " "^-?[0-9]+$" "Chat id must be a number."
echo "Caption (e.g., your domain, to identify the backup):"
read -r caption

# Cronjob Setup
while true; do
    echo "Cronjob (minutes and hours) (e.g : 30 6 or 0 12) : "
    read -r minute hour
    if [[ $minute =~ ^[0-9]+$ && $hour =~ ^[0-9]+$ && $minute -lt 60 && $hour -lt 24 ]]; then
        if [[ $minute == 0 && $hour == 0 ]]; then
            cron_time="0 0 * * *"
        elif [[ $minute == 0 ]]; then
            cron_time="0 */${hour} * * *"
        elif [[ $hour == 0 ]]; then
            cron_time="*/${minute} * * * *"
        else
            cron_time="*/${minute} */${hour} * * *"
        fi
        break
    else
        echo "Invalid input. Please enter numbers: minute(0-59), hour(0-23)."
    fi
done

prompt_input xmhs "x-ui or s-ui or marzban or hiddify? [x/s/m/h] : " "^[xmhs]$" "Please choose x, s, m or h."
prompt_input crontabs "Would you like the previous crontabs to be cleared? [y/n] : " "^[yn]$" "Please choose y or n."

# Clear previous crontabs if selected
[[ "$crontabs" == "y" ]] && sudo crontab -l | grep -vE '/root/ac-backup.+\.sh' | crontab -

# --- [ Backup Logic per Type ] ---
if [[ "$xmhs" == "m" ]]; then
    dir=$(find /opt /root -type d -iname "marzban" -print -quit)
    [[ -z "$dir" ]] && echo "Marzban folder not found." && exit 1

    if [[ -d "/var/lib/marzban/mysql" ]]; then
        path="/var/lib/marzban/mysql"
    elif [[ -d "/var/lib/mysql/marzban" ]]; then
        path="/var/lib/mysql/marzban"
    else
        echo "Neither Marzban MySQL path found." && exit 1
    fi

    sed -i -e 's/\s*=\s*/=/' -e 's/\s*:\s*/:/' -e 's/^\s*//' /opt/marzban/.env
    docker exec marzban-mysql-1 bash -c "mkdir -p /var/lib/mysql/db-backup"
    source /opt/marzban/.env

    cat > "$path/ac-backup.sh" <<EOL
#!/bin/bash
USER="root"
PASSWORD="$MYSQL_ROOT_PASSWORD"
databases=\$(mysql -h 127.0.0.1 --user=\$USER --password=\$PASSWORD -e "SHOW DATABASES;" | tr -d "| " | grep -v Database)
for db in \$databases; do
    if [[ "\$db" != "information_schema" && "\$db" != "mysql" && "\$db" != "performance_schema" && "\$db" != "sys" ]]; then
        echo "Dumping database: \$db"
        mysqldump -h 127.0.0.1 --force --opt --user=\$USER --password=\$PASSWORD --routines --databases \$db > /var/lib/mysql/db-backup/\$db.sql
    fi
done
EOL

    chmod +x "$path/ac-backup.sh"

    ZIP=$(cat <<EOF
#!/bin/bash
docker exec marzban-mysql-1 bash -c "/var/lib/mysql/ac-backup.sh"
zip -r /root/ac-backup-m.zip /opt/marzban/* /var/lib/marzban/* /opt/marzban/.env -x "$path/*"
if find "$path/db-backup/" -type f | grep -q .; then
    zip -r /root/ac-backup-m.zip "$path/db-backup/"*
else
    echo "No DB backups found to zip."
fi
rm -rf "$path/db-backup/"*
EOF
)
    ACh="marzban backup"

elif [[ "$xmhs" == "x" || "$xmhs" == "s" ]]; then
    dbDir=$(find /etc /opt/freedom /usr/local -type d \( -iname "x-ui*" -o -iname "s-ui" \) -print -quit)
    [[ -z "$dbDir" ]] && echo "UI folder not found." && exit 1

    case "$dbDir" in
        "/opt/freedom/x-ui"*) dbDir="$dbDir/db/x-ui.db"; ACh="x-ui backup" ;;
        "/usr/local/s-ui") dbDir="$dbDir/db/s-ui.db"; ACh="s-ui backup" ;;
        *) dbDir="$dbDir/x-ui.db"; ACh="x-ui backup" ;;
    esac

    configDir=$(find /usr/local -type d -iname "x-ui*" -print -quit)
    [[ -n "$configDir" ]] && configDir="$configDir/config.json"

    ZIP="zip /root/ac-backup-${xmhs}.zip ${dbDir} ${configDir}"

elif [[ "$xmhs" == "h" ]]; then
    [[ ! -d "/opt/hiddify-manager/hiddify-panel/backup" ]] && echo "Backup folder not found." && exit 1
    [[ -f "/opt/hiddify-manager/hiddify-panel/backup.sh" ]] && backupCommand="bash backup.sh" || backupCommand="python3 -m hiddifypanel backup"

    ZIP=$(cat <<EOF
#!/bin/bash
cd /opt/hiddify-manager/hiddify-panel/
if [ \$(find backup -type f | wc -l) -gt 100 ]; then
  find backup -type f -delete
fi
$backupCommand
cd backup
latest_file=\$(ls -t *.json | head -n1)
rm -f /root/ac-backup-h.zip
zip /root/ac-backup-h.zip "backup/\$latest_file"
EOF
)
    ACh="hiddify backup"
fi

# --- [ Caption + Execution Script ] ---
trim() {
    local var="$*"
    var="${var#"${var%%[![:space:]]*}"}"
    var="${var%"${var##*[![:space:]]}"}"
    echo -n "$var"
}

IP=$(ip route get 1 | sed -n 's/^.*src \([0-9.]*\) .*$/\1/p')
caption="${caption}\n\n${ACh}\n<code>${IP}</code>\nCreated by @ACh1992 - https://github.com/ach1992"
comment=$(echo -e "$caption" | sed 's/<code>//g;s/<\/code>//g')
comment=$(trim "$comment")

sudo apt install zip -y

cat > "/root/ac-backup-${xmhs}.sh" <<EOL
rm -rf /root/ac-backup-${xmhs}.zip
$ZIP
echo -e "$comment" | zip -z /root/ac-backup-${xmhs}.zip
curl -F chat_id="${chatid}" -F caption=\$'${caption}' -F parse_mode="HTML" -F document=@"/root/ac-backup-${xmhs}.zip" https://api.telegram.org/bot${tk}/sendDocument
EOL

chmod +x "/root/ac-backup-${xmhs}.sh"
{ crontab -l -u root; echo "${cron_time} /bin/bash /root/ac-backup-${xmhs}.sh >/dev/null 2>&1"; } | crontab -u root -
bash "/root/ac-backup-${xmhs}.sh"

echo -e "\nDone\n"
