class Workflow::Step::BranchPackageStep < Workflow::Step
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
      branch_package
    end
  end

  private

  def target_project_base_name
    step_instructions[:target_project]
  end

  def target_project
    Project.find_by(name: target_project_name)
  end

  def add_repositories?
    step_instructions[:add_repositories].blank? || step_instructions[:add_repositories] == 'enabled'
  end

  def branch_package
    create_branched_package if webhook_event_for_linking_or_branching?

    scm_synced? ? set_scmsync_on_target_package : add_branch_request_file(package: target_package)

    Workflows::ScmEventSubscriptionCreator.new(token, workflow_run, scm_webhook, target_package).call

    target_package
  end

  def check_source_access
    return if remote_source?

    # we don't have any package records on the frontend level for scmsynced projects, therefore
    # we can only check on the project level for sourceaccess permission
    if scm_synced_project?
      Pundit.authorize(@token.executor, Project.get_by_name(source_project_name), :source_access?)
      return
    end

    options = { use_source: false, follow_project_links: true, follow_multibuild: true }

    begin
      src_package = Package.get_by_project_and_name(source_project_name, source_package_name, options)
    rescue Package::UnknownObjectError
      raise BranchPackage::Errors::CanNotBranchPackageNotFound, "Package #{source_project_name}/#{source_package_name} not found, it could not be branched."
    end

    Pundit.authorize(@token.executor, src_package, :create_branch?)
  end

  def create_branched_package
    check_source_access

    # If we create target_project, BranchPackage.branch below will not create repositories
    if !add_repositories? && target_project.nil?
      project = Project.new(name: target_project_name)
      Pundit.authorize(@token.executor, project, :create?)

      project.relationships.build(user: @token.executor,
                                  role: Role.find_by_title('maintainer'))
      project.commit_user = User.session
      project.store
    end

    begin
      # Service running on package avoids branching it: wait until services finish
      Backend::Api::Sources::Package.wait_service(source_project_name, source_package_name)

      BranchPackage.new({ project: source_project_name, package: source_package_name,
                          target_project: target_project_name,
                          target_package: target_package_name }).branch
    rescue BranchPackage::InvalidArgument, InvalidProjectNameError, ArgumentError => e
      raise BranchPackage::Errors::CanNotBranchPackage, "Package #{source_project_name}/#{source_package_name} could not be branched: #{e.message}"
    rescue Project::WritePermissionError, CreateProjectNoPermission => e
      raise BranchPackage::Errors::CanNotBranchPackageNoPermission,
            "Package #{source_project_name}/#{source_package_name} could not be branched due to missing permissions: #{e.message}"
    end

    Event::BranchCommand.create(project: source_project_name, package: source_package_name,
                                targetproject: target_project_name,
                                targetpackage: target_package_name,
                                user: @token.executor.login)

    target_package
  end

  def add_branch_request_file(package:)
    branch_request_file = case scm_webhook.payload[:scm]
                          when 'github'
                            branch_request_content_github
                          when 'gitlab'
                            branch_request_content_gitlab
                          when 'gitea'
                            branch_request_content_gitea
                          end

    package.save_file({ file: branch_request_file, filename: '_branch_request', comment: 'Updated _branch_request file via SCM/CI Workflow run' })
  end

  def branch_request_content_github
    {
      # TODO: change to scm_webhook.payload[:action]
      # when check_for_branch_request method in obs-service-tar_scm accepts other actions than 'opened'
      # https://github.com/openSUSE/obs-service-tar_scm/blob/2319f50e741e058ad599a6890ac5c710112d5e48/TarSCM/tasks.py#L145
      action: 'opened',
      pull_request: {
        head: {
          repo: { full_name: scm_webhook.payload[:source_repository_full_name] },
          sha: scm_webhook.payload[:commit_sha]
        }
      }
    }.to_json
  end

  def branch_request_content_gitlab
    { object_kind: scm_webhook.payload[:object_kind],
      project: { http_url: scm_webhook.payload[:http_url] },
      object_attributes: { source: { default_branch: scm_webhook.payload[:commit_sha] } } }.to_json
  end

  def branch_request_content_gitea
    { object_kind: 'merge_request',
      project: { http_url: scm_webhook.payload[:http_url] },
      object_attributes: { source: { default_branch: scm_webhook.payload[:commit_sha] } } }.to_json
  end
end
