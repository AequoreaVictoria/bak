#!/bin/sh
[ -z "$1" ] && echo "USAGE: ./add-user <host.name.tld>" && exit 1

if ! echo "$1" |egrep '^([[:alnum:]]+\.)?([[:alnum:]]+\.)?[[:alnum:]]+\.[[:alnum:]]+$'; then
	echo "error: invaid hostname!"; exit 1
fi

hostname="$1"

if [ ! -x /bin/sh-rsync ]; then
	cat <<-'EOF' > sh-rsync.c
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

char *msg = "rsync only!\n";

int main(int argc, char *argv []) {
	int i;
	char *str;
	char *buf = NULL;
	char **arg = NULL;

	if (argc < 3) {
		printf("%s", msg);
		return 1;
	}
	if (strncmp(argv [2], "rsync ", 6) != 0) {
		printf("%s", msg);
		return 2;
	}

	i = 0;
	buf = strdup(argv[2]);
	str = strtok(buf, " ");
	do {
		arg = (char **) realloc(arg, ++i * sizeof(*arg));
		arg[i - 1] = strdup(str);
	} while ((str = strtok(NULL, " ")) != NULL);

	arg = (char **) realloc(arg, ++i * sizeof(*arg));
	arg[i - 1] = NULL;

	execvp(arg[0], arg);
	return 0;
}
	EOF
	gcc -Os -static -o /bin/sh-rsync sh-rsync.c >/dev/null 2>&1
	rm sh-rsync.c
	if ! grep '/bin/sh-rsync' /etc/shells; then
		echo '/bin/sh-rsync' >> /etc/shells
	fi
fi

if ! grep -q "$hostname" /etc/shadow ; then
	bak="$(dirname $0)"
	useradd -d $bak -M -s /bin/sh-rsync $hostname >/dev/null 2>&1
	mkdir -p $bak/.ssh
	touch $bak/.ssh/authorized_keys
	chmod 700 -R $bak
	chmod 600 $bak/.ssh/authorized_keys
	chown -R $hostname:$hostname $bak
	sed -ie "s@$hostname:!:@$hostname:*:@" /etc/shadow
	if [ -f /etc/ssh/sshd_config ] && ! grep -q "$hostname" /etc/ssh/sshd_config ; then
		allowed=`grep -o '^AllowUsers.*$' /etc/ssh/sshd_config`
		sed -i -e "s@^AllowUsers.*\$@$allowed $hostname@" /etc/ssh/sshd_config
		/etc/init.d/ssh restart
	fi
fi
