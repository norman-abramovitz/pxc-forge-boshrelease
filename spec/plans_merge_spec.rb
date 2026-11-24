require 'rspec'
require 'yaml'
require 'tmpdir'
require 'open3'
require 'bosh/template/test'

# Merges the rendered plan files with graft (the merger the broker uses),
# the way the broker does: the plan manifest first, then params.yml for a
# deploy, or the jobs list and credentials.yml for a bind. vault and file
# operators are swapped for literals, since neither exists here.
describe 'pxc-blacksmith-plans merged with graft' do
  let(:release) { Bosh::Template::Test::ReleaseDir.new(File.join(File.dirname(__FILE__), '..')) }
  let(:job) { release.job('pxc-blacksmith-plans') }
  let(:props) { { 'environment' => 'lab', 'bosh_env' => 'lab-bosh' } }

  # params.yml as configure-blacksmith writes it; the broker merges it into
  # the plan manifest for both a deploy and a bind.
  PARAMS = { 'meta' => { 'size' => 'default', 'net' => 'pxc-service',
                'disk_config' => { 'persistent_disk' => 10_240 }, 'tls_required' => false } }.freeze

  before(:all) { skip 'graft is not installed' unless system('command -v graft >/dev/null') }

  def offline(yaml)
    yaml.gsub('(( vault $CREDENTIALS "/admin:password" ))', 'TESTPW')
        .gsub(/\(\( file "[^"]+" \)\)/, 'SERVICES-CA')
  end

  def merge(*docs)
    Dir.mktmpdir do |dir|
      files = docs.each_with_index.map do |doc, i|
        path = File.join(dir, "#{i}.yml")
        File.write(path, doc.is_a?(String) ? doc : doc.to_yaml)
        path
      end
      out, err, status = Open3.capture3('graft', 'merge', *files)
      raise "graft merge failed: #{err}" unless status.success?
      YAML.safe_load(out, aliases: true)
    end
  end

  def manifest(plan)
    offline(job.template("plans/#{plan}/manifest.yml").render(props))
  end

  def credentials(plan, jobs)
    merged = merge(manifest(plan), PARAMS, { 'jobs' => jobs },
                   offline(job.template("plans/#{plan}/credentials.yml").render(props)),
                   { 'name' => 'deployment' }, { 'params' => { 'instance_id' => 'i', 'hostname' => '' } })
    merged['credentials']
  end

  def vm(name, ips)
    { 'name' => name, 'ips' => ips }
  end

  def pxc_props(merged)
    mysql = merged['instance_groups'].find { |g| g['name'] == 'mysql' }
    mysql['jobs'].find { |j| j['name'] == 'pxc-mysql' }['properties']
  end

  context 'a deploy' do
    let(:params) do
      { 'meta' => { 'size' => 'small', 'net' => 'pxc-service', 'azs' => ['z2'],
                    'disk_config' => { 'persistent_disk' => 20_480 }, 'tls_required' => true } }
    end

    %w[standalone cluster].each do |plan|
      it "resolves the #{plan} plan's grabs" do
        m = merge(manifest(plan), params)
        mysql = m['instance_groups'].find { |g| g['name'] == 'mysql' }
        expect(mysql['vm_type']).to eq('small')
        expect(mysql['networks']).to eq([{ 'name' => 'pxc-service' }])
        expect(mysql['azs']).to eq(['z2'])
        expect(mysql['persistent_disk']).to eq(20_480)
        expect(pxc_props(m)['seeded_users']['admin']['password']).to eq('TESTPW')
        expect(pxc_props(m)['tls']['required']).to eq(true)
        expect(m['variables'].find { |v| v['name'] == 'pxc_server_tls' }['options']['ca'])
          .to eq('/lab-bosh-bosh/lab-blacksmith/blacksmith_services_ca')
      end
    end

    it 'defaults tls_required to false' do
      m = merge(manifest('standalone'), { 'meta' => { 'size' => 'default', 'net' => 'pxc-service',
                                                      'disk_config' => { 'persistent_disk' => 10_240 } } })
      expect(pxc_props(m)['tls']['required']).to eq(false)
    end

    it 'sizes the cluster proxies apart from the nodes' do
      m = merge(manifest('cluster'), params.merge('meta' => params['meta'].merge('proxy_size' => 'tiny')))
      expect(m['instance_groups'].find { |g| g['name'] == 'proxy' }['vm_type']).to eq('tiny')
    end
  end

  context 'a bind' do
    it 'returns the admin user of a standalone node' do
      creds = credentials('standalone', [vm('mysql/0', ['10.0.0.5']), vm('mysql', ['10.0.0.5'])])
      expect(creds).to eq(
        'host' => '10.0.0.5',
        'port' => 3306,
        'username' => 'admin',
        'password' => 'TESTPW',
        'admin_username' => 'admin',
        'admin_password' => 'TESTPW',
        'uri' => 'mysql://admin:TESTPW@10.0.0.5:3306/',
        'ca_certificate' => 'SERVICES-CA'
      )
    end

    it 'points a cluster binding at the proxies' do
      creds = credentials('cluster', [
        vm('mysql/0', ['10.0.0.5']), vm('mysql/1', ['10.0.0.6']), vm('mysql/2', ['10.0.0.7']),
        vm('mysql', ['10.0.0.5', '10.0.0.6', '10.0.0.7']),
        vm('proxy/0', ['10.0.0.8']), vm('proxy/1', ['10.0.0.9']), vm('proxy', ['10.0.0.8', '10.0.0.9'])
      ])
      expect(creds['host']).to eq('10.0.0.8')
      expect(creds['hosts']).to eq(['10.0.0.8', '10.0.0.9'])
      expect(creds['uri']).to eq('mysql://admin:TESTPW@10.0.0.8:3306/')
      expect(creds['username']).to eq('admin')
    end
  end
end
