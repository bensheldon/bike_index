class UserRegistrationOrganization < ApplicationRecord
  include RegistrationInfoable

  acts_as_paranoid

  belongs_to :user
  belongs_to :organization

  validates_presence_of :user_id, :organization_id

  before_validation :set_calculated_attributes
  after_commit :update_associations, if: :persisted?

  scope :paid_organizations, -> { includes(:organization).where(organizations: {is_paid: true}) }
  scope :not_paid_organizations, -> { includes(:organization).where(organizations: {is_paid: false}) }

  attr_accessor :skip_after_user_change_worker

  # Includes deleted, just to be safe
  def self.org_ids_with_uniq_info(user, fields = nil)
    fields ||= OrganizationFeature.reg_fields
    bike_org_ids = BikeOrganization.unscoped.where(bike_id: user.bike_ids).distinct.pluck(:organization_id)
    Organization.where(id: bike_org_ids).with_any_enabled_feature_slugs(fields).pluck(:id)
  end

  # TODO: maybe should be in ownership
  def self.universal_registration_info_for(user, passed_reg_info = {})
    uro_reg_info = user.user_registration_organizations.pluck(:registration_info).reduce({}, :merge)
    own_reg_info = user.ownerships.reorder(:updated_at).pluck(:registration_info).reduce({}, :merge)
    # Pretty sure that user_name and extra_registration_number can't end up in registration_info anymore
    # TODO: post #2121 remove them if that's true
    ignored_own_keys = %w[user_name bike_sticker extra_registration_number]
    merging_own_keys = (own_reg_info.keys - uro_reg_info.keys - ignored_own_keys)
    # Then, remove location keys
    location_keys = %w[city country state street zipcode latitude longitude]
    unless (uro_reg_info.keys & location_keys).count == location_keys.count
      merging_own_keys += location_keys
    end
    new_reg_info = uro_reg_info.merge(own_reg_info.slice(*merging_own_keys))
    new_reg_info["phone"] = user.phone if user.phone.present? # Assign phone from user if possible
    # If there are assigned orgs with reg_student_id, switch student_id to reference the org ids
    if new_reg_info["student_id"].present?
      ids = org_ids_with_uniq_info(user, "reg_student_id")
      if ids.any?
        student_id = new_reg_info.delete("student_id")
        # Don't overwrite if it's already assigned
        ids.each { |i| new_reg_info["student_id_#{i}"] ||= student_id }
      end
    end
    # If there are assigned orgs with reg_organization_affiliation, switch organization_affiliation to reference the org ids
    if new_reg_info["organization_affiliation"].present?
      ids = org_ids_with_uniq_info(user, "reg_organization_affiliation")
      if ids.any?
        organization_affiliation = new_reg_info.delete("organization_affiliation")
        # Don't overwrite if it's already assigned
        ids.each { |i| new_reg_info["organization_affiliation_#{i}"] ||= organization_affiliation }
      end
    end
    new_reg_info.merge(passed_reg_info.slice(*ignored_own_keys))
  end

  def bikes
    all_bikes? ? user.bikes : user.bikes.organization(organization_id)
  end

  def manages_information?
    registration_info.present? || organization.additional_registration_fields.any?
  end

  # Use all the registration info from the bikes
  def set_initial_registration_info
    reg_info_array = bikes.reorder(:updated_at).map(&:registration_info).reject(&:blank?)
    self.registration_info = reg_info_array.reduce({}, :merge)
  end

  # Because seth wants to have default=false attributes in the database, but can_edit_claimed is easier to think about
  # Duplicates functionality in bike_organization
  def can_edit_claimed
    !can_not_edit_claimed
  end

  def can_edit_claimed=(val)
    self.can_not_edit_claimed = !val
  end

  def set_calculated_attributes
    self.registration_info ||= {}
  end

  def update_associations
    create_or_update_bike_organizations
    return true if skip_after_user_change_worker
    AfterUserChangeWorker.perform_async(user_id)
  end

  # Manually called from AfterUserChangeWorker
  def create_or_update_bike_organizations
    return true unless all_bikes # only overrides bike_organizations if all_bikes is checked
    bikes.each do |bike|
      bike_organization = BikeOrganization.unscoped
        .where(organization_id: organization_id, bike_id: bike.id)
        .first_or_initialize
      bike_organization.update(deleted_at: nil, can_not_edit_claimed: can_not_edit_claimed)
    end
  end
end
