# Build stage
FROM ruby:3.3.6-slim AS builder

WORKDIR /app

COPY Gemfile* ./
RUN apt-get update && apt-get install -y build-essential \
    && bundle config set without 'development test' \
    && bundle install --jobs 4 --retry 3

# Runtime stage
FROM ruby:3.3.6-slim

WORKDIR /app

COPY --from=builder /usr/local/bundle /usr/local/bundle
COPY . .

EXPOSE 9292

CMD ["bundle", "exec", "rackup", "--host", "0.0.0.0"]
