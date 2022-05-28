require "rails_helper"

RSpec.describe Organized::ExportsController, type: :controller do
  let(:root_path) { organization_bikes_path(organization_id: organization.to_param) }
  let(:exports_root_path) { organization_exports_path(organization_id: organization.to_param) }
  let(:export) { FactoryBot.create(:export_organization, organization: organization) }

  before { set_current_user(user) if user.present? }

  context "organization without bike_stickers" do
    let(:organization) { FactoryBot.create(:organization) }
    context "logged in as organization admin" do
      let(:user) { FactoryBot.create(:organization_admin, organization: organization) }
      describe "index" do
        it "redirects" do
          get :index, params: {organization_id: organization.to_param}
          expect(response).to redirect_to root_path
          expect(flash[:error]).to be_present
        end
      end

      describe "show" do
        it "redirects" do
          get :show, params: {organization_id: organization.to_param, id: export.id}
          expect(response).to redirect_to root_path
          expect(flash[:error]).to be_present
        end
      end
    end

    context "logged in as super admin" do
      let(:user) { FactoryBot.create(:admin) }
      describe "index" do
        it "renders" do
          get :index, params: {organization_id: organization.to_param}
          expect(response).to render_template(:index)
          expect(assigns(:current_organization)).to eq organization
        end
      end
    end
  end

  context "organization with csv_exports" do
    let(:enabled_feature_slugs) { ["csv_exports"] }
    let!(:organization) { FactoryBot.create(:organization_with_organization_features, enabled_feature_slugs: enabled_feature_slugs) }
    let(:user) { FactoryBot.create(:organization_member, organization: organization) }

    describe "index" do
      it "renders" do
        expect(export).to be_present # So that we're actually rendering an export
        organization.reload
        expect(organization.enabled?("csv_exports")).to be_truthy
        get :index, params: {organization_id: organization.to_param}
        expect(response.code).to eq("200")
        expect(response).to render_template(:index)
        expect(assigns(:current_organization)).to eq organization
        expect(assigns(:exports).pluck(:id)).to eq([export.id])
      end
    end

    describe "show" do
      it "renders" do
        get :show, params: {organization_id: organization.to_param, id: export.id}
        expect(response.code).to eq("200")
        expect(response).to render_template(:show)
        expect(flash).to_not be_present
      end
      context "not organization export" do
        let(:export) { FactoryBot.create(:export_organization) }
        it "404s" do
          expect(export.organization.id).to_not eq organization.id
          expect {
            get :show, params: {organization_id: organization.to_param, id: export.id}
          }.to raise_error(ActiveRecord::RecordNotFound)
        end
      end
      context "avery_export" do
        let(:target_redirect_url) { "https://avery.com?mergeDataURL=https%3A%2F%2Ffiles.bikeindex.org%2Fexports%2F820181214ccc.xlsx" }
        it "redirects" do
          ENV["AVERY_EXPORT_URL"] = "https://avery.com?mergeDataURL="
          allow_any_instance_of(Export).to receive(:file_url) { "https://files.bikeindex.org/exports/820181214ccc.xlsx" }
          export.update(progress: "finished", options: export.options.merge(avery_export: true))
          get :show, params: {organization_id: organization.to_param, id: export.id, avery_redirect: true}
          expect(response).to redirect_to target_redirect_url
        end
      end
    end

    describe "new" do
      it "renders" do
        get :new, params: {organization_id: organization.to_param}
        expect(response.code).to eq("200")
        expect(response).to render_template(:new)
        expect(flash).to_not be_present
      end
      context "organization has all feature slugs" do
        let(:enabled_feature_slugs) { ["csv_exports"] + OrganizationFeature::REG_FIELDS }
        it "renders still" do
          get :new, params: {organization_id: organization.to_param}
          expect(response.code).to eq("200")
          expect(response).to render_template(:new)
          expect(flash).to_not be_present
        end
      end
    end

    describe "destroy" do
      it "renders" do
        expect(export).to be_present
        expect {
          delete :destroy, params: {id: export.id, organization_id: organization.to_param}
        }.to change(Export, :count).by(-1)
        expect(response).to redirect_to exports_root_path
        expect(flash[:success]).to be_present
      end
      context "with assigned bike codes" do
        let(:bike) { FactoryBot.create(:bike) }
        let!(:bike_sticker) { FactoryBot.create(:bike_sticker_claimed, organization: organization, code: "a1111") }
        let(:export) { FactoryBot.create(:export_avery, organization: organization, bike_code_start: "a1111") }
        it "removes the stickers before destroying" do
          export.update(options: export.options.merge(bike_codes_assigned: ["a1111"]))
          bike_sticker.reload
          export.reload
          expect(bike_sticker.claimed?).to be_truthy
          expect([bike_sticker.user_id, bike_sticker.claimed_at, bike_sticker.bike_id].count(&:present?)).to eq 3
          expect(export.avery_export?).to be_truthy
          expect(export.assign_bike_codes?).to be_truthy
          expect(export.bike_stickers_assigned).to eq(["a1111"])
          expect {
            delete :destroy, params: {id: export.id, organization_id: organization.to_param}
          }.to change(Export, :count).by(-1)
          expect(response).to redirect_to exports_root_path
          expect(flash[:success]).to be_present
          bike_sticker.reload
          expect([bike_sticker.claimed_at, bike_sticker.bike_id].count(&:present?)).to eq 0
          expect(bike_sticker.bike_sticker_updates.count).to eq 2
          bike_sticker_update = bike_sticker.bike_sticker_updates.last
          expect(bike_sticker_update.creator_kind).to eq "creator_export"
          expect(bike_sticker_update.kind).to eq "un_claim"
        end
      end
    end

    describe "create" do
      let(:start_at) { 1454925600 }
      let(:valid_attrs) do
        {
          start_at: "2016-02-08 02:00:00",
          end_at: nil,
          file_format: "xlsx",
          timezone: "America/Los Angeles",
          headers: %w[link registered_at manufacturer model registered_by]
        }
      end
      let(:avery_params) { valid_attrs.merge(end_at: "2016-03-08 02:00:00", avery_export: true, bike_code_start: "a221 ") }
      it "creates the expected export" do
        expect {
          post :create, params: {
            export: valid_attrs,
            organization_id: organization.to_param,
            include_partial_registrations: 1,
            include_full_registrations: 0
          }
        }.to change(Export, :count).by 1
        expect(response).to redirect_to organization_exports_path(organization_id: organization.to_param)
        export = Export.last
        expect(export.kind).to eq "organization"
        expect(export.file_format).to eq "xlsx"
        expect(export.user).to eq user
        expect(export.headers).to eq valid_attrs[:headers]
        expect(export.start_at.to_i).to be_within(1).of start_at
        expect(export.end_at).to_not be_present
        expect(export.options["partial_registrations"]).to be_falsey
        expect(OrganizationExportWorker).to have_enqueued_sidekiq_job(export.id)
      end
      context "with partial export" do
        let(:enabled_feature_slugs) { %w[csv_exports show_partial_registrations] }
        it "creates with partial only export" do
          expect {
            post :create, params: {
              export: valid_attrs,
              organization_id: organization.to_param,
              include_partial_registrations: "true"
            }
          }.to change(Export, :count).by 1
          expect(response).to redirect_to organization_exports_path(organization_id: organization.to_param)
          export = Export.last
          expect(export.kind).to eq "organization"
          expect(export.file_format).to eq "xlsx"
          expect(export.user).to eq user
          expect(export.headers).to eq valid_attrs[:headers]
          expect(export.start_at.to_i).to be_within(1).of start_at
          expect(export.end_at).to_not be_present
          expect(export.options["partial_registrations"]).to eq "only"
          expect(export.partial_registrations).to eq "only"
          expect(OrganizationExportWorker).to have_enqueued_sidekiq_job(export.id)
        end
        context "with include_full_registrations" do
          it "creates with both" do
            expect {
              post :create, params: {
                export: valid_attrs,
                organization_id: organization.to_param,
                include_partial_registrations: "1",
                include_full_registrations: "1"
              }
            }.to change(Export, :count).by 1
            expect(response).to redirect_to organization_exports_path(organization_id: organization.to_param)
            export = Export.last
            expect(export.kind).to eq "organization"
            expect(export.file_format).to eq "xlsx"
            expect(export.user).to eq user
            expect(export.headers).to eq valid_attrs[:headers]
            expect(export.start_at.to_i).to be_within(1).of start_at
            expect(export.end_at).to_not be_present
            expect(export.options["partial_registrations"]).to be_truthy
            expect(OrganizationExportWorker).to have_enqueued_sidekiq_job(export.id)
          end
        end
      end
      context "avery export without feature" do
        it "fails" do
          expect {
            post :create, params: {export: avery_params, organization_id: organization.to_param}
          }.to_not change(Export, :count)
          expect(flash[:error]).to be_present
        end
      end
      context "organization with avery export" do
        let(:enabled_feature_slugs) { %w[csv_exports avery_export parking_notifications bike_stickers show_partial_registrations] }
        let(:export_params) { valid_attrs.merge(file_format: "csv", avery_export: "0", end_at: "2016-02-10 02:00:00") }
        it "creates a non-avery export" do
          expect(organization.enabled?("avery_export")).to be_truthy
          expect {
            post :create, params: {
              export: export_params.merge(bike_code_start: 1, custom_bike_ids: "1222, https://bikeindex.org/bikes/999"),
              organization_id: organization.to_param,
              include_partial_registrations: false,
              include_full_registrations: 0
            }
          }.to change(Export, :count).by 1
          expect(response).to redirect_to organization_exports_path(organization_id: organization.to_param)
          export = Export.last
          expect(export.kind).to eq "organization"
          expect(export.file_format).to eq "csv"
          expect(export.user).to eq user
          expect(export.headers).to eq valid_attrs[:headers]
          expect(export.start_at.to_i).to be_within(1).of start_at
          expect(export.end_at.to_i).to be_within(1).of start_at + 2.days.to_i
          expect(export.bike_code_start).to be_nil
          expect(export.options["partial_registrations"]).to be_falsey # Both were false, so it defaults to just full
          expect(OrganizationExportWorker).to have_enqueued_sidekiq_job(export.id)
          expect(export.avery_export?).to be_falsey
          expect(export.custom_bike_ids).to eq([1222, 999])
        end
        context "with IE 11 datetime params" do
          let!(:bike_sticker) { FactoryBot.create(:bike_sticker, organization: organization, code: "a221") }
          let(:crushed_datetime_attrs) do
            {
              start_at: "08/25/2018",
              end_at: "09/30/2018",
              timezone: "",
              file_format: "csv",
              bike_code_start: "01", # Avery export organizations always submit a number here
              headers: %w[link registered_at organization_affiliation extra_registration_number phone address bike_sticker]
            }
          end
          it "creates the expected export" do
            expect {
              post :create, params: {export: crushed_datetime_attrs, organization_id: organization.to_param}
            }.to change(Export, :count).by 1
            expect(response).to redirect_to organization_exports_path(organization_id: organization.to_param)
            export = Export.last
            expect(export.kind).to eq "organization"
            expect(export.file_format).to eq "csv"
            expect(export.user).to eq user
            expect(export.headers).to eq crushed_datetime_attrs[:headers]
            expect(export.start_at.to_i).to be_within(1).of 1535173200
            expect(export.end_at.to_i).to be_within(1).of 1538283600 # Explicitly testing this in TimeParser
            expect(export.assign_bike_codes?).to be_falsey
            expect(OrganizationExportWorker).to have_enqueued_sidekiq_job(export.id)
          end
        end
        context "avery export" do
          let(:end_at) { 1457431200 }
          it "makes the avery export" do
            expect {
              post :create, params: {
                export: avery_params,
                organization_id: organization.to_param,
                include_partial_registrations: 1,
                include_full_registrations: 0
              }
            }.to change(Export, :count).by 1
            export = Export.last
            expect(response).to redirect_to organization_export_path(organization_id: organization.to_param, id: export.id, avery_redirect: true)
            expect(export.kind).to eq "organization"
            expect(export.file_format).to eq "xlsx"
            expect(export.user).to eq user
            expect(export.headers).to eq Export::AVERY_HEADERS
            expect(export.avery_export?).to be_truthy
            expect(export.start_at.to_i).to be_within(1).of start_at
            expect(export.end_at.to_i).to be_within(1).of end_at
            expect(export.options["partial_registrations"]).to be_falsey # Avery exports can't include partials
            expect(export.bike_code_start).to eq "A221"
            expect(OrganizationExportWorker).to have_enqueued_sidekiq_job(export.id)
          end
          context "avery export with already assigned bike_sticker" do
            let!(:bike_sticker) { FactoryBot.create(:bike_sticker_claimed, organization: organization, code: "a0221") }
            it "fails to make the avery export" do
              expect(bike_sticker.claimed?).to be_truthy
              expect {
                post :create, params: {export: avery_params, organization_id: organization.to_param}
              }.to_not change(Export, :count)
              expect(flash[:error]).to match(/sticker/)
            end
          end
        end
      end
    end

    describe "update bike_codes_removed" do
      let(:export) { FactoryBot.build(:export_avery, progress: "pending", file: nil, bike_code_start: "z ", organization: organization, user: user) }
      let(:bike) { FactoryBot.create(:bike_organized, creation_organization: organization) }
      let!(:bike_sticker) { FactoryBot.create(:bike_sticker, organization: organization, code: "z") }
      it "removes the bike codes" do
        export.options = export.options.merge(bike_codes_assigned: ["Z"])
        bike_sticker.claim(user: user, bike: bike)
        export.save
        export.reload
        bike_sticker.reload
        expect(export.assign_bike_codes?).to be_truthy
        expect(export.bike_stickers_assigned).to eq(["Z"])
        expect(export.bike_codes_removed?).to be_falsey
        expect(bike_sticker.claimed?).to be_truthy
        expect(bike_sticker.bike).to eq bike
        expect {
          put :update, params: {organization_id: organization.to_param, id: export.id, remove_bike_stickers: true}
        }.to change(BikeStickerUpdate, :count).by 1
        export.reload
        bike_sticker.reload
        expect(export.assign_bike_codes?).to be_truthy
        expect(export.bike_stickers_assigned).to eq(["Z"])
        expect(export.bike_codes_removed?).to be_truthy
        expect(bike_sticker.claimed?).to be_falsey
        expect(bike_sticker.bike).to be_nil
        expect(bike_sticker.bike_sticker_updates.count).to eq 2

        bike_sticker_update = bike_sticker.bike_sticker_updates.last
        expect(bike_sticker_update.kind).to eq "un_claim"
        expect(bike_sticker_update.creator_kind).to eq "creator_export"
        expect(bike_sticker_update.organization_kind).to eq "primary_organization"
        expect(bike_sticker_update.user).to eq user
        expect(bike_sticker_update.bike).to be_blank
        expect(bike_sticker_update.organization_id).to eq organization.id
      end
    end
  end
end
