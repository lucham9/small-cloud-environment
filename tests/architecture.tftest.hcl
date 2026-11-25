# Plan-only, mocked AWS: these tests never contact AWS or create resources.
mock_provider "aws" {
  override_during = plan
  mock_data "aws_ssm_parameter" {
    defaults = { value = "ami-0123456789abcdef0" }
  }
  mock_resource "aws_eip" {
    defaults = { public_ip = "198.51.100.25" }
  }
  mock_resource "aws_vpc" {
    defaults = { id = "vpc-0123456789abcdef0" }
  }
  mock_resource "aws_security_group" {
    defaults = { id = "sg-0123456789abcdef0" }
  }
  mock_resource "aws_network_interface" {
    defaults = { id = "eni-0123456789abcdef0" }
  }
  mock_resource "aws_iam_role" {
    defaults = { id = "mock-role-id", name = "mock-role-name" }
  }
  override_resource {
    target = aws_subnet.internal
    values = { id = "subnet-0123456789abcdef0" }
  }
  override_resource {
    target = aws_subnet.external
    values = { id = "subnet-1123456789abcdef0" }
  }
  override_resource {
    target = aws_instance.ubuntu["web"]
    values = { id = "i-0123456789abcdef0" }
  }
}

run "default_architecture" {
  command = plan
  assert {
    condition     = length(aws_instance.windows) == 4 && length(aws_instance.ubuntu) == 3 && aws_instance.firewall.instance_type == "t3.medium"
    error_message = "Require four Windows servers and four Ubuntu servers including the firewall."
  }
  assert {
    condition     = alltrue([for node in aws_instance.windows : node.instance_type == "c6i.xlarge"])
    error_message = "Every Windows server must be c6i.xlarge."
  }
  assert {
    condition     = alltrue([for node in aws_instance.ubuntu : node.instance_type == "t3.medium"])
    error_message = "Every Ubuntu workload must be t3.medium."
  }
  assert {
    condition     = alltrue([for node in aws_instance.windows : one(node.root_block_device).volume_size == 60 && one(node.root_block_device).volume_type == "gp3"])
    error_message = "Every Windows server must have a 60-GiB gp3 root disk."
  }
  assert {
    condition     = alltrue([for node in concat(values(aws_instance.ubuntu), [aws_instance.firewall]) : one(node.root_block_device).volume_size == 30 && one(node.root_block_device).volume_type == "gp3"])
    error_message = "Every Ubuntu server must have a 30-GiB gp3 root disk."
  }
  assert {
    condition     = data.aws_ssm_parameter.windows_ami.name == "/aws/service/ami-windows-latest/Windows_Server-2022-English-Full-Base" && data.aws_ssm_parameter.ubuntu_ami.name == "/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id"
    error_message = "AMI lookups must request Windows Server 2022 and Ubuntu 24.04 amd64."
  }
  assert {
    condition     = aws_route.external_internet.destination_cidr_block == "0.0.0.0/0" && aws_route.internal_internet.destination_cidr_block == "0.0.0.0/0"
    error_message = "Both subnets need their explicitly configured default routes."
  }
  assert {
    condition     = aws_vpc.school.cidr_block == "10.20.0.0/16" && aws_subnet.external.cidr_block == "10.20.1.0/24" && aws_subnet.internal.cidr_block == "10.20.2.0/24"
    error_message = "Network design ranges must remain exact."
  }
  assert {
    condition     = aws_route.internal_internet.network_interface_id == aws_network_interface.firewall.id && !aws_network_interface.firewall.source_dest_check
    error_message = "Internal egress must route to an ENI that permits forwarding."
  }
  assert {
    condition     = alltrue([for node in aws_instance.windows : !node.associate_public_ip_address && node.subnet_id == aws_subnet.internal.id])
    error_message = "All four Windows servers must reside in the internal subnet without public IPs."
  }
  assert {
    condition     = aws_network_interface.firewall.subnet_id == aws_subnet.external.id && aws_instance.ubuntu["web"].subnet_id == aws_subnet.external.id && aws_instance.ubuntu["app"].subnet_id == aws_subnet.internal.id && aws_instance.ubuntu["monitor"].subnet_id == aws_subnet.internal.id
    error_message = "Linux must be split exactly two external (firewall/web) and two internal (app/monitor)."
  }
  assert {
    condition     = toset(keys(aws_instance.windows)) == toset(["dc1", "dc2", "msca", "nps"]) && local.windows.msca.features == ["ADCS-Cert-Authority"] && local.windows.nps.features == ["NPAS"]
    error_message = "Windows roles must be two domain controllers, Microsoft CA and NPS."
  }
  assert {
    condition     = aws_eip_association.web.instance_id == aws_instance.ubuntu["web"].id
    error_message = "The external web VM needs a public address for IGW egress."
  }
  assert {
    condition     = length(aws_route.school_vpn) == 0 && length(aws_iam_role_policy.vpn_secret) == 0 && length(aws_vpc_security_group_ingress_rule.firewall_http) == 0
    error_message = "The default must neither publish HTTP nor enable a VPN or secret access."
  }
  assert {
    condition     = alltrue([for node in concat(values(aws_instance.windows), values(aws_instance.ubuntu), [aws_instance.firewall]) : node.metadata_options[0].http_tokens == "required" && one(node.root_block_device).encrypted])
    error_message = "Require IMDSv2 and encrypted root disks on all eight servers."
  }
}

run "vpn_and_http_configuration" {
  command = plan
  variables {
    web_ingress_cidrs = ["203.0.113.10/32"]
    vpn = {
      enabled = true
      # Synthetic public address for MOCKED plan only; no traffic is sent here.
      peer_public_ip    = "8.8.8.8"
      remote_cidr       = "192.168.50.0/24"
      psk_parameter_arn = "arn:aws:ssm:us-east-1:123456789012:parameter/school/vpn/psk"
      kms_key_arn       = "arn:aws:kms:us-east-1:123456789012:key/00000000-0000-0000-0000-000000000000"
    }
  }
  assert {
    condition     = aws_route.school_vpn[0].destination_cidr_block == "192.168.50.0/24" && aws_route.school_vpn[0].network_interface_id == aws_network_interface.firewall.id
    error_message = "VPN return traffic must route through the firewall."
  }
  assert {
    condition     = aws_route.external_school_vpn[0].destination_cidr_block == "192.168.50.0/24" && aws_route.external_school_vpn[0].network_interface_id == aws_network_interface.firewall.id
    error_message = "External web return traffic must use the firewall for the remote site."
  }
  assert {
    condition     = aws_vpc_security_group_ingress_rule.workload["nps_radius_udp_school"].from_port == 1812 && aws_vpc_security_group_ingress_rule.workload["nps_radius_udp_school"].to_port == 1813 && aws_vpc_security_group_ingress_rule.workload["msca_rpc_tcp_school"].cidr_ipv4 == "192.168.50.0/24"
    error_message = "RADIUS and CA service rules must be limited to the configured remote network."
  }
  assert {
    condition     = alltrue([for rule in aws_vpc_security_group_ingress_rule.firewall_ike : rule.cidr_ipv4 == "8.8.8.8/32"]) && length(aws_vpc_security_group_ingress_rule.firewall_ike) == 2
    error_message = "IKE and NAT-T must be restricted to the exact school peer."
  }
  assert {
    condition     = jsondecode(aws_iam_role_policy.vpn_secret[0].policy).Statement[0].Resource == "arn:aws:ssm:us-east-1:123456789012:parameter/school/vpn/psk" && aws_iam_role_policy.vpn_secret[0].role == aws_iam_role.instance["firewall"].id
    error_message = "Only the firewall role may read the named VPN secret."
  }
  assert {
    condition     = !strcontains(aws_iam_role_policy.ssm["workload"].policy, "ssm:GetParameter")
    error_message = "Workload management permissions must not grant Parameter Store reads."
  }
  assert {
    condition     = length(aws_vpc_security_group_ingress_rule.firewall_http) == 1 && aws_vpc_security_group_ingress_rule.workload["web_http"].cidr_ipv4 == "10.20.1.10/32"
    error_message = "Published HTTP must traverse firewall DNAT/SNAT."
  }
}

run "reject_overlapping_school_network" {
  command = plan
  variables {
    vpn = {
      enabled           = false
      peer_public_ip    = "192.0.2.10"
      remote_cidr       = "10.20.5.0/24"
      psk_parameter_arn = ""
    }
  }
  expect_failures = [var.vpn]
}

run "reject_enabled_placeholder_peer" {
  command = plan
  variables {
    vpn = {
      enabled           = true
      peer_public_ip    = "192.0.2.10"
      remote_cidr       = "192.168.50.0/24"
      psk_parameter_arn = "arn:aws:ssm:us-east-1:123456789012:parameter/school/vpn/psk"
    }
  }
  expect_failures = [var.vpn]
}

run "reject_invalid_web_cidr" {
  command = plan
  variables {
    web_ingress_cidrs = ["not-a-network"]
  }
  expect_failures = [var.web_ingress_cidrs]
}

run "reject_wrong_region_az" {
  command = plan
  variables {
    availability_zone = "us-west-2a"
  }
  expect_failures = [var.availability_zone]
}
