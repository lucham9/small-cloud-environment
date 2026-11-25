# Small cloud environment

AWS infrastructure for an Ann Arbor organization with approximately 20 staff and 150–200 users. A virtual firewall connects the premises through IPsec, while external and internal subnets separate public-facing services from directory, certificate, authentication and application systems.

**Status: Validated and planned; no AWS resources deployed.** Terraform installs Windows role features; domain, CA and NPS configuration requires the included PowerShell helper and organization-specific settings. See [VALIDATION.txt](VALIDATION.txt) for test results and limitations.

## Architecture

- **Region / AZ:** `us-east-2` / `us-east-2a`.
- **VPC:** `10.20.0.0/16`.
- **External subnet:** `10.20.1.0/24`, with firewall and web.
- **Internal subnet:** `10.20.2.0/24`, with four Windows servers, app and monitor.
- **Routing:** external internet access through an internet gateway; internal internet access through the firewall's NAT. Both subnets route the optional premises network to the firewall.

| Server | Private IP | Subnet | Role |
| --- | --- | --- | --- |
| firewall | `10.20.1.10` | External | strongSwan IPsec, firewall and NAT |
| web | `10.20.1.20` | External | nginx, reverse proxy and PKI publication directory |
| app | `10.20.2.40` | Internal | Reference HTTP application |
| monitor | `10.20.2.50` | Internal | Prometheus and Linux host metrics |
| dc1 | `10.20.2.10` | Internal | First AD DS domain controller / DNS |
| dc2 | `10.20.2.11` | Internal | Second AD DS domain controller / DNS |
| msca | `10.20.2.20` | Internal | Microsoft Certificate Authority, AD CS |
| nps | `10.20.2.21` | Internal | Network Policy Server, RADIUS |

| Systems | Instance | vCPU / RAM each | Encrypted gp3 storage each |
| --- | --- | --- | --- |
| Four Windows Server 2022 | `c6i.xlarge` | 4 / 8 GiB | 60 GiB |
| Four Ubuntu 24.04 | `t3.medium` | 2 / 4 GiB | 30 GiB |

Total capacity: **24 vCPUs, 48 GiB RAM and 360 GiB storage**. Ohio is a nearby regional hosting choice; actual network latency depends on the premises connection.

## Files and validation

| File | Purpose |
| --- | --- |
| `main.tf` | Infrastructure, security groups, instances and service bootstraps |
| `firewall-init.sh` | Firewall/NAT and optional IPsec template |
| `windows-roles.ps1` | Interactive Windows role configuration |
| `terraform.tfvars.example` | Safe sample settings |
| `tests/architecture.tftest.hcl` | Mocked, plan-only tests |
| `VALIDATION.txt` | Verification record |

Terraform 1.14 or later below 2.0 is required; AWS provider 6.22.0 is pinned. Keep `.terraform.lock.hcl` in Git. Run from the project directory:

```powershell
terraform init -backend=false -input=false
terraform fmt -check -recursive
terraform validate
terraform test
```

Provider installation needs internet access. Subsequent local checks use mocks without AWS credentials or resource creation. An authorized AWS-backed `terraform plan -input=false` resolves public AMIs and reviews proposed changes without launching infrastructure. Deployment is a separate billable operation; no automatic deployment workflow is included.

## Security and connectivity

All instances require IMDSv2 and encrypted disks. Public SSH/RDP are closed; SSM over outbound HTTPS is preferred for management. Internal NAT forwarding permits HTTP/HTTPS and rejects other unapproved traffic. Same-VPC traffic follows local AWS routing and destination security groups rather than central firewall inspection.

Firewall and web each have an Elastic IP. Web uses its address for updates and SSM, bypassing the NAT firewall for outbound internet traffic. Its security group denies direct public HTTP. Optional allowlisted internet HTTP enters through the firewall using DNAT/SNAT; it is disabled by default. The reference web/application service has no TLS or end-user authentication.

Windows security groups and host rules allow directory, DNS, RPC and RADIUS services only from internal or configured premises networks. Application TCP 8080 is limited to web/monitor; metrics TCP 9100 is limited to monitor. Administration and Prometheus access through the VPN remain restricted to appropriate hosts. Narrow premises rules to actual managed clients before operational use.

## Site-to-site IPsec

The premises team supplies a static public peer and a non-overlapping RFC1918 LAN CIDR. Configure `vpn` in private, ignored `terraform.tfvars`:

- IKEv2 with PSK; AES-256, SHA-256 and DH/PFS group 14.
- AWS protected network: `10.20.0.0/16`; premises network: the configured LAN.
- Transport: UDP 500 and forced ESP-in-UDP 4500, restricted to the peer.
- Both route tables return premises traffic through the firewall. Protected traffic requires IPsec policies and is exempt from NAT; cleartext fallback is denied.

Store a random 64-character hexadecimal PSK outside Terraform as an SSM SecureString in `us-east-2`. Supply only its ARN and, if applicable, the customer-managed KMS key ARN. The firewall retrieves it with scoped IAM permissions and writes a root-only configuration. Configure matching identities, selectors, proposals, NAT exemptions and return routes on the premises appliance. VPN remains disabled until real details are supplied.

## Windows configuration

User data installs AD DS/DNS on DC1/DC2, AD CS on MSCA and NPAS on NPS, recording status in `C:\ProgramData\School\bootstrap-status.json`. Feature installation alone does not configure those services.

Copy `windows-roles.ps1` to the matching host and run elevated Windows PowerShell 5.1. Replace the example domain with one the organization controls. The helper checks private IP and role/action pairing, requests passwords securely and sets hostnames. After a hostname change, restart and rerun; restart again after promotion or domain joining.

```powershell
# On DC1, then DC2:
.\windows-roles.ps1 -ServerRole DC1 -Action PromotePrimary -DomainName ad.school.example -NetbiosName SCHOOL
.\windows-roles.ps1 -ServerRole DC2 -Action PromoteSecondary -DomainName ad.school.example
# After promotion/restart, configure this on each DC:
Set-DnsServerForwarder -IPAddress 10.20.0.2

# On the matching member server, join and restart before configuration:
.\windows-roles.ps1 -ServerRole MSCA -Action JoinMember -DomainName ad.school.example
.\windows-roles.ps1 -ServerRole NPS -Action JoinMember -DomainName ad.school.example
.\windows-roles.ps1 -ServerRole MSCA -Action ConfigureCA -DomainName ad.school.example
.\windows-roles.ps1 -ServerRole NPS -Action RegisterNPS -DomainName ad.school.example
```

Use authorized domain credentials; CA installation needs enterprise CA permissions. ConfigureCA initializes an online Enterprise Root CA using RSA-3072/SHA-256. Before issuance, configure templates, enrollment permissions, AIA/CDP publication, protected backups and renewal procedures. Web's `/var/www/html/pki` directory is available for signed CA certificates and CRLs; publication content and jobs are not created automatically.

In `nps.msc`, configure actual RADIUS clients, securely entered shared secrets, an MSCA-issued server certificate, the approved EAP method, AD groups and network policies. Registration does not create an allow-all policy. Verify DNS, AD replication, certificate issuance/revocation and allowed/denied authentication before enabling service for users.

## Operational limits

This single-AZ design has one firewall/VPN endpoint and single-instance CA, NPS, web, app and monitor services. Two DCs address individual host failure, not AZ failure. Central logging, backups, recovery procedures and multi-AZ failover need further implementation.

A full launch requires 24 available standard On-Demand vCPUs. Actual operation incurs compute, storage, two public IPv4 addresses and applicable transfer charges. Use encrypted, access-controlled remote Terraform state for operational use. Never commit credentials, private keys, real variable files, state or saved plans.

Local checks and a successful AWS plan do not prove EC2 first boot, a working Windows domain, certificate services, RADIUS authentication or a negotiated premises VPN. Those remain unverified on deployed resources.
