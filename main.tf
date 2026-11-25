# Small cloud environment. AWS infrastructure, role feature bootstraps and Linux services.
# Keep firewall-init.sh and windows-roles.ps1 with this configuration.
terraform {
  required_version = ">= 1.14.0, < 2.0.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "= 6.22.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
  default_tags {
    tags = {
      Project     = var.project_name
      Environment = "development"
      ManagedBy   = "Terraform"
    }
  }
}

variable "project_name" {
  type        = string
  default     = "small-cloud-environment"
  description = "Short prefix for names and tags."
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,24}$", var.project_name))
    error_message = "Use 3-25 lowercase letters, digits or hyphens, starting with a letter."
  }
}

variable "availability_zone" {
  type        = string
  default     = "us-east-1a"
  description = "Both required subnets are in one AZ; this single-AZ topology is not highly available."
  validation {
    condition     = can(regex("^us-east-1[a-f]$", var.availability_zone))
    error_message = "Choose an availability zone from us-east-1a through us-east-1f."
  }
}

variable "key_name" {
  type        = string
  default     = null
  nullable    = true
  description = "Optional EXISTING EC2 key pair in us-east-1. No private keys are generated. Prefer SSM."
}

variable "web_ingress_cidrs" {
  type        = list(string)
  default     = []
  description = "IPv4 ranges allowed to reach the demo HTTP site through the firewall. Empty disables publication."
  validation {
    condition     = alltrue([for c in var.web_ingress_cidrs : can(cidrnetmask(c))])
    error_message = "Supply valid IPv4 CIDRs, for example 203.0.113.10/32."
  }
}

variable "vpn" {
  description = "Optional school-site IKEv2 VPN. SSM SecureString must already exist; only its ARN enters Terraform."
  type = object({
    enabled           = bool
    peer_public_ip    = string
    remote_cidr       = string
    psk_parameter_arn = string
    kms_key_arn       = optional(string, null)
  })
  default = {
    enabled           = false
    peer_public_ip    = "192.0.2.10"
    remote_cidr       = "192.168.50.0/24"
    psk_parameter_arn = ""
  }
  validation {
    condition = (
      can(cidrnetmask("${var.vpn.peer_public_ip}/32")) &&
      can(cidrnetmask(var.vpn.remote_cidr)) &&
      can(regex("^(10\\.|172\\.(1[6-9]|2[0-9]|3[01])\\.|192\\.168\\.)", cidrhost(var.vpn.remote_cidr, 0))) &&
      try(tonumber(split("/", var.vpn.remote_cidr)[1]) >= 16, false) &&
      !can(regex("^10\\.20\\.", cidrhost(var.vpn.remote_cidr, 0)))
    )
    error_message = "Use an IPv4 peer and an RFC1918 /16 or smaller school network outside 10.20.0.0/16."
  }
  validation {
    condition = !var.vpn.enabled || (
      can(regex("^arn:aws:ssm:us-east-1:[0-9]{12}:parameter/[A-Za-z0-9_./-]+$", var.vpn.psk_parameter_arn)) &&
      !can(regex("^(192\\.0\\.2\\.|198\\.51\\.100\\.|203\\.0\\.113\\.|10\\.|172\\.(1[6-9]|2[0-9]|3[01])\\.|192\\.168\\.|0\\.|127\\.|169\\.254\\.|100\\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\\.|(22[4-9]|23[0-9]|24[0-9]|25[0-5])\\.)", var.vpn.peer_public_ip))
    )
    error_message = "Enabled VPN requires a real public peer IPv4 address and an existing us-east-1 SSM parameter ARN."
  }
  validation {
    condition     = var.vpn.kms_key_arn == null || can(regex("^arn:aws:kms:us-east-1:[0-9]{12}:key/[A-Za-z0-9-]+$", var.vpn.kms_key_arn))
    error_message = "kms_key_arn must be null or a us-east-1 KMS key ARN."
  }
}

locals {
  vpc_cidr      = "10.20.0.0/16"
  external_cidr = "10.20.1.0/24"
  internal_cidr = "10.20.2.0/24"
  firewall_ip   = "10.20.1.10"
  windows = {
    dc1  = { ip = "10.20.2.10", intended_role = "Primary domain controller / DNS", features = ["AD-Domain-Services", "DNS"] }
    dc2  = { ip = "10.20.2.11", intended_role = "Secondary domain controller / DNS", features = ["AD-Domain-Services", "DNS"] }
    msca = { ip = "10.20.2.20", intended_role = "Microsoft Certificate Authority (AD CS)", features = ["ADCS-Cert-Authority"] }
    nps  = { ip = "10.20.2.21", intended_role = "Network Policy Server (RADIUS)", features = ["NPAS"] }
  }
  ubuntu = {
    web     = { ip = "10.20.1.20", subnet = "external", role = "nginx demo web / reverse proxy" }
    app     = { ip = "10.20.2.40", subnet = "internal", role = "Python demo application" }
    monitor = { ip = "10.20.2.50", subnet = "internal", role = "Prometheus / node exporter" }
  }
  # Windows services require both AWS and Windows rules. Domain/CA credentials
  # are intentionally supplied interactively through windows-roles.ps1, not Terraform.
  windows_service_ports = {
    dns_tcp         = { targets = ["dc1", "dc2"], protocol = "tcp", from = 53, to = 53 }
    dns_udp         = { targets = ["dc1", "dc2"], protocol = "udp", from = 53, to = 53 }
    kerberos_tcp    = { targets = ["dc1", "dc2"], protocol = "tcp", from = 88, to = 88 }
    kerberos_udp    = { targets = ["dc1", "dc2"], protocol = "udp", from = 88, to = 88 }
    time_udp        = { targets = ["dc1", "dc2"], protocol = "udp", from = 123, to = 123 }
    ldap_tcp        = { targets = ["dc1", "dc2"], protocol = "tcp", from = 389, to = 389 }
    ldap_udp        = { targets = ["dc1", "dc2"], protocol = "udp", from = 389, to = 389 }
    smb_tcp         = { targets = ["dc1", "dc2"], protocol = "tcp", from = 445, to = 445 }
    password_tcp    = { targets = ["dc1", "dc2"], protocol = "tcp", from = 464, to = 464 }
    password_udp    = { targets = ["dc1", "dc2"], protocol = "udp", from = 464, to = 464 }
    ldaps_tcp       = { targets = ["dc1", "dc2"], protocol = "tcp", from = 636, to = 636 }
    catalog_tcp     = { targets = ["dc1", "dc2"], protocol = "tcp", from = 3268, to = 3269 }
    adws_tcp        = { targets = ["dc1", "dc2"], protocol = "tcp", from = 9389, to = 9389 }
    rpc_tcp         = { targets = ["dc1", "dc2", "msca"], protocol = "tcp", from = 135, to = 135 }
    rpc_dynamic_tcp = { targets = ["dc1", "dc2", "msca"], protocol = "tcp", from = 49152, to = 65535 }
    radius_udp      = { targets = ["nps"], protocol = "udp", from = 1812, to = 1813 }
  }
  windows_sources = merge(
    { internal = local.internal_cidr },
    var.vpn.enabled ? { school = var.vpn.remote_cidr } : {}
  )
  windows_role_ingress = merge([for port_name, port in local.windows_service_ports : merge([
    for target in port.targets : {
      for source_name, source in local.windows_sources : "${target}_${port_name}_${source_name}" => {
        group = target, source = source, protocol = port.protocol, from = port.from, to = port.to
      }
    }
  ]...)]...)
  # Small functional examples, not a production student-information system.
  linux_common = <<-SH
    #!/bin/bash
    set -euo pipefail
    export DEBIAN_FRONTEND=noninteractive
    retry() { for attempt in $(seq 1 90); do if "$@"; then return 0; fi; sleep 10; done; return 1; }
    retry apt-get update
    retry apt-get install -y prometheus-node-exporter curl
    systemctl enable --now prometheus-node-exporter
    if command -v snap >/dev/null; then snap start amazon-ssm-agent || true; fi
  SH
  linux_scripts = {
    web     = <<-SH
      retry apt-get install -y nginx
      install -d -m 755 /var/www/html/pki
      cat >/etc/nginx/sites-available/default <<'NGINX'
      server {
        listen 80 default_server;
        server_name _;
        location / {
          default_type text/html;
          return 200 '<h1>Small cloud environment</h1><p>Web service online.</p><a href="/api/health">Application health</a>';
        }
        location /api/ {
          proxy_pass http://10.20.2.40:8080/;
          proxy_connect_timeout 5s;
          proxy_read_timeout 10s;
        }
        location /pki/ {
          root /var/www/html;
          autoindex off;
          try_files $uri =404;
        }
      }
      NGINX
      nginx -t
      systemctl enable nginx
      systemctl restart nginx
    SH
    app     = <<-SH
      retry apt-get install -y python3
      install -d -o nobody -g nogroup /opt/school-app
      cat >/opt/school-app/app.py <<'PY'
      import json
      from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
      class Handler(BaseHTTPRequestHandler):
          def do_GET(self):
              if self.path != "/health":
                  self.send_error(404)
                  return
              body = json.dumps({"service": "school-app", "status": "ok"}).encode()
              self.send_response(200)
              self.send_header("Content-Type", "application/json")
              self.send_header("Content-Length", str(len(body)))
              self.end_headers()
              self.wfile.write(body)
      ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
      PY
      cat >/etc/systemd/system/school-app.service <<'UNIT'
      [Unit]
      Description=Small cloud environment application
      After=network-online.target
      Wants=network-online.target
      [Service]
      User=nobody
      Group=nogroup
      ExecStart=/usr/bin/python3 /opt/school-app/app.py
      Restart=on-failure
      NoNewPrivileges=true
      ProtectSystem=strict
      ProtectHome=true
      PrivateTmp=true
      [Install]
      WantedBy=multi-user.target
      UNIT
      systemctl daemon-reload
      systemctl enable --now school-app
    SH
    monitor = <<-SH
      retry apt-get install -y prometheus
      cat >/etc/prometheus/prometheus.yml <<'YAML'
      global:
        scrape_interval: 30s
      scrape_configs:
        - job_name: prometheus
          static_configs:
            - targets: ['127.0.0.1:9090']
        - job_name: ubuntu
          static_configs:
            - targets: ['10.20.1.10:9100', '10.20.1.20:9100', '10.20.2.40:9100', '10.20.2.50:9100']
      YAML
      chown root:prometheus /etc/prometheus/prometheus.yml
      chmod 640 /etc/prometheus/prometheus.yml
      promtool check config /etc/prometheus/prometheus.yml
      systemctl enable prometheus
      systemctl restart prometheus
    SH
  }
  workload_ingress = merge(
    local.windows_role_ingress,
    {
      web_http    = { group = "web", source = "${local.firewall_ip}/32", protocol = "tcp", from = 80, to = 80 }
      app_web     = { group = "app", source = "${local.ubuntu.web.ip}/32", protocol = "tcp", from = 8080, to = 8080 }
      app_monitor = { group = "app", source = "${local.ubuntu.monitor.ip}/32", protocol = "tcp", from = 8080, to = 8080 }
    },
    { for name, node in local.ubuntu : "${name}_metrics" => { group = name, source = "${local.ubuntu.monitor.ip}/32", protocol = "tcp", from = 9100, to = 9100 } },
    var.vpn.enabled ? merge(
      { for name, node in local.ubuntu : "${name}_ssh" => { group = name, source = var.vpn.remote_cidr, protocol = "tcp", from = 22, to = 22 } },
      { for name, node in local.windows : "${name}_rdp" => { group = name, source = var.vpn.remote_cidr, protocol = "tcp", from = 3389, to = 3389 } },
      { for name in concat(keys(local.ubuntu), keys(local.windows)) : "${name}_ping" => { group = name, source = var.vpn.remote_cidr, protocol = "icmp", from = 8, to = -1 } },
      {
        monitor_ui = { group = "monitor", source = var.vpn.remote_cidr, protocol = "tcp", from = 9090, to = 9090 }
        web_site   = { group = "web", source = var.vpn.remote_cidr, protocol = "tcp", from = 80, to = 80 }
      }
    ) : {}
  )
}

data "aws_ssm_parameter" "ubuntu_ami" {
  name = "/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id"
}

data "aws_ssm_parameter" "windows_ami" {
  name = "/aws/service/ami-windows-latest/Windows_Server-2022-English-Full-Base"
}

resource "aws_vpc" "school" {
  cidr_block           = local.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "${var.project_name}-vpc" }
}

resource "aws_subnet" "external" {
  vpc_id                  = aws_vpc.school.id
  cidr_block              = local.external_cidr
  availability_zone       = var.availability_zone
  map_public_ip_on_launch = false
  tags                    = { Name = "${var.project_name}-external" }
}

resource "aws_subnet" "internal" {
  vpc_id                  = aws_vpc.school.id
  cidr_block              = local.internal_cidr
  availability_zone       = var.availability_zone
  map_public_ip_on_launch = false
  tags                    = { Name = "${var.project_name}-internal" }
}

resource "aws_internet_gateway" "school" {
  vpc_id = aws_vpc.school.id
  tags   = { Name = "${var.project_name}-igw" }
}

resource "aws_route_table" "external" {
  vpc_id = aws_vpc.school.id
  tags   = { Name = "${var.project_name}-external" }
}

resource "aws_route" "external_internet" {
  route_table_id         = aws_route_table.external.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.school.id
}

resource "aws_route_table_association" "external" {
  subnet_id      = aws_subnet.external.id
  route_table_id = aws_route_table.external.id
}

resource "aws_route_table" "internal" {
  vpc_id = aws_vpc.school.id
  tags   = { Name = "${var.project_name}-internal" }
}

resource "aws_route" "internal_internet" {
  route_table_id         = aws_route_table.internal.id
  destination_cidr_block = "0.0.0.0/0"
  network_interface_id   = aws_network_interface.firewall.id
}

resource "aws_route" "school_vpn" {
  count                  = var.vpn.enabled ? 1 : 0
  route_table_id         = aws_route_table.internal.id
  destination_cidr_block = var.vpn.remote_cidr
  network_interface_id   = aws_network_interface.firewall.id
}

resource "aws_route" "external_school_vpn" {
  count                  = var.vpn.enabled ? 1 : 0
  route_table_id         = aws_route_table.external.id
  destination_cidr_block = var.vpn.remote_cidr
  network_interface_id   = aws_network_interface.firewall.id
}

resource "aws_route_table_association" "internal" {
  subnet_id      = aws_subnet.internal.id
  route_table_id = aws_route_table.internal.id
}

# Separate IAM roles: workloads cannot read the VPN secret.
resource "aws_iam_role" "instance" {
  for_each    = toset(["firewall", "workload"])
  name_prefix = "${var.project_name}-${each.key}-"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Action = "sts:AssumeRole", Principal = { Service = "ec2.amazonaws.com" } }]
  })
}

resource "aws_iam_role_policy" "ssm" {
  for_each = aws_iam_role.instance
  name     = "ssm-management-without-parameter-access"
  role     = each.value.name
  # Session Manager and command delivery without the Parameter Store read access
  # included in AmazonSSMManagedInstanceCore. VPN access is separately scoped.
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow", Resource = "*"
        Action = [
          "ssm:DescribeAssociation", "ssm:GetDocument", "ssm:DescribeDocument",
          "ssm:ListAssociations", "ssm:ListInstanceAssociations", "ssm:PutInventory",
          "ssm:PutComplianceItems", "ssm:PutConfigurePackageResult",
          "ssm:UpdateAssociationStatus", "ssm:UpdateInstanceAssociationStatus",
          "ssm:UpdateInstanceInformation"
        ]
      },
      {
        Effect = "Allow", Resource = "*"
        Action = [
          "ssmmessages:CreateControlChannel", "ssmmessages:CreateDataChannel",
          "ssmmessages:OpenControlChannel", "ssmmessages:OpenDataChannel"
        ]
      }
    ]
  })
}

resource "aws_iam_instance_profile" "instance" {
  for_each    = aws_iam_role.instance
  name_prefix = "${var.project_name}-${each.key}-"
  role        = each.value.name
}

resource "aws_iam_role_policy" "vpn_secret" {
  count = var.vpn.enabled ? 1 : 0
  name  = "read-one-vpn-secret"
  role  = aws_iam_role.instance["firewall"].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      [{ Effect = "Allow", Action = ["ssm:GetParameter"], Resource = var.vpn.psk_parameter_arn }],
      var.vpn.kms_key_arn == null ? [] : [{
        Effect    = "Allow", Action = ["kms:Decrypt"], Resource = var.vpn.kms_key_arn
        Condition = { StringEquals = { "kms:ViaService" = "ssm.us-east-1.amazonaws.com" } }
      }]
    )
  })
}

resource "aws_security_group" "firewall" {
  name_prefix = "${var.project_name}-firewall-"
  description = "NAT, optional HTTP forwarding and optional peer-restricted IKEv2"
  vpc_id      = aws_vpc.school.id
}

resource "aws_security_group" "workload" {
  for_each    = toset(concat(keys(local.windows), keys(local.ubuntu)))
  name_prefix = "${var.project_name}-${each.key}-"
  description = "Role-specific ingress; no public administrative access"
  vpc_id      = aws_vpc.school.id
}

resource "aws_vpc_security_group_egress_rule" "outbound" {
  for_each          = merge({ firewall = aws_security_group.firewall }, aws_security_group.workload)
  security_group_id = each.value.id
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
  description       = "Host outbound; firewall limits routed internet traffic to HTTP and HTTPS"
}

resource "aws_vpc_security_group_ingress_rule" "firewall_internal" {
  for_each          = toset(["80", "443"])
  security_group_id = aws_security_group.firewall.id
  cidr_ipv4         = local.internal_cidr
  ip_protocol       = "tcp"
  from_port         = tonumber(each.value)
  to_port           = tonumber(each.value)
  description       = "Internal HTTP and HTTPS egress through NAT"
}

resource "aws_vpc_security_group_ingress_rule" "firewall_metrics" {
  security_group_id = aws_security_group.firewall.id
  cidr_ipv4         = "${local.ubuntu.monitor.ip}/32"
  ip_protocol       = "tcp"
  from_port         = 9100
  to_port           = 9100
}

resource "aws_vpc_security_group_ingress_rule" "firewall_pmtu" {
  security_group_id = aws_security_group.firewall.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "icmp"
  from_port         = 3
  to_port           = 4
  description       = "Path MTU discovery"
}

resource "aws_vpc_security_group_ingress_rule" "firewall_http" {
  for_each          = toset(var.web_ingress_cidrs)
  security_group_id = aws_security_group.firewall.id
  cidr_ipv4         = each.value
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
  description       = "Optional demo website publication"
}

resource "aws_vpc_security_group_ingress_rule" "firewall_ike" {
  for_each          = var.vpn.enabled ? toset(["500", "4500"]) : toset([])
  security_group_id = aws_security_group.firewall.id
  cidr_ipv4         = "${var.vpn.peer_public_ip}/32"
  ip_protocol       = "udp"
  from_port         = tonumber(each.value)
  to_port           = tonumber(each.value)
  description       = "IKEv2 and forced ESP-in-UDP from school peer only"
}

resource "aws_vpc_security_group_ingress_rule" "firewall_vpn_return" {
  count             = var.vpn.enabled ? 1 : 0
  security_group_id = aws_security_group.firewall.id
  cidr_ipv4         = local.vpc_cidr
  ip_protocol       = "-1"
  description       = "VPN return traffic; host firewall enforces IPsec policies"
}

resource "aws_vpc_security_group_ingress_rule" "workload" {
  for_each          = local.workload_ingress
  security_group_id = aws_security_group.workload[each.value.group].id
  cidr_ipv4         = each.value.source
  ip_protocol       = each.value.protocol
  from_port         = each.value.from
  to_port           = each.value.to
}

resource "aws_network_interface" "firewall" {
  subnet_id         = aws_subnet.external.id
  private_ips       = [local.firewall_ip]
  security_groups   = [aws_security_group.firewall.id]
  source_dest_check = false
  tags              = { Name = "${var.project_name}-firewall-eni" }
}

resource "aws_eip" "firewall" {
  domain = "vpc"
  tags   = { Name = "${var.project_name}-firewall" }
}

resource "aws_instance" "firewall" {
  ami                  = nonsensitive(data.aws_ssm_parameter.ubuntu_ami.value)
  instance_type        = "t3.medium"
  iam_instance_profile = aws_iam_instance_profile.instance["firewall"].name
  key_name             = var.key_name
  primary_network_interface {
    network_interface_id = aws_network_interface.firewall.id
  }
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }
  root_block_device {
    volume_size = 30
    volume_type = "gp3"
    encrypted   = true
  }
  credit_specification { cpu_credits = "standard" }
  user_data_replace_on_change = true
  user_data = templatefile("${path.module}/firewall-init.sh", {
    firewall_ip       = local.firewall_ip
    firewall_public   = aws_eip.firewall.public_ip
    internal_cidr     = local.internal_cidr
    vpc_cidr          = local.vpc_cidr
    web_ip            = local.ubuntu.web.ip
    monitor_ip        = local.ubuntu.monitor.ip
    web_cidrs         = join(" ", var.web_ingress_cidrs)
    vpn_enabled       = var.vpn.enabled ? "true" : "false"
    peer_public_ip    = var.vpn.peer_public_ip
    remote_cidr       = var.vpn.remote_cidr
    psk_parameter_arn = var.vpn.psk_parameter_arn
  })
  tags = { Name = "${var.project_name}-firewall", Role = "NAT firewall / optional strongSwan IPsec" }
  depends_on = [
    aws_route.external_internet, aws_route_table_association.external,
    aws_iam_role_policy.ssm, aws_iam_role_policy.vpn_secret,
    aws_vpc_security_group_egress_rule.outbound
  ]
}

resource "aws_eip_association" "firewall" {
  allocation_id        = aws_eip.firewall.id
  network_interface_id = aws_network_interface.firewall.id
  depends_on           = [aws_instance.firewall, aws_internet_gateway.school]
}

resource "aws_instance" "ubuntu" {
  for_each                    = local.ubuntu
  ami                         = nonsensitive(data.aws_ssm_parameter.ubuntu_ami.value)
  instance_type               = "t3.medium"
  subnet_id                   = each.value.subnet == "external" ? aws_subnet.external.id : aws_subnet.internal.id
  private_ip                  = each.value.ip
  associate_public_ip_address = false
  vpc_security_group_ids      = [aws_security_group.workload[each.key].id]
  iam_instance_profile        = aws_iam_instance_profile.instance["workload"].name
  key_name                    = var.key_name
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }
  root_block_device {
    volume_size = 30
    volume_type = "gp3"
    encrypted   = true
  }
  credit_specification { cpu_credits = "standard" }
  user_data_replace_on_change = true
  user_data                   = "${local.linux_common}\n${local.linux_scripts[each.key]}"
  tags                        = { Name = "${var.project_name}-${each.key}", Role = each.value.role }
  depends_on = [
    aws_eip_association.firewall, aws_route.internal_internet,
    aws_route_table_association.internal, aws_iam_role_policy.ssm,
    aws_vpc_security_group_ingress_rule.firewall_internal,
    aws_vpc_security_group_egress_rule.outbound
  ]
}

# The external web VM needs a public address for direct IGW egress (updates/SSM).
# Its SG still accepts HTTP only from the firewall, so website ingress uses DNAT.
resource "aws_eip" "web" {
  domain = "vpc"
  tags   = { Name = "${var.project_name}-web-egress" }
}

resource "aws_eip_association" "web" {
  allocation_id = aws_eip.web.id
  instance_id   = aws_instance.ubuntu["web"].id
  depends_on    = [aws_internet_gateway.school]
}

resource "aws_instance" "windows" {
  for_each                    = local.windows
  ami                         = nonsensitive(data.aws_ssm_parameter.windows_ami.value)
  instance_type               = "c6i.xlarge"
  subnet_id                   = aws_subnet.internal.id
  private_ip                  = each.value.ip
  associate_public_ip_address = false
  vpc_security_group_ids      = [aws_security_group.workload[each.key].id]
  iam_instance_profile        = aws_iam_instance_profile.instance["workload"].name
  key_name                    = var.key_name
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }
  root_block_device {
    volume_size = 60
    volume_type = "gp3"
    encrypted   = true
  }
  user_data_replace_on_change = true
  user_data                   = <<-PS
    <powershell>
    $ErrorActionPreference = 'Stop'
    $featureNames = @(${join(", ", [for feature in each.value.features : "'${feature}'"])})
    $installed = Install-WindowsFeature -Name $featureNames -IncludeManagementTools
    if (-not $installed.Success) { throw 'Windows role feature installation failed' }
    $allowedSources = @(${join(", ", [for source in values(local.windows_sources) : "'${source}'"])})
    $serviceRules = '${jsonencode([for name, port in local.windows_service_ports : { name = name, protocol = upper(port.protocol), ports = port.from == port.to ? tostring(port.from) : "${port.from}-${port.to}" } if contains(port.targets, each.key)])}' | ConvertFrom-Json
    foreach ($serviceRule in $serviceRules) {
      $ruleName = 'SmallCloud-' + $serviceRule.name
      if (-not (Get-NetFirewallRule -Name $ruleName -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -Name $ruleName -DisplayName $ruleName -Group 'SmallCloudRoleServices' -Direction Inbound -Action Allow -Protocol $serviceRule.protocol -LocalPort $serviceRule.ports -RemoteAddress $allowedSources -Profile Any | Out-Null
      }
    }
    New-Item -Path 'C:\ProgramData\School' -ItemType Directory -Force | Out-Null
    @{
      Server = '${each.key}'
      IntendedRole = '${each.value.intended_role}'
      Features = $featureNames
      FeatureInstallation = 'Completed'
      RoleConfiguration = 'Pending secure post-build steps in windows-roles.ps1'
      RestartNeeded = [string]$installed.RestartNeeded
    } | ConvertTo-Json | Set-Content -LiteralPath 'C:\ProgramData\School\bootstrap-status.json'
    </powershell>
  PS
  tags                        = { Name = "${var.project_name}-${each.key}", IntendedRole = each.value.intended_role, ConfiguredRole = "Role feature bootstrap; secure domain/CA/NPS configuration follows" }
  depends_on = [
    aws_eip_association.firewall, aws_route.internal_internet,
    aws_route_table_association.internal, aws_iam_role_policy.ssm,
    aws_vpc_security_group_ingress_rule.firewall_internal,
    aws_vpc_security_group_egress_rule.outbound
  ]
}

output "network" {
  value = {
    region          = "us-east-1", vpc_id = aws_vpc.school.id,
    vpc_cidr        = local.vpc_cidr, external_subnet = local.external_cidr,
    internal_subnet = local.internal_cidr, firewall_public_ip = aws_eip.firewall.public_ip
  }
}

output "servers" {
  value = merge(
    { firewall = { id = aws_instance.firewall.id, private_ip = local.firewall_ip, role = "NAT / optional IPsec" } },
    { for name, node in aws_instance.ubuntu : name => { id = node.id, private_ip = node.private_ip, role = local.ubuntu[name].role } },
    { for name, node in aws_instance.windows : name => { id = node.id, private_ip = node.private_ip, role = local.windows[name].intended_role } }
  )
}

output "demo_url" {
  value = length(var.web_ingress_cidrs) > 0 ? "http://${aws_eip.firewall.public_ip}/" : "HTTP publication disabled (web_ingress_cidrs is empty)"
}

output "vpn_status" {
  value = var.vpn.enabled ? "Configured for school peer; runtime PSK retrieval and both-end setup required. Not verified live." : "Disabled; no live school peer or VPN secret supplied."
}
