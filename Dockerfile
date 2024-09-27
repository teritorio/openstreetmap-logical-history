FROM ruby:3.2-alpine

RUN apk add --no-cache --virtual \
        build-dependencies \
        build-base \
        geos-dev \
        proj-dev \
        ruby-dev \
        ruby-json

WORKDIR /srv/app

ADD Gemfile Gemfile.lock ./
RUN bundle config --global silence_root_warning 1
RUN bundle install
RUN cd /usr/local/bundle/gems/levenshtein-ffi-1.1.0/ext/levenshtein && make

ADD . ./
