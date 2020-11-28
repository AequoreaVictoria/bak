# bak
> Another in an infinite sea of backup scripts.

### Overview
This is nothing fancy. You execute `./run.sh` either manually or by cron,
it dumps files into `./files/`. You define backup tasks using a simple
declarative syntax in the `tasks` file. Configuration is through the `config`
file.

It will generate a debug log of the backup script's execution. This is complete
with listings of all files affected and sha512 checksums for all files
generated.

If any step encounters an error, it will alert a specified email address with
the command that failed. No sensitive passwords are logged, nor do they leak to
the environment.

### Dependencies
* `sendmail` (or compatible), for alerts. [REQUIRED]
* `uuidgen`, for unique filenames. [REQUIRED]
* `sha512sum`, for file checksums. [REQUIRED]
* `xz`, for file compression. [REQUIRED]
* `rsync`, for SSH file syncing. [REQUIRED]
* `mysqldump`, for MySQL backups.
* `pg_dump`, for PostgreSQL backups.
* `b2`, for B2 file transfers and syncing.
* `s3cmd`, for S3 file transfers and syncing.
* A C compiler, for sh-rsync.c.

### Install
`git clone https://github.com/AequoreaVictoria/bak /bak`

Nothing in the scripts assume you will install to `/bak`, but all documentation
will assume this is the case.

### Usage
``` Shell
./run.sh --configure       # Write out default 'config' and 'tasks' file.
./run.sh                   # Execute 'tasks'.
```

Set up new installations with `./run.sh --configure` to generate the
configuration files. Edit both the `config` and the `tasks` files. Both files
contain comments on their usage. When finished, set cron or similar task agent
to execute `/bak/run.sh`.

`config` must be set `chmod 600`, else `run.sh` will refuse to continue.

### Tasks List
```
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
```

### Tasks Example
``` Shell
tarxz name /var/log/foo     # Create host-YYYY-MM-DD-name.tar.xz daily.
weekly tarxz name /app/path # Create host-YYYY-MM-DD-name.tar.xz weekly.
msqldump name "db1 db2"     # Dump tables to host-YYYY-MM-DD-name.msql.xz daily.
monthly psqldump name "db"  # Dump table to host-YYYY-MM-DD-name.psql.xz monthly.
s3sync                      # Sync ./files to s3://$bucket/$host/.
cleanm                      # Remove all files older than last month.
```

Consult the chart above for more details. `$bucket` and `$host` are
defined in `config`.

### Example Setup
The ideal setup involves a dedicated backup server that pulls backup files
from your other machines. All of the machines involved will execute
`/bak/run.sh` daily.

On all production machines, `tasks` create database dumps and backup
tarballs in `/bak/files/`. It will then run `cleanm` or `cleanw` depending on
how large a backup cache can safely be afforded on this machine. `purge` is
available for systems that cannot hold more than today's snapshot, as it
empties `/bak/files/` of logs and backups.

On the backup server, `tasks` will `pull` the contents of `/bak/files` from
production machines. It will store them in `/bak/files/<hostname>/`. It will
then sync the contents of its `/bak/files/` to either Backblaze B2 or
Amazon S3 for long-term storage.

Finally, backup servers also run `cleanm` or `cleanw` as appropriate.

By having this setup, your production machines have no access to your
backup site or long-term storage in the event of a compromise.

Using a combination of `cleanm`, `cleanw` and `b2sync`, you can tailor
how much backup retention is kept cached on each production machine, the backup
server and your long-term storage independently of each other. Your
B2 bucket may hold many more days than than your backup server, for example.

### Helpers
Having the above setup does mean having an rsync-only account on every machine
you wish to back up. The `add-user.sh` script can automate this for you.

`./add-user.sh bak.domain.com`

This creates a 'bak.domain.com' user with a home set to where `add-user.sh` is
located on the machine.

An `rsync`-only shell named `sh-rsync` is also built by `add-user.sh`, if
needed. This will be the user's shell. It is a 35 line of C program that
rejects anything but `rsync` for remote commands.

The user is also added to the AllowUser directive in `/etc/ssh/sshd_config`,
if the directive is present.

A public key from the backup server will need to be pasted into the empty
`/bak/.ssh/authorized_keys` now present in the directory. Once that is done,
`pull` is ready to be used on the backup server.

### Using `pull` and `sync`
A `pull` task in the backup server's `tasks` list:

``` Shell
# sync `/bak/files` of 'somesite.com' to `/bak/files/somesite.com/files`
# locally, over SSH port '8086'.
pull somesite.com 8086
```

From there, your backup server's `/bak/files` can be safely copied to
Amazon S3 or Backblaze B2. Pick one:

``` Shell
# sync `/bak/files` to `b2://$bucket/$host` at Backblaze B2.
b2sync

# sync `/bak/files` to `s3://$bucket/$host` at Amazon S3.
s3sync
```

`$bucket` and `$host` are defined by `config`.

During `pull` tasks, a `/bak/tmp` directory will be used to hold files
currently being transferred. They will be staged into `/bak/files` when
completed. This will prevent the `sync` commands from seeing incomplete
files.

### Rationale
The seperate `tasks` file is intended to present a simple declarative interface
for administrators of any experience level to use. The rest of the code is
designed to make this interface work.

The work of `run.sh` and `bak.sh` is split up for two reasons of clarity:

###### 1. Debugging:
`foo() { blah $1 $2 $3; }` is harder to read than
`foo() { blah %%USER%% %%HOST%% $1; }`. The `run.sh` script creates a
specialized `bak.sh` with the '%%CONSTANTS%%' replaced with `config` values.

###### 2. Logging:
The `bak.sh` executes with `set -x` logging enabled, capturing everything that
occurrs during execution. By keeping task execute confined to `bak.sh`, this
focuses the log on only the most important part of the task.

### License
*bak* is licensed [0BSD][0].

[0]: https://opensource.org/licenses/0BSD
