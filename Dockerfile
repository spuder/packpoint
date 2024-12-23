FROM ruby:3.2.2

WORKDIR /app

COPY Gemfile* ./
RUN bundle config set with production && bundle install

COPY . .

EXPOSE 9292


CMD ["bundle", "exec", "rackup", "--host", "0.0.0.0"]