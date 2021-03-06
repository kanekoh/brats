require 'spec_helper'
require 'bcrypt'

def generate_python_app(python_version, ucs2 = false)
  template = PythonTemplateApp.new(python_version, ucs2)
  template.generate!
  template
end

RSpec.shared_examples :a_deploy_of_python_app_to_cf do |python_version, stack, ucs2|
  context "with python#{ucs2 ? '-ucs2' : ''} version #{python_version}" do
    let(:browser) { Machete::Browser.new(@app) }

    before(:all) do
      app_template = generate_python_app(python_version, ucs2)
      @app = deploy_app(template: app_template, stack: stack, buildpack: 'python-brat-buildpack')
    end

    after(:all) { Machete::CF::DeleteApp.new.execute(@app) }

    it 'runs a simple webserver', version: python_version do
      expect(@app).to be_running

      2.times do
        browser.visit_path('/')
        expect(browser).to have_body('Hello, World')
      end
    end

    it 'uses the correct python version', version: python_version do
      2.times do
        browser.visit_path('/version')
        expect(browser).to have_body(python_version)
      end
    end

    it 'encrypts with bcrypt', version: python_version do
      2.times do
        browser.visit_path('/bcrypt')
        crypted_text = BCrypt::Password.new(browser.body)
        expect(crypted_text).to eq 'Hello, bcrypt'
      end
    end

    it 'supports postgres by raising a no connection error', version: python_version do
      2.times do
        browser.visit_path '/pg'
        expect(browser).to have_body 'could not connect to server: No such file or directory'
      end
    end

    it 'supports mysql by raising a no connection error', version: python_version do
      2.times do
        browser.visit_path '/mysql'
        expect(browser).to have_body "Can't connect to local MySQL server through socket '/var/run/mysqld/mysqld.sock'"
      end
    end

    it 'supports loading and running the hiredis lib', version: python_version do
      2.times do
        browser.visit_path('/redis')
        expect(browser).to have_body 'Hello'
      end
    end

    it 'supports the proper version of unicode', version: python_version do
      2.times do
        max_unicode =  ucs2 ? '65535' : '1114111'

        browser.visit_path('/unicode')
        expect(browser).to have_body "max unicode: #{max_unicode}"
      end
    end
  end
end

describe 'For the python buildpack', language: 'python' do
  after(:all) do
    cleanup_buildpack(buildpack: 'python')
  end

  describe 'deploying an app with an updated version of the same buildpack' do
    let(:stack)          { 'cflinuxfs2' }
    let(:python_version) { dependency_versions_in_manifest('python', 'python', stack).last }
    let(:app) do
      app_template = generate_python_app(python_version)
      deploy_app(template: app_template, stack: stack, buildpack: 'python-brat-buildpack')
    end

    before(:all) do
      cleanup_buildpack(buildpack: 'python')
      install_buildpack(buildpack: 'python')
    end

    after { Machete::CF::DeleteApp.new.execute(app) }

    it 'prints useful warning message to stdout' do
      expect(app).to_not have_logged('WARNING: buildpack version changed from')
      bump_buildpack_version(buildpack: 'python')
      Machete.push(app)
      expect(app).to have_logged('WARNING: buildpack version changed from')
    end
  end

  describe 'staging with python buildpack that sets EOL on dependency' do
    let(:stack)      { 'cflinuxfs2' }
    let(:python_version) { dependency_versions_in_manifest('python', 'python', stack).last }
    let(:app) do
      app_template = generate_python_app(python_version)
      deploy_app(template: app_template, stack: stack, buildpack: 'python-brat-buildpack')
    end

    let(:version_line) { python_version.gsub(/\.\d+$/,'') }
    let(:eol_date) { (Date.today + 10) }
    let(:warning_message) { /WARNING: python #{version_line} will no longer be available in new buildpacks released after/ }

    before do
      cleanup_buildpack(buildpack: 'python')
      install_buildpack(buildpack: 'python', buildpack_caching: caching) do
        hash = YAML.load_file('manifest.yml')
        hash['dependency_deprecation_dates'] = [{
          'match' => version_line + '\.\d+',
          'version_line' => version_line,
          'name' => 'python',
          'date' => eol_date
        }]
        File.write('manifest.yml', hash.to_yaml)
      end
    end

    after { Machete::CF::DeleteApp.new.execute(app) }

    context "using an uncached buildpack" do
      let(:caching)        { :uncached }

      it 'warns about end of life' do
        expect(app).to have_logged(warning_message)
      end
    end

    context "using an uncached buildpack" do
      let(:caching)        { :cached }

      it 'warns about end of life' do
        expect(app).to have_logged(warning_message)
      end
    end
  end

  describe 'staging with a version of python that is not the latest patch release in the manifest' do
    let(:stack)      { 'cflinuxfs2' }
    let(:python_version) do
      dependency_versions_in_manifest('python', 'python', stack).sort do |ver1, ver2|
        Gem::Version.new(ver1) <=> Gem::Version.new(ver2)
      end.first
    end

    let(:app) do
      app_template = generate_python_app(python_version)
      deploy_app(template: app_template, stack: stack, buildpack: 'python-brat-buildpack')
    end

    before do
      cleanup_buildpack(buildpack: 'python')
      install_buildpack(buildpack: 'python')
    end

    after { Machete::CF::DeleteApp.new.execute(app) }

    it 'logs a warning that tells the user to upgrade the dependency' do
      expect(app).to have_logged(/\*\*WARNING\*\* A newer version of python is available in this buildpack/)
    end
  end

  describe 'For all supported Python versions' do
    before(:all) do
      cleanup_buildpack(buildpack: 'python')
      install_buildpack(buildpack: 'python')
    end


    if is_current_user_language_tag?('python')
      ['cflinuxfs2'].each do |stack|
        context "on the #{stack} stack", stack: stack do
          python_ucs2_versions = dependency_versions_in_manifest('python', 'python-ucs2', stack)
          python_ucs2_versions.each do |python_version|
            it_behaves_like :a_deploy_of_python_app_to_cf, python_version, stack, true
          end

          python_versions = dependency_versions_in_manifest('python', 'python', stack)
          python_versions.each do |python_version|
            it_behaves_like :a_deploy_of_python_app_to_cf, python_version, stack, false
          end
        end
      end
    end
  end

  describe 'staging with custom buildpack that uses credentials in manifest dependency uris' do
    let(:stack)          { 'cflinuxfs2' }
    let(:python_version) { dependency_versions_in_manifest('python', 'python', stack).last }
    let(:app) do
      app_template = generate_python_app(python_version)
      deploy_app(template: app_template, stack: stack, buildpack: 'python-brat-buildpack')
    end

    before do
      cleanup_buildpack(buildpack: 'python')
      install_buildpack_with_uri_credentials(buildpack: 'python', buildpack_caching: caching)
    end

    after { Machete::CF::DeleteApp.new.execute(app) }

    context "using an uncached buildpack" do
      let(:caching)        { :uncached }
      let(:credential_uri) { Regexp.new(Regexp.quote('https://') + 'login:password[@]') }
      let(:python_uri)     { Regexp.new(Regexp.quote('https://-redacted-:-redacted-@buildpacks.cloudfoundry.org/dependencies/python/python-') + '[\d\.]+' + Regexp.quote('-linux-x64-') + '[\da-f]+' + Regexp.quote('.tgz')) }

      it 'does not include credentials in logged dependency uris' do
        expect(app).to_not have_logged(credential_uri)
        expect(app).to have_logged(python_uri)
      end
    end

    context "using a cached buildpack" do
      let(:caching)        { :cached }
      let(:credential_uri) { Regexp.new('https___login_password') }
      let(:python_uri)     { Regexp.new(Regexp.quote('https___-redacted-_-redacted-@buildpacks.cloudfoundry.org_dependencies_python_python-') + '[\d\.]+' + Regexp.quote('-linux-x64-') + '[\da-f]+' + Regexp.quote('.tgz')) }

      it 'does not include credentials in logged dependency file paths' do
        expect(app).to_not have_logged(credential_uri)
        expect(app).to have_logged(python_uri)
      end
    end
  end

  describe 'deploying an app that has an executable .profile script' do
    let(:stack)          { 'cflinuxfs2' }
    let(:python_version) { dependency_versions_in_manifest('python', 'python', stack).last }
    let(:app) do
      app_template = generate_python_app(python_version)
      add_dot_profile_script_to_app(app_template.full_path)
      deploy_app(template: app_template, stack: stack, buildpack: 'python-brat-buildpack')
    end
    let(:browser) { Machete::Browser.new(app) }

    before(:all) do
      skip_if_no_dot_profile_support_on_targeted_cf
      cleanup_buildpack(buildpack: 'python')
      install_buildpack(buildpack: 'python')
    end

    after { Machete::CF::DeleteApp.new.execute(app) }

    it 'executes the .profile script' do
      expect(app).to have_logged("PROFILE_SCRIPT_IS_PRESENT_AND_RAN")
    end

    it 'does not let me view the .profile script' do
      browser.visit_path('/.profile', allow_404: true)
      expect(browser).to_not have_body 'PROFILE_SCRIPT_IS_PRESENT_AND_RAN'
    end
  end

  describe 'deploying an app that has sensitive environment variables' do
    let(:stack)          { 'cflinuxfs2' }
    let(:python_version) { dependency_versions_in_manifest('python', 'python', stack).last }
    let(:app) do
      app_template = generate_python_app(python_version)
      deploy_app(template: app_template, stack: stack, buildpack: 'python-brat-buildpack')
    end

    before(:all) do
      cleanup_buildpack(buildpack: 'python')
      install_buildpack(buildpack: 'python')
    end

    it 'will not write credentials to the app droplet' do
      expect(app).to be_running
      expect(app.name).to keep_credentials_out_of_droplet
    end
  end

end
