#!/bin/bash

# تابعی برای گرفتن ورودی‌ها
get_input() {
  local var_name="$1"
  local prompt="$2"
  local pattern="$3"
  
  while [[ -z "${!var_name}" ]]; do
    echo "$prompt"
    read -r "$var_name"
    if [[ ${!var_name} == $'\0' ]]; then
      echo "Invalid input. Please try again."
      unset "$var_name"
    elif [[ ! ${!var_name} =~ $pattern ]]; then
      echo "Invalid input format."
      unset "$var_name"
    fi
  done
}

# گرفتن توکن
get_input "tk" "Bot token: " ".*"

# گرفتن شناسه چت
get_input "chatid" "Chat id: " "^-?[0-9]+$"

# گرفتن عنوان
echo "Caption (for example, your domain, to identify the database file more easily): "
read -r caption

# گرفتن زمان cron
while true; do
  echo "Cronjob (minutes and hours) (e.g : 30 6 or 0 12) : "
  read -r minute hour
  if [[ -z "$minute" || -z "$hour" ]]; then
    echo "Both minute and hour must be provided."
    continue
  elif [[ $minute =~ ^[0-9]+$ ]] && [[ $hour =~ ^[0-9]+$ ]] && [[ $hour -lt 24 ]] && [[ $minute -lt 60 ]]; then
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
    echo "Invalid input, please enter a valid cronjob format (e.g: 0 6 or 30 12)"
  fi
done

# گرفتن نوع نرم‌افزار
get_input "xmhs" "x-ui or s-ui or marzban or hiddify? [x/s/m/h] : " "^[xmhs]$"

# بررسی و گرفتن ورودی crontab
get_input "crontabs" "Would you like the previous crontabs to be cleared? [y/n] : " "^[yn]$"

# پاک کردن crontab قبلی در صورت نیاز
if [[ "$crontabs" == "y" ]]; then
  sudo crontab -l | grep -vE '/root/ac-backup.+\.sh' | crontab -
fi

# بررسی و آماده‌سازی برای نرم‌افزار marzban
if [[ "$xmhs" == "m" ]]; then
  if dir=$(find /opt /root -type d -iname "marzban" -print -quit); then
    echo "The folder exists at $dir"
  else
    echo "The folder does not exist."
    exit 1
  fi

  if [ -d "/var/lib/marzban/mysql" ] || [ -d "/var/lib/mysql/marzban" ]; then
    path=""
    if [ -d "/var/lib/marzban/mysql" ]; then
      path="/var/lib/marzban/mysql"
    elif [ -d "/var/lib/mysql/marzban" ]; then
      path="/var/lib/mysql/marzban"
    else
      echo "Neither path exists."
      exit 1
    fi

    sed -i -e 's/\s*=\s*/=/' -e 's/\s*:\s*/:/' -e 's/^\s*//' /opt/marzban/.env
    docker exec marzban-mysql-1 bash -c "mkdir -p /var/lib/mysql/db-backup"
    source /opt/marzban/.env

    cat > "$path/ac-backup.sh" <<EOL
#!/bin/bash
USER="root"
PASSWORD="\$MYSQL_ROOT_PASSWORD"

databases=\$(mysql -h 127.0.0.1 --user=\$USER --password=\$PASSWORD -e "SHOW DATABASES;" | tr -d "| " | grep -v Database)

for db in \$databases; do
    if [[ "\$db" != "information_schema" ]] && [[ "\$db" != "mysql" ]] && [[ "\$db" != "performance_schema" ]] && [[ "\$db" != "sys" ]] ; then
        echo "Dumping database: \$db"
        mysqldump -h 127.0.0.1 --force --opt --user=\$USER --password=\$PASSWORD --routines --databases \$db > /var/lib/mysql/db-backup/\$db.sql
    fi
done
EOL
    chmod +x "$path/ac-backup.sh"

    ZIP=$(cat <<EOF
#!/bin/bash
docker exec marzban-mysql-1 bash -c "/var/lib/mysql/ac-backup.sh"
zip -r /root/ac-backup-m.zip /opt/marzban/* /var/lib/marzban/* /opt/marzban/.env -x "$path/\*"
zip -r /root/ac-backup-m.zip "$path/db-backup/*"
rm -rf "$path/db-backup/*"
EOF
    )

  else
    ZIP="zip -r /root/ac-backup-m.zip ${dir}/* /var/lib/marzban/* /opt/marzban/.env"
  fi

  ACh="marzban backup"

# بررسی و آماده‌سازی برای نرم‌افزارهای دیگر (x-ui, s-ui)
elif [[ "$xmhs" == "x" || "$xmhs" == "s" ]]; then
  ACh=""
  dbDir=$(find /etc /opt/freedom /usr/local -type d \( -iname "x-ui*" -o -iname "s-ui" \) -print -quit 2>/dev/null)

  if [[ -n "${dbDir}" ]]; then
    echo "The folder exists at $dbDir"
    if [[ $dbDir == "/opt/freedom/x-ui"* ]]; then
      dbDir="${dbDir}/db/x-ui.db"
      ACh="x-ui backup"
    elif [[ $dbDir == "/usr/local/s-ui" ]]; then
      dbDir="${dbDir}/db/s-ui.db"
      ACh="s-ui backup"
    else
      dbDir="${dbDir}/x-ui.db"
      ACh="x-ui backup"
    fi
  else
    echo "The folder does not exist."
    exit 1
  fi

  configDir=$(find /usr/local -type d -iname "x-ui*" -print -quit 2>/dev/null)
  if [[ -n "${configDir}" ]]; then
    configDir="${configDir}/config.json"
  else
    configDir="."
  fi

  ZIP="zip /root/ac-backup-${xmhs}.zip ${dbDir} ${configDir}"

# بررسی و آماده‌سازی برای hiddify
elif [[ "$xmhs" == "h" ]]; then
  if ! find /opt/hiddify-manager/hiddify-panel/ -type d -iname "backup" -print -quit; then
    echo "The folder does not exist."
    exit 1
  fi

  if [ -f "/opt/hiddify-manager/hiddify-panel/backup.sh" ]; then
    backupCommand="bash backup.sh"
  else
    backupCommand="python3 -m hiddifypanel backup"
  fi

  ZIP=$(cat <<EOF
#!/bin/bash
cd /opt/hiddify-manager/hiddify-panel/
if [ $(find /opt/hiddify-manager/hiddify-panel/backup -type f | wc -l) -gt 100 ]; then
  find /opt/hiddify-manager/hiddify-panel/backup -type f -delete
fi

$backupCommand

cd /opt/hiddify-manager/hiddify-panel/backup
latest_file=\$(ls -t *.json | head -n1)
rm -f /root/ac-backup-h.zip
zip /root/ac-backup-h.zip /opt/hiddify-manager/hiddify-panel/backup/\$latest_file
EOF
  )
  ACh="hiddify backup"
else
  echo "Please choose m or x or h only !"
  exit 1
fi

# تابع trim برای حذف فاصله‌های اضافی
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

# نصب zip در صورت نیاز
if ! command -v zip &>/dev/null; then
  sudo apt install zip -y
fi

# نوشتن اسکریپت نهایی
cat > "/root/ac-backup-${xmhs}.sh" <<EOL
rm -rf /root/ac-backup-${xmhs}.zip
$ZIP &
wait $!
echo -e "$comment" | zip -z /root/ac-backup-${xmhs}.zip
curl -F chat_id="${chatid}" -F caption=\$'${caption}' -F parse_mode="HTML" -F document=@"/root/ac-backup-${xmhs}.zip" https://api.telegram.org/bot${tk}/sendDocument
EOL

# افزودن کرون‌جاب
{ crontab -l -u root; echo "${cron_time} /bin/bash /root/ac-backup-${xmhs}.sh >/dev/null 2>&1"; } | crontab -u root -

# اجرای اسکریپت
bash "/root/ac-backup-${xmhs}.sh"

echo -e "\nDone\n"
