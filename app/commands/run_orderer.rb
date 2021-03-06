require 'clockwork'
require './config/boot'
require './config/environment'
require 'tzinfo'

module Clockwork
  RETRY_ATTEMPTS = 3

  handler do |job|
    puts "Running #{job}"
  end

  every(1.day, 'Order mealpal - 5pm', tz: 'America/New_York', at: '17:05') do
    return if tomorrow_is_weekend?

    clean_up_events_table_if_too_big

    today = (TZInfo::Timezone.get('America/New_York').now.wday + 1)

    User.all.each do |user|
      next unless user.order_early?

      todays_order_day = user.order_days.find { |od| od.week_day_number == today }

      order_for_user(user, todays_order_day)
    end
  end

  every(1.day, 'Order mealpal - 11pm', tz: 'America/New_York', at: '23:02') do
    return if tomorrow_is_weekend?

    clean_up_events_table_if_too_big

    today = (TZInfo::Timezone.get('America/New_York').now.wday + 1)

    User.all.each do |user|
      next if user.order_early?

      todays_order_day = user.order_days.find { |od| od.week_day_number == today }

      order_for_user(user, todays_order_day)
    end
  end

  private

  def self.tomorrow_is_weekend?
    [5, 6].include?(TZInfo::Timezone.get('America/New_York').now.wday)
  end

  def self.order_for_user(user, todays_order_day)
    return unless todays_order_day.scheduled_to_order

    ordered = false

    RETRY_ATTEMPTS.times do
      begin
        # remove PhantomJS cookies
        system 'rm $HOME/.local/share/Ofi\ Labs/PhantomJS/*'

        if Orderer.run(user: user, todays_order_day: todays_order_day)
          ordered = true

          break
        end

      rescue Exception => e
        user.events.create!(details: e.message)

        log_entry = "\n===========================\n#{Time.now}\n#{e.message}"
        File.open('log/log.log', 'a') { |file| file << log_entry }
      end
    end

    send_email(ordered, user) if ENV['ADMIN_EMAIL_REPORTS']
  end

  def self.clean_up_events_table_if_too_big
    if ::Event.count > 9000
      ::Event.find(:all, order: 'created_at desc', limit: 1000).destroy_all
    end
  end

  def self.send_email(ordered, user)
    if ordered
      AdminMailer.send_status_report_success(user).deliver
    else
      AdminMailer.send_status_report_error(user).deliver
    end
  end
end
