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
docker compose up script
```

Query with
```
http://127.0.0.1:9292/api/0.1/overpass_logical_history
```
