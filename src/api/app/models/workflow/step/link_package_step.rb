class Workflow::Step::LinkPackageStep < Workflow::Step
  include ScmSyncEnabledStep
  include TargetProjectLifeCycleSupport

  REQUIRED_KEYS = [:source_project, :source_package, :target_project].freeze

  validate :validate_source_project_and_package_name

  def call
    return unless valid?

    if scm_webhook.closed_merged_pull_request?
      destroy_target_project
    elsif scm_webhook.reopened_pull_request?
      restore_target_project
    else
      link_package
    end
  end

  private

  def link_package
    create_target_package if webhook_event_for_linking_or_branching?

    set_scmsync_on_target_package if scm_synced?

    Workflows::ScmEventSubscriptionCreator.new(token, workflow_run, scm_webhook, target_package).call

    target_package
  end

  def target_project_base_name
    step_instructions[:target_project]
  end

  def target_project
    Project.find_by(name: target_project_name)
  end

  def create_target_package
    create_project_and_package
    return if scm_synced?

    create_link
  end

  def create_project_and_package
    check_source_access

    raise PackageAlreadyExists, "Can not link package. The package #{target_package_name} already exists." if target_package.present?

    if target_project.nil?
      project = Project.new(name: target_project_name)
      Pundit.authorize(@token.executor, project, :create?)

      project.save!
      project.commit_user = User.session
      project.relationships.create!(user: User.session, role: Role.find_by_title('maintainer'))
      project.store
    end

    Pundit.authorize(@token.executor, target_project, :update?)
    target_project.packages.create(name: target_package_name)
  end

  # Will raise an exception if the source package is not accesible
  def check_source_access
    return if remote_source?

    Package.get_by_project_and_name(source_project_name, source_package_name)
  end

  def create_link
    Backend::Api::Sources::Package.write_link(target_project_name,
                                              target_package_name,
                                              @token.executor,
                                              link_xml(project: source_project_name, package: source_package_name))

    target_package
  end

  def link_xml(opts = {})
    # "<link package=\"foo\" project=\"bar\" />"
    Nokogiri::XML::Builder.new { |x| x.link(opts) }.doc.root.to_s
  end
end
