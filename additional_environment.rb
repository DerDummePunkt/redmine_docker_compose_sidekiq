config.active_job.queue_adapter = :sidekiq

# Redis/Valkey connection for sidekiq, configured with individual variables like the database
# (REDMINE_DB_*). Every REDMINE_REDIS_* variable also supports a _FILE variant (docker secrets).
redis_env = lambda do |name, default = nil|
  value = ENV[name].to_s
  file = ENV["#{name}_FILE"].to_s
  raise ArgumentError, "both #{name} and #{name}_FILE are set (but are exclusive)" if !value.empty? && !file.empty?

  return File.read(file).strip unless file.empty?
  value.empty? ? default : value
end

redis_config = {
  host: redis_env.call('REDMINE_REDIS_HOST', 'redis'),
  port: Integer(redis_env.call('REDMINE_REDIS_PORT', '6379')),
  db: Integer(redis_env.call('REDMINE_REDIS_DB', '0'))
}
username = redis_env.call('REDMINE_REDIS_USERNAME')
password = redis_env.call('REDMINE_REDIS_PASSWORD')
# redis allows a password without a username, but not the other way around
raise ArgumentError, 'REDMINE_REDIS_USERNAME is set, but not REDMINE_REDIS_PASSWORD' if username && !password

redis_config[:username] = username if username
redis_config[:password] = password if password

Sidekiq.configure_client { |sidekiq| sidekiq.redis = redis_config }
Sidekiq.configure_server { |sidekiq| sidekiq.redis = redis_config }
