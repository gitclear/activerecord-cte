FROM ruby:3.2

ENV APP_HOME /activerecord_cte
RUN mkdir $APP_HOME
WORKDIR $APP_HOME

ENV RAILS_ENV test

# Cache the bundle install
COPY Gemfile* $APP_HOME/
COPY lib/activerecord/cte/version.rb $APP_HOME/lib/activerecord/cte/version.rb
COPY *.gemspec $APP_HOME/
RUN gem install bundler
RUN bundle install

ADD . $APP_HOME

