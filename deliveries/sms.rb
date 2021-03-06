require 'twilio-rb'

module Deliveries
  module SMS

    extend Helpers::Routing

    def self.deliver_for_user!(user, options = {})
      dry_run = options['dry_run'] || false
      
      unless user.phone.present? and user.phone_confirmed?
        Admin.report Report.failure("Delivery", "#{user.id} is signed up for SMS alerts but has no confirmed phone", :id => user.id.to_s, :email => user.email, :phone => user.phone, :phone_confirmed => user.phone_confirmed)
        return []
      end

      failures = 0
      successes = []

      email = user.email
      phone = user.phone

      matching_deliveries = user.deliveries.where(:mechanism => "sms").all
      interest_deliveries = matching_deliveries.group_by &:interest

      interest_deliveries.each do |interest, deliveries|
        # 1) change this to a landing page per-interest 
        #   (show page for item interests, new page for keyword interests [HTML version of RSS feed])
        # 2) shorten this URL in the Sunlight URL shortener
        
        core, url = render_interest interest, deliveries
        content = render_final core, url

        if content.size > 160
          too_big = content.size - 160
          original = content.dup

          # cut out the overage, plus 3 for the ellipse, one for the potential quote, 3 for an additional buffer
          truncated_core = core[0...-(too_big + 3 + 1 + 3)] + "..." + (interest.search? ? "\"" : "")
          content = render_final truncated_core, url

          # I may disable the emailing of this report after a while, but I want to see the frequency of this in practice
          Admin.report Report.warning("Delivery", "SMS more than 160 characters, truncating", :truncation => true, :original => content, :truncated => content)
        end

        if content.size > 160
          Admin.report Report.failure("Delivery", "Failed somehow to truncate SMS to less than 160", :truncation => true, :original => original, :truncated => content)
          next
        end

        if dry_run
          ::SMS.sent_message("DRY RUN", "User", phone, content)
        else
          if sms_user(phone, content)
            deliveries.each &:delete
            successes << save_receipt!(user, deliveries, content)
          else
            failures += 1
          end
        end
      end

      if failures > 0
        Admin.report Report.failure("Delivery", "Failed to deliver #{failures} SMSes to #{email}")
      end

      if successes.any?
        Report.success("Delivery", "Delivered #{successes.size} SMSes to #{email}")
      end

      successes
    end

    def self.render_interest(interest, deliveries)
      grouped = deliveries.group_by &:subscription_type

      url = interest_url interest

      content = ""
      
      content << grouped.map do |subscription_type, subscription_deliveries|
        number = subscription_deliveries.size
        "#{number} #{Subscription.adapter_for(subscription_type).short_name number, interest}"
      end.join(", ")

      if interest.search?
        content << " on \"#{interest.in}\""
      elsif interest.item?
        content << " for #{Subscription.adapter_for(item_types[interest.item_type]['adapter']).interest_name(interest)}"
      elsif interest.feed?
        content << " from" # ?
      end

      [content, url]
    end

    def self.render_final(content, url)
      "[Scout] #{content} #{url}"
    end

    def self.save_receipt!(user, deliveries, content)
      Receipt.create!(
        mechanism: "sms",

        deliveries: deliveries.map {|delivery| delivery.attributes.dup},

        user_id: user.id,
        user_phone: user.phone,
        user_notifications: user.notifications,

        content: content,
        delivered_at: Time.now
      )
    end

    # the actual mechanics of sending the email
    def self.sms_user(phone, content)
      ::SMS.deliver! "User", phone, content
    end

  end
end