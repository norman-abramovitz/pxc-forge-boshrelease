require 'rspec'
require 'yaml'
require 'bosh/template/test'

describe 'pxc-blacksmith-plans manifests' do
  let(:release) { Bosh::Template::Test::ReleaseDir.new(File.join(File.dirname(__FILE__), '..')) }
  let(:job) { release.job('pxc-blacksmith-plans') }
  let(:base) { { 'environment' => 'lab', 'bosh_env' => 'lab-bosh' } }

  def render(plan, props = base)
    YAML.safe_load(job.template("plans/#{plan}/manifest.yml").render(props), aliases: true)
  end

  def group(manifest, name)
    manifest['instance_groups'].find { |g| g['name'] == name }
  end

  def job_in(group, name)
    group['jobs'].find { |j| j['name'] == name }
  end

  def release_entry(manifest, name)
    manifest['releases'].find { |r| r['name'] == name }
  end

  %w[standalone cluster].each do |plan|
    context "the #{plan} manifest" do
      let(:manifest) { render(plan) }
      let(:mysql) { job_in(group(manifest, 'mysql'), 'pxc-mysql')['properties'] }

      it 'defaults to the latest noble stemcell' do
        expect(manifest['stemcells']).to eq([{ 'alias' => 'default', 'os' => 'ubuntu-noble', 'version' => 'latest' }])
      end

      it 'takes the stemcell from the job properties' do
        m = render(plan, base.merge('stemcell_os' => 'ubuntu-resolute', 'stemcell_version' => '1.69'))
        expect(m['stemcells']).to eq([{ 'alias' => 'default', 'os' => 'ubuntu-resolute', 'version' => '1.69' }])
      end

      it 'pins pxc-release 2.0.15' do
        expect(release_entry(manifest, 'pxc')).to eq(
          'name' => 'pxc',
          'version' => '2.0.15',
          'url' => 'https://bosh.io/d/github.com/cloudfoundry/pxc-release?v=2.0.15',
          'sha1' => '3bb8ac90fde574c55cb9f405a67f2bac71207485'
        )
      end

      it 'pins bpm 1.4.41' do
        expect(release_entry(manifest, 'bpm')).to eq(
          'name' => 'bpm',
          'version' => '1.4.41',
          'url' => 'https://bosh.io/d/github.com/cloudfoundry/bpm-release?v=1.4.41',
          'sha1' => 'sha256:7b445508d63d2171d892ba33f836087e1e519b9782f44c5fa5290323616ca8e6'
        )
      end

      it 'takes the pxc release from the job properties' do
        m = render(plan, base.merge('pxc_release' => { 'version' => '2.0.14', 'url' => 'u', 'sha1' => 's' }))
        expect(release_entry(m, 'pxc')).to eq('name' => 'pxc', 'version' => '2.0.14', 'url' => 'u', 'sha1' => 's')
      end

      it 'runs MySQL 8.4' do
        expect(mysql['mysql_version']).to eq('8.4')
      end

      it 'seeds one remote admin user' do
        expect(mysql['seeded_users']).to eq(
          'admin' => { 'password' => '(( grab meta.admin_password ))', 'host' => 'any', 'role' => 'admin' }
        )
      end

      it 'keeps root local, with a generated password' do
        expect(mysql['admin_password']).to eq('((pxc_root_password))')
        expect(mysql).not_to have_key('remote_admin_access')
      end

      it 'serves TLS with a certificate from the services CA' do
        expect(mysql['tls']['server']).to eq('((pxc_server_tls))')
        cert = manifest['variables'].find { |v| v['name'] == 'pxc_server_tls' }
        expect(cert['type']).to eq('certificate')
        expect(cert['options']['ca']).to eq('(( concat "/" meta.bosh_env "-bosh/" meta.environment "-blacksmith/blacksmith_services_ca" ))')
      end

      # Clients verify the server's name: the binding host is a BOSH DNS
      # name, and the certificate covers every name in the client-facing
      # group through a wildcard link.
      it 'names the server certificate after the client-facing group' do
        cert = manifest['variables'].find { |v| v['name'] == 'pxc_server_tls' }
        expect(cert['options']['alternative_names']).to eq(['localhost'])
        expect(cert['consumes']).to eq(
          'alternative_name' => { 'from' => 'pxc-san', 'properties' => { 'wildcard' => true } }
        )
      end

      it 'takes tls.required from the plan' do
        expect(mysql['tls']['required']).to eq('(( grab meta.tls_required || false ))')
      end

      it 'rolls one VM at a time' do
        expect(manifest['update']['max_in_flight']).to eq(1)
      end

      it 'runs bpm on every instance group' do
        manifest['instance_groups'].each do |g|
          expect(job_in(g, 'bpm')).to eq('name' => 'bpm', 'release' => 'bpm')
        end
      end
    end
  end

  context 'the standalone manifest' do
    let(:manifest) { render('standalone') }

    it 'has one MySQL node and no proxy' do
      expect(manifest['instance_groups'].map { |g| g['name'] }).to eq(['mysql'])
      expect(group(manifest, 'mysql')['instances']).to eq(1)
    end

    it 'leaves Galera off' do
      props = job_in(group(manifest, 'mysql'), 'pxc-mysql')['properties']
      expect(props.dig('engine_config', 'galera', 'enabled')).to be_falsey
    end

    it 'gives the server certificate the node group DNS name' do
      node = job_in(group(manifest, 'mysql'), 'pxc-mysql')
      expect(node['provides']).to eq('pxc-san' => { 'as' => 'pxc-san', 'ip_addresses' => false })
      expect(node['custom_provider_definitions']).to eq([{ 'name' => 'pxc-san', 'type' => 'address' }])
    end
  end

  context 'the cluster manifest' do
    let(:manifest) { render('cluster') }
    let(:mysql_group) { group(manifest, 'mysql') }
    let(:mysql) { job_in(mysql_group, 'pxc-mysql')['properties'] }

    it 'has three MySQL nodes' do
      expect(mysql_group['instances']).to eq(3)
    end

    it 'turns Galera on with its own CA' do
      expect(mysql['engine_config']['galera']['enabled']).to eq(true)
      expect(mysql['tls']['galera']).to eq('((pxc_galera_tls))')
      ca = manifest['variables'].find { |v| v['name'] == 'pxc_galera_ca' }
      expect(ca['options']['is_ca']).to eq(true)
      cert = manifest['variables'].find { |v| v['name'] == 'pxc_galera_tls' }
      expect(cert['options']['ca']).to eq('pxc_galera_ca')
      expect(cert['options']['extended_key_usage']).to eq(%w[server_auth client_auth])
    end

    it 'runs the Galera support jobs on the nodes' do
      expect(mysql_group['jobs'].map { |j| j['name'] }).to include(
        'galera-agent', 'bootstrap', 'gra-log-purger', 'cluster-health-logger'
      )
      expect(job_in(mysql_group, 'galera-agent')['properties']).to eq(
        'endpoint_password' => '((pxc_galera_agent_endpoint_password))',
        'db_password' => '((pxc_galera_agent_db_password))'
      )
      expect(job_in(mysql_group, 'cluster-health-logger')['properties']).to eq(
        'db_password' => '((pxc_cluster_health_password))'
      )
    end

    it 'has two proxies' do
      proxy = group(manifest, 'proxy')
      expect(proxy['instances']).to eq(2)
      expect(job_in(proxy, 'proxy')['properties']).to eq('api_password' => '((pxc_proxy_api_password))')
    end

    # Clients reach the nodes through the proxies, so the certificate the
    # nodes serve carries the proxy group's name.
    it 'gives the server certificate the proxy group DNS name' do
      proxy = job_in(group(manifest, 'proxy'), 'proxy')
      expect(proxy['provides']).to eq('pxc-san' => { 'as' => 'pxc-san', 'ip_addresses' => false })
      expect(proxy['custom_provider_definitions']).to eq([{ 'name' => 'pxc-san', 'type' => 'address' }])
      expect(job_in(mysql_group, 'pxc-mysql')).not_to have_key('provides')
    end

    it 'generates every internal password' do
      names = manifest['variables'].select { |v| v['type'] == 'password' }.map { |v| v['name'] }
      expect(names).to contain_exactly(
        'pxc_root_password', 'pxc_galera_agent_endpoint_password', 'pxc_galera_agent_db_password',
        'pxc_cluster_health_password', 'pxc_proxy_api_password'
      )
    end
  end
end
