ARG REDMINE_TAG=6.1.6-trixie
FROM redmine:${REDMINE_TAG}

USER root

# version of https://github.com/kontron/redmine_oauth to install, leave empty to skip the plugin
ARG OAUTH_PLUGIN_VERSION=

# build-essential is only needed to compile native gems, it is purged again afterwards
RUN set -eux; \
	apt-get update; \
	apt-get install -y --no-install-recommends build-essential; \
	\
	if [ -n "$OAUTH_PLUGIN_VERSION" ]; then \
		wget -O /tmp/oauth_plugin.tar.gz "https://github.com/kontron/redmine_oauth/archive/refs/tags/v${OAUTH_PLUGIN_VERSION}.tar.gz"; \
		mkdir plugins/redmine_oauth; \
		tar -xf /tmp/oauth_plugin.tar.gz -C plugins/redmine_oauth --strip-components=1; \
		rm /tmp/oauth_plugin.tar.gz; \
	fi; \
	\
	echo "gem 'sidekiq'" > Gemfile.local; \
	chown -R redmine:redmine plugins Gemfile.local; \
	\
	gosu redmine bundle install --jobs "$(nproc)"; \
	chmod -R ugo=rwX Gemfile.lock "$GEM_HOME"; \
	rm -rf ~redmine/.bundle; \
	\
	apt-get purge -y --auto-remove build-essential; \
	rm -rf /var/lib/apt/lists/*

COPY --chmod=644 additional_environment.rb config/additional_environment.rb
