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
