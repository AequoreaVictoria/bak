#!/bin/sh
if [ ! "%READY%" = "ready" ] ; then
	echo "ERROR: Do not run this script directly!" >&2
	echo "       Please review './run.sh --help'." >&2
	exit 1
fi
set -x

# --  Alert
alert() {
	cat <<- EOF | sendmail -t
to:%ADMIN%
from:bak@%HOST%
subject:Backup failure!

Failed executing: $(echo "$1")
	EOF
}

# -- Scheduling
# If today's date isn't equal to MONTHLY from config, don't run $@.
monthly() {
	[ "$(date +%d)" != "%MONTHLY%" ] && return
	$@
}

# If the current day of the week isn't equal to WEEKLY, don't run $@.
weekly() {
	[ "$(date +%a)" != "%WEEKLY%" ] && return
	$@
}

# -- Backups
# Dump the selected database with options from config. sha512sum the result.
msqldump() {
	mysqldump -u%MSQLUSER% -h%MSQLHOST% -P%MSQLPORT% %MSQLOPS% --databases $2 \
		| nice -n 18 xz -c > %BAK%/files/%HOST%-%YMD%-$1.msql.xz
	if [ ! "$?" -eq "0" ]; then
		alert "mysqldump <name: $1> <databases: $2>"
		return
	fi
	sha512sum "%BAK%/files/%HOST%-%YMD%-$1.msql.xz"
}
psqldump() {
	pg_dump -U%PSQLUSER% -h%PSQLHOST% -p%PSQLPORT% %PSQLOPS% -d $2 -w \
		| nice -n 18 xz -c > %BAK%/files/%HOST%-%YMD%-$1.psql.xz
	if [ ! "$?" -eq "0" ]; then
		alert "psqldump <name: $1> <database: $2>"
		return
	fi
	sha512sum "%BAK%/files/%HOST%-%YMD%-$1.psql.xz"
}

# Create a .tar.xz of specified name and path. sha512sum the result.
tarxz() {
	tar cvJf "%BAK%/files/%HOST%-%YMD%-$1.tar.xz" "$2"
	if [ ! "$?" -eq "0" ]; then
		alert "tarxz <name: $1> <path: $2>"
		return
	fi
	sha512sum "%BAK%/files/%HOST%-%YMD%-$1.tar.xz"
}

# -- Clean-up
# Remove all .xz/.log files that do not match the directory exclude
# list or the date exclude list $1.
remove() {
	for i in $(eval "find '%BAK%/files' %EXCLUDE% -name '*.xz' $1")
	do
		rm "$i"
		if [ ! "$?" -eq "0" ]; then
			alert "remove <file: $i>"
			return
		fi
	done
	for i in $(eval "find '%BAK%/files' %EXCLUDE% -name '*.log' $1")
	do
		rm "$i"
		if [ ! "$?" -eq "0" ]; then
			alert "remove <file: $i>"
			return
		fi
	done
}

# Remove all backups prior to the last month (cleanm) or week (cleanw).
# If $1 is passed, $1 additional months will be retained.
cleanm() {
	exclude=$(
		if [ -z "$1" ]; then months=1; else months="$1"; fi
		echo -n '-not -name "*'"$(date +%Y-%m)"'*" '
		for i in $(seq -s' ' 1 "$months") ; do
			echo -n '-not -name "*'"$(date --date="$i month ago" +%Y-%m)"'*" '
		done
	)
	remove "$exclude"
}
cleanw() {
	exclude=$(
		if [ -z "$1" ]; then weeks=1; else weeks="$1"; fi
		days=$(echo "7 * $weeks" |bc)
		for i in $(seq -s' ' 0 "$days") ; do
			echo -n '-not -name "*'"$(date --date="$i day ago" +%Y-%m-%d)"'*" '
		done
	)
	remove "$exclude"
}

# Remove all local backup files.
purge() {
	rm "%BAK%/files/*.xz %BAK%/files/bak_log/*.log"
	[ ! "$?" -eq "0" ] && \
		alert "purge <files: %BAK%/files/*.xz %BAK%/files/bak_log/*.log>"
}

# -- Transfer
# Sync to B2/S3. If $1 is '-rm', delete stale files from the remote location.
b2sync() {
	for i in $(seq 1 %RETRIES%); do
		b2 sync --noProgress --skipNewer \
			"%BAK%/files/" "b2://%BUCKET%/%HOST%/"
		[ "$?" -eq "0" ] && return
		sleep %DELAY%
	done
	alert "b2 sync"
}
s3sync() {
	for i in $(seq 1 %RETRIES%); do
		s3cmd sync --skip-existing \
			"%BAK%/files/" "s3://%BUCKET%/%HOST%/"
		[ "$?" -eq "0" ] && return
		sleep %DELAY%
	done
	alert "s3cmd sync"
}

# rsync pull path $3 from host $1 over port $2.
rsyncit() {
	for i in $(seq 1 %RETRIES%); do
		rsync -e "ssh -i .ssh/key -p$2" \
			-a --ignore-existing --temp-dir="%BAK%/tmp/" \
			"%HOST%@$1:$3" "%BAK%/files/$1/"
		[ "$?" -eq "0" ] && return
		sleep %DELAY%
	done
	alert "rsync <host: $1> <port: $2> <path: $3>"
}

# rsync pull the backup cache of remote machine $1 to ./files/$1/.
# $2 is the required remote port. $3 is the optional remote directory.
pull() {
	if [ -n "$3" ]; then
		rsyncit $1 $2 $3
	else
		rsyncit $1 $2 "files/"
	fi
}
