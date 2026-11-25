# pxc-forge

A [Blacksmith](https://github.com/blacksmith-community/blacksmith) forge
for dedicated MySQL 8.4 instances, built on
[pxc-release](https://github.com/cloudfoundry/pxc-release) (Percona XtraDB
Cluster).

The forge holds plan templates only. Service instance deployments use
pxc-release and bpm from bosh.io; the versions are job properties, so an
operator can move them without a new forge release.

## Plan types

| Type | VMs | Shape |
|---|---|---|
| `standalone` | 1 | One MySQL 8.4 node, no replication. |
| `cluster` | 5 | Three MySQL nodes in a Galera cluster, two proxies in front. |

The proxies send all traffic to one healthy node and move it to another
node when that one fails. A cluster gives availability, not more write
capacity: Galera applies every write on every node.

To restart a cluster after all three nodes stopped, run the `bootstrap`
errand on the service instance deployment.

## Plans

Plans go in the `plans` property of the `pxc-blacksmith-plans` job, keyed by
plan id:

```yaml
plans:
  single:
    name: standalone
    description: A single MySQL 8.4 server, with no replication
    limit: 7
    type: standalone
  ha:
    name: cluster
    description: A 3-node Galera cluster behind 2 proxies
    limit: 4
    type: cluster
    vm_type: large
    proxy_vm_type: small
```

| Key | Default | Meaning |
|---|---|---|
| `name`, `description`, `limit` | id, —, 0 | Marketplace entry; a limit of 0 means no limit. |
| `type` | `standalone` | `standalone` or `cluster`. |
| `vm_type` | `default` | VM type of the MySQL nodes. |
| `proxy_vm_type` | `vm_type` | Cluster only: VM type of the proxies. |
| `network` | `pxc-service` | Network of all instance VMs. |
| `azs` | `[z1]` | Availability zones. |
| `disk` | `10240` | Persistent disk of each MySQL node, in MB. |
| `disk_type` | — | Persistent disk type from the cloud config; used instead of `disk`. |
| `tls_required` | `false` | Refuse client connections without TLS. |

## Job properties

| Property | Default |
|---|---|
| `environment`, `bosh_env` | required; they name the services CA (below) |
| `stemcell_os` | `ubuntu-noble` (`ubuntu-resolute` works too) |
| `stemcell_version` | `latest` |
| `pxc_release.{version,url,sha1}` | pxc-release 2.0.15 |
| `pxc_release.stemcell.{os,version}` | unset; for a compiled pxc-release (below) |
| `bpm_release.{version,url,sha1}` | bpm 1.4.41 (resolute needs 1.4.41 or later) |
| `service.{id,name,description,tags,limit}` | `pxc`, `pxc`, …, `[blacksmith, dedicated, mysql, pxc]`, 0 |

## Source and compiled pxc-release

By default, instance deployments use the pxc-release source tarball from
bosh.io. The first deployment on a director compiles Percona XtraDB
Cluster and XtraBackup, which takes about 90 minutes on four 2-CPU
compile VMs. The director keeps the compiled packages and reuses them
until the stemcell's major version changes; later deployments take a few
minutes.

To skip that compile, export a compiled release from a director that has
already built it, host the tarball where the director can fetch it, and
point the forge at it:

```
bosh export-release pxc/2.0.15 ubuntu-noble/<stemcell version>
```

```yaml
pxc_release:
  version: "2.0.15"
  url: https://example.com/pxc-2.0.15-ubuntu-noble-<stemcell version>.tgz
  sha1: <sha1 of the tarball>
  stemcell:
    os: ubuntu-noble
    version: "<stemcell version>"
```

A compiled release only deploys on a stemcell with the same OS and major
version.

`bosh deploy` reads `stemcell` to check whether the director already has
the release compiled for that stemcell. Blacksmith does not: it uploads
a release only when the director has no release of that name and
version. A director that already holds pxc-release 2.0.15 keeps the copy
it has, so set the compiled tarball before the first instance on that
director.

## Credentials and TLS

Each instance gets an `admin` user with all privileges, including `GRANT
OPTION`, from any host. Its password is generated into the instance's vault
path when the instance is created. `root` can only connect from the VM
itself; BOSH generates its password.

A binding returns:

| Key | Value |
|---|---|
| `host` | the BOSH DNS name of the MySQL node (standalone) or the first proxy (cluster) |
| `hosts` | cluster only: the BOSH DNS names of all proxies |
| `port` | 3306 |
| `username`, `password` | the `admin` user |
| `uri` | `mysql://<username>:<password>@<host>:3306/` |
| `ca_certificate` | the Blacksmith services CA |

MySQL serves TLS with a certificate that BOSH signs with the Blacksmith
services CA (`/<bosh_env>-bosh/<environment>-blacksmith/blacksmith_services_ca`).
The certificate covers `*.<group>.<network>.<deployment>.bosh`, the names the
binding hands out (group `mysql` for standalone, `proxy` for cluster), so
clients can verify the host name as well as the CA. The names resolve on
VMs that run BOSH DNS, such as Diego cells. Galera traffic between cluster nodes uses a CA of its own
for each instance.

## Development

```
make test   # renders the templates and merges them with graft
make dev    # builds a dev release tarball
```

`make test` needs Ruby with the `bosh-template` and `rspec` gems, and
[graft](https://github.com/fivetwenty-io/graft) on the PATH for the merge
tests.
