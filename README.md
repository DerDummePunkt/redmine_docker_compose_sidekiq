# redmine_docker_compose_sidekiq

This repo is meant to showcase proposed changes to https://github.com/docker-library/redmine/ as well as provide an example on how to use the proposed changes in a docker compose context.

The compose stack runs the same image as two services:
- one running the ruby on rails redmine application
- the other one running the sidekiq background worker

Additionally there are services for
- postgres as a database
- valkey as a redis-like kv-store

**This setup assumes you are running a reverse proxy for http/https and is not part of main compose stack**. There is `proxy/docker-compose.yml` however, that shows how that is intended to work.

## Credentials and secrets

To configure credentials for the database and key-value store, this repo utilizes docker secrets.

Place the desired passwords in text files with the corresponding names in `./secrets`, e.g. via:
```bash
openssl rand -hex 64 >> ./secrets/DB_PASSWORD
openssl rand -hex 64 >> ./secrets/REDIS_PASSWORD
```
The values are mapped and used in the respective services accordingly.

## run the stack

- create the external network
    ```bash
    docker network create web
    ```
- run the stack
    ```bash
    docker compose up -d
    ```
- watch the logs
    ```bash
    docker compose logs -f --tail=100
    ```
- eventually, you should see output like
    ```bash
    sidekiq-1  | 2024-12-06T20:52:31.407Z pid=1 tid=41l INFO: Sidekiq 7.3.6 connecting to Redis with options {:size=>10, :pool_name=>"internal", :url=>"redis://:REDACTED@valkey:6379/0"}
    sidekiq-1  | 2024-12-06T20:52:31.410Z pid=1 tid=41l INFO: Sidekiq 7.3.6 connecting to Redis with options {:size=>5, :pool_name=>"default", :url=>"redis://:REDACTED@valkey:6379/0"}
    redmine    | => Booting Puma
    redmine    | => Rails 7.2.2 application starting in production
    redmine    | => Run `bin/rails server --help` for more startup options
    redmine    | Puma starting in single mode...
    redmine    | * Puma version: 6.5.0 ("Sky's Version")
    redmine    | * Ruby version: ruby 3.3.6 (2024-11-05 revision 75015d4c1f) [x86_64-linux]
    redmine    | *  Min threads: 0
    redmine    | *  Max threads: 5
    redmine    | *  Environment: production
    redmine    | *          PID: 1
    redmine    | * Listening on http://0.0.0.0:3000
    ```
## running the reverse proxy

Again, some assumptions here.

You need to obtain SSL certifiactes, for instance from LetsEncrypt. Place the certificate and key in `proxy/certs` and/or change the volumes in the docker compose in `proxy/docker-compose.yml`.

The certificate file names as well as domain names are set to the examplary value of `mydomain.com`, change them accordingly in the `proxy/conf.d/snippets/standard_ssl.conf` files to fit your domain / file names you set in the volume mount.

The redmine instance is assumed to be run under the subdomain `redmine.`, you can change that in `proxy/conf.d/redmine.conf`

- obtain and place SSL Certificates
- create the Diffie–Hellman params
    ```bash
    openssl dhparam -out ./proxy/dhparam.pem 4096
    ```
- run the stack
    ```bash
    cd proxy
    docker compose up -d
    ```
- watch the logs
    ```bash
    docker compose logs -f --tail=100
    ```

## the two docker files
The Dockerfile used by default is `Dockerfile.debian.sidekiq`, there is also `Dockerfile.debian.sidekiq.oidc` which addionally integrates aplugin for OIDC/OAuth, see https://github.com/kontron/redmine_oauth/