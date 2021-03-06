module BitswarmBox
  # Class which drives the build process.
  class Builder
    include BitswarmBox::Errors

    attr_accessor :name, :description
    attr_accessor :template, :scripts, :provider, :provisioner, :packer_shell_exec_cmd
    attr_accessor :puppet, :puppetserver, :foreman, :ansible, :chef, :docker, :bootstrap
    attr_accessor :app_creator, :app_project, :app_version
    attr_accessor :aws_access_key, :aws_secret_key, :aws_region, :aws_source_ami, :aws_user_data

    # Initialise a new build.
    #
    # @param env [BitswarmBox::Environment] environment to operate in.
    # @param args [Hash]
    # @param template [String] the name of the template.
    # @param scripts [Array] scripts to include in the build.
    def initialize(env, args) # rubocop:disable Metrics/MethodLength
      @environment = env
      @provisioner = args[:provisioner] || fail(MissingArgumentError,
                                          'The provisioner must be specified.')
      @packer_shell_exec_cmd = args[:packer_shell_exec_cmd] || 'chmod +x {{ .Path }}; {{ .Vars }} {{ .Path }}'
      @name = args[:name] || fail(MissingArgumentError,
                                  'The name must be specified.')
      @description = args[:description]
      @provider = args[:provider] || fail(MissingArgumentError,
                                          'The provider must be specified.')
      template = args[:template] || fail(MissingArgumentError,
                                         'The template must be specified.')
      scripts = args.fetch(:scripts, [])

      @template = Template.new(env, template)
      @scripts = scripts.collect do |c|
        env.available_scripts.include?(c) ? c : fail(ScriptNotFoundError)
      end

      @puppet = args[:puppet]
      @puppetserver = args[:puppetserver]
      @foreman = args[:foreman]
      @chef = args[:chef]
      @ansible = args[:ansible]
      @docker = args[:docker]

      @app_creator = args[:app_creator] || ENV['USER']
      @app_project = args[:app_project] || 'default'
      @app_version = args[:app_version] || BitswarmBox::VERSION

      if @provisioner == 'aws'
        @aws_access_key = args[:aws_access_key]
        @aws_secret_key = args[:aws_secret_key]
        @aws_region = args[:aws_region]
        @aws_source_ami = args[:aws_source_ami]
        @aws_user_data = args[:aws_user_data]
      end

      @bootstrap = args[:bootstrap]
    end

    # Run the build.
    def run # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
      original_directory = FileUtils.pwd
      box_name = ''
      ami = ''

      # render the template
      if provisioner == 'aws'
        rendered_template = template.render(name: name,
                                            description: description,
                                            provider: provider,
                                            provisioner: provisioner,
                                            shell_exec_cmd: packer_shell_exec_cmd,
                                            scripts: scripts,
                                            puppet: puppet,
                                            puppetserver: puppetserver,
                                            foreman: foreman,
                                            chef: chef,
                                            ansible: ansible,
                                            docker: docker,
                                            bootstrap: bootstrap,
                                            app_creator: app_creator,
                                            app_project: app_project,
                                            app_version: app_version,
                                            aws_access_key: aws_access_key,
                                            aws_secret_key: aws_secret_key,
                                            aws_region: aws_region,
                                            aws_source_ami: aws_source_ami,
                                            aws_user_data: aws_user_data,
        )
      else
        rendered_template = template.render(name: name,
                                            provider: provider,
                                            provisioner: provisioner,
                                            shell_exec_cmd: packer_shell_exec_cmd,
                                            scripts: scripts,
                                            puppet: puppet,
                                            puppetserver: puppetserver,
                                            foreman: foreman,
                                            chef: chef,
                                            ansible: ansible,
                                            docker: docker,
                                            bootstrap: bootstrap,
                                            app_creator: app_creator,
                                            app_project: app_project,
                                            app_version: app_version,
        )
      end

      # write the template to a file
      File.open(BitswarmBox.config.working_dir + "#{build_name}.json", 'w') do |f|
        f.puts rendered_template
      end

      # set the environment vars
      BitswarmBox.config.environment_vars.each do |e|
        e.each do |k, v|
          ENV[k] = v.to_s
        end
      end

      # execute the packer validate command
      FileUtils.chdir(BitswarmBox.config.working_dir)
      cmd = "packer validate #{build_name}.json"
      status = Subprocess.run(cmd) do |stdout, stderr, _thread|
        puts stdout unless stdout.nil?
        puts stderr unless stderr.nil?
        fail() unless stderr.nil?
      end

      # execute the packer inspect command
      # FileUtils.chdir(BitswarmBox.config.working_dir)
      # cmd = "packer inspect #{build_name}.json"
      # status = Subprocess.run(cmd) do |stdout, stderr, _thread|
      #   puts stdout unless stdout.nil?
      #   puts stderr unless stderr.nil?
      #   fail() unless stderr.nil?
      # end

      # execute the packer build command
      FileUtils.chdir(BitswarmBox.config.working_dir)
      cmd = "packer build --force #{build_name}.json"
      status = Subprocess.run(cmd) do |stdout, stderr, _thread|
        puts stdout unless stdout.nil?
        puts stderr unless stderr.nil?

        # catch the name of the artifact
        if @provisioner == 'vagrant' && stdout =~ /\.box/
          box_name = stdout.gsub(/[a-zA-Z0-9:\.\-_]*?\.box/).first
        end

        if @provisioner == 'aws' && stdout =~ /ami\-[a-f0-9]+/
          ami = stdout.gsub(/ami\-[a-f0-9]+/).first
        end
      end

      if status.exitstatus == 0
        if @provisioner == 'vagrant'
          FileUtils.mv(BitswarmBox.config.working_dir + box_name,
                     "#{original_directory}/#{box_name}")
        elsif @provisioner == 'aws'
          puts "All done! AWS EC2 AMI #{ami} created for #{@build_name}."
        end

      else
        fail BuildRunError,
             'The build didn\'t complete successfully. Check the logs.'
      end
    end

    def finalize
      @environment.sync_ssh_keys(true)
    end

    # Clean any temporary files used during building.
    def clean
      FileUtils.rm("#{build_name}.json")
    end

    private

    def build_name
      @build_name ||= "#{@name}-#{Time.now.strftime('%Y%m%d%H%M%S')}"
    end
  end
end
