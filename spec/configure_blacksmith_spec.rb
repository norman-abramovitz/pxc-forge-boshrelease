require 'rspec'
require 'yaml'
require 'tmpdir'
require 'fileutils'
require 'open3'
require 'bosh/template/test'

# Renders bin/configure-blacksmith and runs it with bash, with /var/vcap
# moved to a temporary directory, then reads what it wrote.
describe 'pxc-blacksmith-plans bin/configure-blacksmith' do
  let(:release) { Bosh::Template::Test::ReleaseDir.new(File.join(File.dirname(__FILE__), '..')) }
  let(:job) { release.job('pxc-blacksmith-plans') }
  let(:tmpl) { job.template('bin/configure-blacksmith') }

  around do |example|
    Dir.mktmpdir do |dir|
      @vcap = dir
      src = File.join(dir, 'jobs/pxc-blacksmith-plans/plans')
      %w[standalone cluster].each do |type|
        FileUtils.mkdir_p(File.join(src, type))
        %w[init credentials.yml manifest.yml].each { |f| File.write(File.join(src, type, f), "#{type} #{f}\n") }
      end
      File.write(File.join(src, 'service.yml'), "service\n")
      example.run
    end
  end

  def run(plans)
    script = tmpl.render({ 'environment' => 'lab', 'bosh_env' => 'lab', 'plans' => plans })
    _, err, status = Open3.capture3('bash', '-c', script.gsub('/var/vcap', @vcap))
    raise "configure-blacksmith failed: #{err}" unless status.success?
  end

  def services
    File.join(@vcap, 'data/blacksmith/pxc-forge/services')
  end

  def written(plan, file)
    YAML.safe_load(File.read(File.join(services, plan, file)))
  end

  it 'writes plan defaults' do
    run('single' => { 'type' => 'standalone' })
    expect(written('single', 'plan.yml')).to eq(
      'id' => 'single', 'name' => 'single', 'limit' => 0, 'description' => 'no description provided'
    )
    expect(written('single', 'params.yml')).to eq(
      'meta' => { 'size' => 'default', 'net' => 'pxc-service',
                  'disk_config' => { 'persistent_disk' => 10_240 }, 'tls_required' => false }
    )
  end

  it 'writes the plan settings' do
    run('ha' => { 'type' => 'cluster', 'name' => 'HA', 'limit' => 3, 'vm_type' => 'large',
                  'proxy_vm_type' => 'small', 'network' => 'db', 'azs' => %w[z1 z2 z3],
                  'disk_type' => 'fast', 'tls_required' => true })
    expect(written('ha', 'plan.yml')).to include('id' => 'ha', 'name' => 'HA', 'limit' => 3)
    expect(written('ha', 'params.yml')).to eq(
      'meta' => { 'size' => 'large', 'proxy_size' => 'small', 'net' => 'db', 'azs' => %w[z1 z2 z3],
                  'disk_config' => { 'persistent_disk_type' => 'fast' }, 'tls_required' => true }
    )
  end

  it 'takes a disk size in MB' do
    run('big' => { 'type' => 'standalone', 'disk' => 51_200 })
    expect(written('big', 'params.yml')['meta']['disk_config']).to eq('persistent_disk' => 51_200)
  end

  it 'copies the files of the plan type and the service stub' do
    run('ha' => { 'type' => 'cluster' }, 'single' => { 'type' => 'standalone' })
    expect(File.read(File.join(services, 'service.yml'))).to eq("service\n")
    expect(File.read(File.join(services, 'ha', 'manifest.yml'))).to eq("cluster manifest.yml\n")
    expect(File.read(File.join(services, 'single', 'credentials.yml'))).to eq("standalone credentials.yml\n")
    expect(File.executable?(File.join(services, 'ha', 'init'))).to be(true)
  end

  it 'keeps shell characters in a description as written' do
    run('x' => { 'type' => 'standalone', 'description' => 'costs $5, see `man`' })
    expect(written('x', 'plan.yml')['description']).to eq('costs $5, see `man`')
  end

  it 'refuses an unknown plan type' do
    expect { run('x' => { 'type' => 'galera' }) }.to raise_error(/type 'galera'/)
  end
end
