# Build stage
FROM ruby:3.3.6-slim AS builder

WORKDIR /app

# Install build dependencies
RUN apt-get update && apt-get install -y build-essential libcups2

COPY Gemfile* ./
RUN bundle config set without 'development test' \
    && bundle install --jobs 4 --retry 3

# Runtime stage
FROM ruby:3.3.6-slim

WORKDIR /app

# Install runtime dependencies
RUN apt-get update && apt-get install -y libcups2 libcups2-dev avahi-utils

COPY --from=builder /usr/local/bundle /usr/local/bundle
COPY . .

EXPOSE 9292

CMD ["bundle", "exec", "rackup", "--host", "0.0.0.0"]
