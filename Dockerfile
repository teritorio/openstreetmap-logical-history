FROM ruby:3.4-alpine

RUN apk add --no-cache --virtual \
        build-dependencies \
        build-base \
        geos-dev \
        proj-dev \
        ruby-dev

WORKDIR /srv/app

ADD Gemfile Gemfile.lock ./
RUN bundle config --global silence_root_warning 1
RUN bundle config set --local with server
RUN bundle install
RUN cd /usr/local/bundle/gems/levenshtein-ffi-1.1.0/ext/levenshtein && make

ADD . ./

EXPOSE 9292

HEALTHCHECK \
    --start-interval=1s \
    --start-period=30s \
    --interval=30s \
    --timeout=20s \
    --retries=5 \
    CMD wget --no-verbose --tries=1 -O /dev/null http://127.0.0.1:9292/up || exit 1
