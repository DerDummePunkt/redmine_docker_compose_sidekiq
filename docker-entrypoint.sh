#!/usr/bin/env bash
set -Eeo pipefail
# TODO add "-u"

# usage: file_env VAR [DEFAULT]
#    ie: file_env 'XYZ_DB_PASSWORD' 'example'
# (will allow for "$XYZ_DB_PASSWORD_FILE" to fill in the value of
#  "$XYZ_DB_PASSWORD" from a file, especially for Docker's secrets feature)
file_env() {
	local var="$1"
	local fileVar="${var}_FILE"
	local def="${2:-}"
	if [ "${!var:-}" ] && [ "${!fileVar:-}" ]; then
		echo >&2 "error: both $var and $fileVar are set (but are exclusive)"
		exit 1
	fi
	local val="$def"
	if [ "${!var:-}" ]; then
		val="${!var}"
	elif [ "${!fileVar:-}" ]; then
		val="$(< "${!fileVar}")"
	fi
	export "$var"="$val"
	unset "$fileVar"
}

isLikelyRedmine=
case "$1" in
	rails | rake ) isLikelyRedmine=1 ;;
esac

isLikelySidekiq=
case "$*" in
	bundle\ exec\ sidekiq* ) isLikelySidekiq=1 ;;
esac


_fix_permissions() {
	# https://www.redmine.org/projects/redmine/wiki/RedmineInstall#Step-8-File-system-permissions
	local dirs=( config log public/plugin_assets tmp ) args=()
	if [ "$(id -u)" = '0' ]; then
		args+=( ${args[@]:+,} '(' '!' -user redmine -exec chown redmine:redmine '{}' + ')' )

		# https://github.com/docker-library/redmine/issues/268 - scanning "files" might be *really* expensive, so we should skip it if it seems like it's "already correct"
		local filesOwnerMode
		filesOwnerMode="$(stat -c '%U:%a' files)"
		if [ "$files" != 'redmine:755' ]; then
			dirs+=( files )
		fi
	fi
	# directories 755, files 644:
	args+=( ${args[@]:+,} '(' -type d '!' -perm 755 -exec sh -c 'chmod 755 "$@" 2>/dev/null || :' -- '{}' + ')' )
	args+=( ${args[@]:+,} '(' -type f '!' -perm 644 -exec sh -c 'chmod 644 "$@" 2>/dev/null || :' -- '{}' + ')' )
	find "${dirs[@]}" "${args[@]}"
}

_set_redis_url() {
	# the easiest way to configure sidekiq is by setting REDIS_URL
	# https://github.com/sidekiq/sidekiq/wiki/Using-Redis
	if [ -z "$REDMINE_REDIS_USERNAME" ] && [ -z "$REDMINE_REDIS_PASSWORD" ]; then
		export REDIS_URL="redis://${REDMINE_REDIS_HOST}:${REDMINE_REDIS_PORT}/${REDMINE_REDIS_DB}"
	elif [ -z "$REDMINE_REDIS_USERNAME" ] && [ -n "$REDMINE_REDIS_PASSWORD" ]; then
		# redis://:the_password@host seems weird, but thats what the redis specs say...
		export REDIS_URL="redis://:${REDMINE_REDIS_PASSWORD}@${REDMINE_REDIS_HOST}:${REDMINE_REDIS_PORT}/${REDMINE_REDIS_DB}"
	else
		export REDIS_URL="redis://${REDMINE_REDIS_USERNAME}:${REDMINE_REDIS_PASSWORD}@${REDMINE_REDIS_HOST}:${REDMINE_REDIS_PORT}/${REDMINE_REDIS_DB}"
	fi
}

_configure_sql_database_connection() {
	if [ ! -f './config/database.yml' ]; then
		file_env 'REDMINE_DB_MYSQL'
		file_env 'REDMINE_DB_POSTGRES'
		file_env 'REDMINE_DB_SQLSERVER'

		if [ "$MYSQL_PORT_3306_TCP" ] && [ -z "$REDMINE_DB_MYSQL" ]; then
			export REDMINE_DB_MYSQL='mysql'
		elif [ "$POSTGRES_PORT_5432_TCP" ] && [ -z "$REDMINE_DB_POSTGRES" ]; then
			export REDMINE_DB_POSTGRES='postgres'
		fi

		if [ "$REDMINE_DB_MYSQL" ]; then
			adapter='mysql2'
			host="$REDMINE_DB_MYSQL"
			file_env 'REDMINE_DB_PORT' '3306'
			file_env 'REDMINE_DB_USERNAME' "${MYSQL_ENV_MYSQL_USER:-root}"
			file_env 'REDMINE_DB_PASSWORD' "${MYSQL_ENV_MYSQL_PASSWORD:-${MYSQL_ENV_MYSQL_ROOT_PASSWORD:-}}"
			file_env 'REDMINE_DB_DATABASE' "${MYSQL_ENV_MYSQL_DATABASE:-${MYSQL_ENV_MYSQL_USER:-redmine}}"
			file_env 'REDMINE_DB_ENCODING' ''
		elif [ "$REDMINE_DB_POSTGRES" ]; then
			adapter='postgresql'
			host="$REDMINE_DB_POSTGRES"
			file_env 'REDMINE_DB_PORT' '5432'
			file_env 'REDMINE_DB_USERNAME' "${POSTGRES_ENV_POSTGRES_USER:-postgres}"
			file_env 'REDMINE_DB_PASSWORD' "${POSTGRES_ENV_POSTGRES_PASSWORD}"
			file_env 'REDMINE_DB_DATABASE' "${POSTGRES_ENV_POSTGRES_DB:-${REDMINE_DB_USERNAME:-}}"
			file_env 'REDMINE_DB_ENCODING' 'utf8'
		elif [ "$REDMINE_DB_SQLSERVER" ]; then
			adapter='sqlserver'
			host="$REDMINE_DB_SQLSERVER"
			file_env 'REDMINE_DB_PORT' '1433'
			file_env 'REDMINE_DB_USERNAME' ''
			file_env 'REDMINE_DB_PASSWORD' ''
			file_env 'REDMINE_DB_DATABASE' ''
			file_env 'REDMINE_DB_ENCODING' ''
		else
			echo >&2
			echo >&2 'warning: missing REDMINE_DB_MYSQL, REDMINE_DB_POSTGRES, or REDMINE_DB_SQLSERVER environment variables'
			echo >&2
			echo >&2 '*** Using sqlite3 as fallback. ***'
			echo >&2

			adapter='sqlite3'
			host='localhost'
			file_env 'REDMINE_DB_PORT' ''
			file_env 'REDMINE_DB_USERNAME' 'redmine'
			file_env 'REDMINE_DB_PASSWORD' ''
			file_env 'REDMINE_DB_DATABASE' 'sqlite/redmine.db'
			file_env 'REDMINE_DB_ENCODING' 'utf8'

			mkdir -p "$(dirname "$REDMINE_DB_DATABASE")"
			if [ "$(id -u)" = '0' ]; then
				find "$(dirname "$REDMINE_DB_DATABASE")" \! -user redmine -exec chown redmine '{}' +
			fi
		fi

		REDMINE_DB_ADAPTER="$adapter"
		REDMINE_DB_HOST="$host"
		echo "$RAILS_ENV:" > config/database.yml
		for var in \
			adapter \
			host \
			port \
			username \
			password \
			database \
			encoding \
		; do
			env="REDMINE_DB_${var^^}"
			val="${!env}"
			[ -n "$val" ] || continue
			echo "  $var: \"$val\"" >> config/database.yml
		done
	fi
}

_configure_redis_connection() {
	# there doesnt seem to be a way to check if this config was already done, is there?
	# the sidekiq config is in additional_environment.rb, but here are many other things which could create that
	# i think all thats left to do here is check the env vars
	# this will be ugly...
	if [ -n "$REDMINE_REDIS_HOST" ] \
		|| [ -n "$REDMINE_REDIS_PORT" ] \
		|| [ -n "$REDMINE_REDIS_DB" ] \
		|| [ -n "$REDMINE_REDIS_USERNAME" ] \
		|| [ -n "$REDMINE_REDIS_PASSWORD" ] \
		|| [ -n "$REDMINE_REDIS_PASSWORD_FILE" ];
	then
		# go for default redis or valkey?
		file_env 'REDMINE_REDIS_HOST' 'valkey'
		file_env 'REDMINE_REDIS_PORT' '6379'
		file_env 'REDMINE_REDIS_DB' '0'

		file_env 'REDMINE_REDIS_USERNAME' ''
		file_env 'REDMINE_REDIS_PASSWORD' ''
		# redis protocol allows empty usernames and a set password
		# but not the other way around, if a username is set, you must also have a password
		if [ -n "$REDMINE_REDIS_USERNAME" ] && [ -z "$REDMINE_REDIS_PASSWORD" ]; then
			echo >&2
			echo >&2 'warning: REDMINE_REDIS_USERNAME environment variable is set, but not REDMINE_REDIS_PASSWORD'
			echo >&2 'warning: skipping sidekiq config'
			echo >&2
			break 2
		fi
		
		_set_redis_url

		# seems like ./config/additional_environment.rb always gets created by the docker file
		# but its owned by root...
		ac_file_path="./config/additional_environment.rb"
		# just in case the user deleted that file, we should check for it anyways
		if [ ! -f "$ac_file_path" ] || ! grep -Fxq "config.active_job.queue_adapter = :sidekiq" "$ac_file_path"; then
			echo "config.active_job.queue_adapter = :sidekiq" >> "$ac_file_path"
		fi

	fi
}

_handle_secrets() {
	if [ ! -s config/secrets.yml ]; then
		file_env 'REDMINE_SECRET_KEY_BASE'
		if [ -n "$REDMINE_SECRET_KEY_BASE" ]; then
			cat > 'config/secrets.yml' <<-YML
				$RAILS_ENV:
				  secret_key_base: "$REDMINE_SECRET_KEY_BASE"
			YML
		elif [ ! -f config/initializers/secret_token.rb ]; then
			rake generate_secret_token
		fi
	fi
}

# allow the container to be started with `--user`
if [ -n "$isLikelyRedmine" ] && [ "$(id -u)" = '0' ]; then
	_fix_permissions
	exec gosu redmine "$BASH_SOURCE" "$@"
fi

if [ -n "$isLikelyRedmine" ] || [ -n "$isLikelySidekiq" ]; then
	_fix_permissions

	_configure_sql_database_connection

	_configure_redis_connection

	# install additional gems for Gemfile.local and plugins
	bundle check || bundle install

	_handle_secrets

fi

if [ -n "$isLikelyRedmine" ]; then
	if [ "$1" != 'rake' -a -z "$REDMINE_NO_DB_MIGRATE" ]; then
		rake db:migrate
	fi

	if [ "$1" != 'rake' -a -n "$REDMINE_PLUGINS_MIGRATE" ]; then
		rake redmine:plugins:migrate
	fi

	# remove PID file to enable restarting the container
	rm -f tmp/pids/server.pid
fi

exec "$@"
