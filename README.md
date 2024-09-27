# OpenStreetMap Logical History

OpenStreetMap Sementic History Recovery.

## Build
```
docker compose --profile "*" build
```

## Dev

Setup
```
bundle install
bundle exec tapioca init

# bundle exec tapioca dsl
bundle exec srb rbi suggest-typed
```

Tests and Validation
```
bundle exec srb typecheck
bundle exec rubocop --parallel -c .rubocop.yml --autocorrect
docker compose run --rm script bundle exec rake test
```

## Server

Run a small web server to explose the computation algorithm.

Enable server, and install required gems
```
bundle config set --local with server
bundle install
```

Start the server
```
docker compose run --rm -p 9292:9292 script bundle exec rackup --host 0.0.0.0
```
