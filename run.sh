#!/bin/sh
# crontab: 0 4 * * * /bak/run.sh
cwd="$(dirname $0)"

if [ "$1" = "--configure" ]; then
	cat <<-'EOF' > $cwd/config
# Path to bak
bak="/bak"

# Address to send alerts.
admin=""

# Hostname of this machine.
host="$(hostname)"

# A 2-digit day of the month a monthly task will run.
monthly="16"

# A 3-letter day of the week a weekly task will run.
weekly="Wed"

# semicolon delimited list of directories inside ./files/ to exclude from
# cleanup functions. (i.e. exclude="example1;example2")
exclude=""

# MySQL user, password, host, port, options.
msqluser=""
msqlpass=""
msqlhost="localhost"
msqlport="3306"
msqlops=""

# Postgres user, password, host, port, options.
psqluser=""
psqlpass=""
psqlhost="localhost"
psqlport="5432"
psqlops=""

# Number of times to reattempt a network transfer.
retries="5"

# Delay between reattempts.
delay="15"

# Amazon S3 credentials.
s3access=""
s3secret=""

# Directory name to use on remote B2/S3 storage. B2 requires 6 characters.
bucket=""
	EOF
	chmod 600 $cwd/config
	cat <<-'EOF' > $cwd/tasks
### $variables are set in 'config' file
############################ Scheduling commands ############################
# monthly <task>                                                            #
# -- Run task on the $monthly (2-digit day) of each month.                  #
# weekly <task>                                                             #
# -- Run task on every $weekly (3-letter day) of the month.                 #
############################ Backup commands ################################
# msqldump <name> "<dbs>" # Multiple DBs                                    #
# psqldump <name> "<db>"  # Single DB only!                                 #
# -- Dump <dbs> as $host-(timestamp)-<name>.(m|p)sql.xz.                    #
# tarxz <name> "<paths>"                                                    #
# -- Compress <paths> into $host-(timestamp)-<name>.tar.xz.                 #
########################### Clean-up commands ###############################
# cleanm [<months>]                                                         #
# -- Remove backups older than <months> back, defaulting to one month prior.#
# cleanw [<weeks>]                                                          #
# -- Remove backups older than <weeks> back, defaulting to one week prior.  #
# purge                                                                     #
# -- Remove ./files/*.xz and ./files/*.log.                                 #
########################### Transfer commands ###############################
# b2sync/s3sync                                                             #
# -- Sync with b2|s3://$bucket/$host/                                       #
# pull <hostname> <port> [<path>]                                           #
# -- rsync pull the backup cache of <hostname> to ./files/<hostname>.       #
# -- [<path>] defaults to 'files/' if not specified.                        #
#############################################################################

	EOF
	echo "run.sh: 'config' and 'tasks' have been written; please edit them!"
	exit 0
elif [ "$1" ]; then
	echo "USAGE:"
	echo "    ./run.sh"
	echo "	Run to execute 'tasks'."
	echo "    ./run.sh --configure"
	echo "	Write default 'config' and 'tasks' file."
	exit 0
fi

# Load config if present, otherwise error.
if [ -f $cwd/config ]; then
	. $cwd/config

	# These variables affect naming; they probably do not need adjustment.
	uuid="$(uuidgen)"
	ymd="$(date +%Y-%m-%d)"
	log="$bak/files/bak_log/$host-$ymd.log"
else
	echo "ERROR: config missing!" >&2
	exit 1
fi

# Verify that sendmail is present.
if ! type sendmail >/dev/null 2>&1 ; then
	echo "ERROR: sendmail not found in PATH!" >&2
	exit 1
fi

# Reports run.sh errors to console and email.
alert() {
	echo "$1" >&2
	cat <<- EOF | sendmail -t
to:$admin
from:bak@$host
subject:Backup could not start!

ERROR: $(echo "$1")
	EOF
	exit 1
}

# Verify security of 'config' file.
[ "$(stat -c "%a" $bak/config)" -ne "600" ] && alert "Run 'chmod 600 config'!"

# Create $bak/files if it is missing.
[ -d "$bak/files" ] || mkdir -p "$bak/files" || alert "Could not make $bak/files!"

# Create $bak/tmp if it is missing.
[ -d "$bak/tmp" ] || mkdir -p "$bak/tmp" || alert "Could not make $bak/tmp!"

# Securely set up MySQL password.
if [ "$msqlpass" != "" ]; then
	cat <<-EOF > ~/.my.cnf || alert "Could not write ~/.my.conf!"
	[client]
	password=$msqlpass
	EOF
	chmod 600 ~/.my.cnf || alert "Could not chmod ~/.my.conf!"
fi

# Securely set up Postgres password.
if [ "$psqlpass" != "" ]; then
	cat <<-EOF > ~/.pgpass || alert "Could not write ~/.pgpass!"
	*:*:*:*:$psqlpass
	EOF
	chmod 600 ~/.pgpass || alert "Could not chmod ~/.pgpass!"
fi

# Securely set up Amazon S3 credentials.
if [ "$s3access" != "" ]; then
	cat <<-EOF > ~/.s3cfg || alert "Could not write ~/.s3cfg!"
	[default]
	access_key = $s3access
	secret_key = $s3secret
	EOF
	chmod 600 ~/.s3cfg || alert "Could not chmod ~/.s3cfg!"
fi

# Verify tasks are present.
[ -f tasks ] || alert "tasks file missing!"

# Verify that needed commands for tasks are present.
for i in uuidgen sha512sum xz rsync ; do
	if ! type "$i" >/dev/null 2>&1 ; then
		alert "$i not found in PATH!"
	fi
done
if grep -q "^msqldump" tasks && ! type "mysqldump" >/dev/null 2>&1 ; then
	alert "mysqldump not found in PATH!"
fi
if grep -q "^psqldump" tasks && ! type "pg_dump" >/dev/null 2>&1 ; then
	alert "pg_dump not found in PATH!"
fi
if grep -q "^s3sync" tasks && ! type "s3cmd" >/dev/null 2>&1 ; then
	alert "s3cmd not found in PATH!"
fi
if grep -q "^b2sync" tasks && ! type "b2" >/dev/null 2>&1 ; then
	alert "b2 not found in PATH!"
fi

# Combine the `bak.sh` template with today's `tasks`,
# using $uuid to avoid collisions.
cat bak.sh tasks > "/tmp/bak.sh.tasks.$uuid" || \
	alert "Could not create /tmp/bak.sh.tasks.$uuid!"

# Add a self-destruct command to the new template.
echo "rm /tmp/bak.sh.tasks.$uuid" >> "/tmp/bak.sh.tasks.$uuid" || \
	alert "Could not append /tmp/bak.sh.tasks.$uuid!"

# Generate a directory exclude list for cleaning functions using `find`.
exclude2=""
for i in $(echo "$exclude" |tr ';' '\n'); do
	exclude2="$exclude2"' -not \\\\( -path ./files/'"$i"' -prune \\\\) '
done

# The new 'bak.sh' template is now rewritten with %PREPROCESSOR%
# variables sourced from `config` and this script.
sed -i -e "s|%ADMIN%|$admin|g" -e "s|%HOST%|$host|g" -e "s|%BAK%|$bak|g" \
	-e "s|%YMD%|$ymd|g" -e "s|%MONTHLY%|$monthly|g" -e "s|%WEEKLY%|$weekly|g" \
	-e "s|%MSQLUSER%|$msqluser|g" -e "s|%MSQLHOST%|$msqlhost|g" \
	-e "s|%MSQLPORT%|$msqlport|g" -e "s|%MSQLOPS%|$msqlops|g" \
	-e "s|%PSQLUSER%|$psqluser|g" -e "s|%PSQLHOST%|$psqlhost|g" \
	-e "s|%PSQLPORT%|$psqlport|g" -e "s|%PSQLOPS%|$psqlops|g" \
	-e "s|%RETRIES%|$retries|g" -e "s|%DELAY%|$delay|g" \
	-e "s|%BUCKET%|$bucket|g" -e "s|%EXCLUDE%|$exclude2|g" \
	-e "s|%READY%|ready|g" \
	"/tmp/bak.sh.tasks.$uuid" || \
		alert "Could not rewrite /tmp/bak.sh.tasks.$uuid!"

# Set the new template to executable.
chmod +x "/tmp/bak.sh.tasks.$uuid" || \
	alert "Could not chmod /tmp/bak.sh.tasks.$uuid!"

# Run the template with logging.
"/tmp/bak.sh.tasks.$uuid" > "$log" 2>&1
