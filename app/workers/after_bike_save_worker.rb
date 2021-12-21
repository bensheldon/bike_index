# This will replace WebhookRunner - which is brittle and not flexible enough for what I'm looking for now
# I need to refactor that, but I don't want to right now because I don't want to break existing stuff yet

class AfterBikeSaveWorker < ApplicationWorker
  sidekiq_options retry: false

  POST_URL = ENV["BIKE_WEBHOOK_URL"]
  AUTH_TOKEN = ENV["BIKE_WEBHOOK_AUTH_TOKEN"]

  def perform(bike_id, skip_user_update = false)
    bike = Bike.unscoped.where(id: bike_id).first
    return true unless bike.present?
    bike.load_external_images
    update_matching_partial_registrations(bike)
    DuplicateBikeFinderWorker.perform_async(bike_id)
    if bike.present? && bike.listing_order != bike.calculated_listing_order
      bike.update_attribute :listing_order, bike.calculated_listing_order
    end
    update_ownership(bike)
    unless skip_user_update
      # Update the user to update any user alerts relevant to bikes
      AfterUserChangeWorker.new.perform(bike.owner.id, bike.owner.reload, true) if bike.owner.present?
    end
    return true unless bike.status_stolen? # For now, only hooking on stolen bikes
    post_bike_to_webhook(serialized(bike))
  end

  def post_bike_to_webhook(post_body)
    return true unless POST_URL.present?
    Faraday.new(url: POST_URL).post do |req|
      req.headers["Content-Type"] = "application/json"
      req.body = post_body.to_json
    end
  end

  def serialized(bike)
    {
      auth_token: AUTH_TOKEN,
      bike: BikeV2ShowSerializer.new(bike, root: false).as_json,
      update: bike.created_at > Time.current - 30.seconds
    }
  end

  def update_matching_partial_registrations(bike)
    return true unless bike.created_at > Time.current - 5.minutes # skip unless new bike
    matches = BParam.partial_registrations.without_bike.where("email ilike ?", "%#{bike.owner_email}%")
      .reorder(:created_at)
    if matches.count > 1
      # Try to make it a little more accurate lookup
      best_matches = matches.select { |b_param| b_param.manufacturer_id == bike.manufacturer_id }
      matches = best_matches if matches.any?
    end
    matching_b_param = matches.last # Because we want the last created
    return true unless matching_b_param.present?
    matching_b_param.update_attributes(created_bike_id: bike.id)
    # Only set creation_state
    creation_state = bike.current_creation_state
    if creation_state.present? && creation_state.origin == "web" && creation_state.organization_id.blank?
      creation_state.organization_id = matching_b_param.organization_id
      creation_state.origin = matching_b_param.origin if (CreationState.origins - ["web"]).include?(matching_b_param.origin)
      creation_state.save
      if matching_b_param.organization_id.present?
        bike.update(creation_organization_id: matching_b_param.organization_id)
        bike.bike_organizations.create(organization_id: matching_b_param.organization_id)
      end
    end
  end

  def update_ownership(bike)
    if bike.soon_current_ownership_id != bike.current_ownership&.id
      bike.update_attribute :soon_current_ownership_id, bike.current_ownership&.id
    end
    return true if bike.soon_current_ownership.blank?
    bike.soon_current_ownership&.update(updated_at: Time.current)
  end
end
