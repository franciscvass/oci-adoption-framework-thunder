// Copyright (c) 2021, Oracle and/or its affiliates. All rights reserved.
// Licensed under the Universal Permissive License v 1.0 as shown at https://oss.oracle.com/licenses/upl.
locals {
  vcns              = [for vcn in var.vcn_params : split("/", vcn.vcn_cidr)[1] < 16 || split("/", vcn.vcn_cidr)[1] > 30 ? file(format("\n\nERROR: The VCN Cidr %s for VCN %s is not between /16 and /30", vcn.vcn_cidr, vcn.display_name)) : null]
  subnets           = [for subnet in var.subnet_params : split("/", subnet.cidr_block)[1] < 16 || split("/", subnet.cidr_block)[1] > 30 ? file(format("\n\nERROR: The Subnet Cidr %s for Subnet %s is not between /16 and /30", subnet.cidr_block, subnet.display_name)) : null]
  protocols         = ["all", "1", "6", "17", "58"]
  sec_lists_ingress = [for sec_lists in var.sl_params : [for ingress in sec_lists.ingress_rules : contains(local.protocols, ingress.protocol) ? null : file(format("\n\nERROR: The protocol %s for the security list %s for ingress rules is not allowed. Supported options are all (all), 1 (ICMP), 6 (TCP), 17 (UDP), 58 (ICMPv6)", ingress.protocol, sec_lists.display_name))]]
  sec_lists_egress  = [for sec_lists in var.sl_params : [for egress in sec_lists.egress_rules : contains(local.protocols, egress.protocol) ? null : file(format("\n\nERROR: The protocol %s for the security list %s for egress rules is not allowed. Supported options are all (all), 1 (ICMP), 6 (TCP), 17 (UDP), 58 (ICMPv6)", egress.protocol, sec_lists.display_name))]]
}

terraform {
  required_providers {
    oci = {
      configuration_aliases = []
    }
  }
}

resource "oci_core_virtual_network" "this" {
  for_each       = var.vcn_params
  cidr_block     = each.value.vcn_cidr
  compartment_id = var.compartment_ids[each.value.compartment_name]
  display_name   = each.value.display_name
  dns_label      = each.value.dns_label
}

resource "oci_core_internet_gateway" "this" {
  for_each       = var.igw_params
  compartment_id = oci_core_virtual_network.this[each.value.vcn_name].compartment_id
  vcn_id         = oci_core_virtual_network.this[each.value.vcn_name].id
  display_name   = each.value.display_name
}

resource "oci_core_nat_gateway" "this" {
  for_each       = var.ngw_params
  compartment_id = oci_core_virtual_network.this[each.value.vcn_name].compartment_id
  vcn_id         = oci_core_virtual_network.this[each.value.vcn_name].id
  display_name   = each.value.display_name
}

resource "oci_core_service_gateway" "this" {
  for_each       = var.sgw_params
  compartment_id = oci_core_virtual_network.this[each.value.vcn_name].compartment_id

  services {
    service_id = data.oci_core_services.this.services.0.id
  }

  vcn_id       = oci_core_virtual_network.this[each.value.vcn_name].id
  display_name = each.value.display_name
  # route_table_id = oci_core_route_table.test_route_table.id
}

data "oci_core_services" "this" {
}

resource "oci_core_local_peering_gateway" "requestor_lpgs" {
  for_each = var.lpg_params

  display_name   = each.value.display_name
  compartment_id = oci_core_virtual_network.this[each.value.acceptor].compartment_id
  vcn_id         = oci_core_virtual_network.this[each.value.requestor].id
  peer_id        = oci_core_local_peering_gateway.acceptor_lpgs[each.value.display_name].id
}

resource "oci_core_local_peering_gateway" "acceptor_lpgs" {
  for_each = var.lpg_params

  display_name   = each.value.display_name
  compartment_id = oci_core_virtual_network.this[each.value.acceptor].compartment_id
  vcn_id         = oci_core_virtual_network.this[each.value.acceptor].id
}

resource "oci_core_route_table" "this" {
  for_each       = var.rt_params
  compartment_id = oci_core_virtual_network.this[each.value.vcn_name].compartment_id
  vcn_id         = oci_core_virtual_network.this[each.value.vcn_name].id
  display_name   = each.value.display_name

  dynamic "route_rules" {
    iterator = rr
    for_each = each.value.route_rules
    content {
      destination       = rr.value.destination
      destination_type  = rr.value.use_sgw ? "SERVICE_CIDR_BLOCK" : null
      network_entity_id = rr.value.use_igw ? oci_core_internet_gateway.this[lookup(rr.value, "igw_name", null)].id : rr.value.use_sgw ? oci_core_service_gateway.this[lookup(rr.value, "sgw_name", null)].id : oci_core_nat_gateway.this[lookup(rr.value, "ngw_name", null)].id
    }
  }


  dynamic "route_rules" {
    iterator = lpg_rr

    for_each = [for lpg in var.lpg_params :
      {
        "cidr" : var.vcn_params[lpg.requestor].vcn_cidr,
        "lpg_id" : oci_core_local_peering_gateway.acceptor_lpgs[lpg.display_name].id
      }
      if lpg.acceptor == each.value.vcn_name
    ]

    content {
      destination       = lpg_rr.value.cidr
      network_entity_id = lpg_rr.value.lpg_id
    }
  }

  dynamic "route_rules" {
    iterator = lpg_rr

    for_each = [for lpg in var.lpg_params :
      {
        "cidr" : var.vcn_params[lpg.acceptor].vcn_cidr,
        "lpg_id" : oci_core_local_peering_gateway.requestor_lpgs[lpg.display_name].id
      }
      if lpg.requestor == each.value.vcn_name
    ]

    content {
      destination       = lpg_rr.value.cidr
      network_entity_id = lpg_rr.value.lpg_id
    }
  }

  dynamic "route_rules" {
    iterator = drg_rr

    for_each = flatten([for drg in var.drg_attachment_params : [for cidr in drg.cidr_rt :
      {
        "cidr" : cidr,
        "drg_id" : oci_core_drg.this[drg.drg_name].id
      }
      if contains(drg.rt_names, each.value.display_name)
    ]])

    content {
      destination       = drg_rr.value.cidr
      network_entity_id = drg_rr.value.drg_id
    }
  }

  # lifecycle {
  #   ignore_changes = all
  # }
}

resource "oci_core_security_list" "this" {
  for_each       = var.sl_params
  compartment_id = oci_core_virtual_network.this[each.value.vcn_name].compartment_id
  vcn_id         = oci_core_virtual_network.this[each.value.vcn_name].id
  display_name   = each.value.display_name

  dynamic "egress_security_rules" {
    iterator = egress_rules
    for_each = each.value.egress_rules
    content {
      stateless   = egress_rules.value.stateless
      protocol    = egress_rules.value.protocol
      destination = egress_rules.value.destination
    }
  }


  dynamic "ingress_security_rules" {
    iterator = ingress_rules
    for_each = each.value.ingress_rules
    content {
      stateless   = ingress_rules.value.stateless
      protocol    = ingress_rules.value.protocol
      source      = ingress_rules.value.source
      source_type = ingress_rules.value.source_type

      dynamic "tcp_options" {
        iterator = tcp_options
        for_each = (lookup(ingress_rules.value, "tcp_options", null) != null) ? ingress_rules.value.tcp_options : []
        content {
          max = tcp_options.value.max
          min = tcp_options.value.min
        }
      }
      dynamic "udp_options" {
        iterator = udp_options
        for_each = (lookup(ingress_rules.value, "udp_options", null) != null) ? ingress_rules.value.udp_options : []
        content {
          max = udp_options.value.max
          min = udp_options.value.min
        }
      }
    }
  }
}


resource "oci_core_network_security_group" "this" {
  for_each       = var.nsg_params
  compartment_id = oci_core_virtual_network.this[each.value.vcn_name].compartment_id
  vcn_id         = oci_core_virtual_network.this[each.value.vcn_name].id
  display_name   = each.value.display_name
}

resource "oci_core_network_security_group_security_rule" "this" {
  for_each                  = var.nsg_rules_params
  network_security_group_id = oci_core_network_security_group.this[each.value.nsg_name].id
  protocol                  = each.value.protocol
  stateless                 = each.value.stateless
  direction                 = each.value.direction

  source      = each.value.direction == "INGRESS" ? each.value.source_type == "NETWORK_SECURITY_GROUP" ? oci_core_network_security_group.this[each.value.source].id : each.value.source : null
  source_type = each.value.direction == "INGRESS" ? each.value.source_type : null

  destination      = each.value.direction == "EGRESS" ? each.value.destination_type == "NETWORK_SECURITY_GROUP" ? oci_core_network_security_group.this[each.value.destination].id : each.value.destination : null
  destination_type = each.value.direction == "EGRESS" ? each.value.destination_type : null


  dynamic "tcp_options" {
    iterator = tcp_options
    for_each = each.value.tcp_options != null ? each.value.tcp_options : []
    content {
      dynamic "destination_port_range" {
        iterator = destination_ports
        for_each = lookup(tcp_options.value, "destination_ports", null) != null ? tcp_options.value.destination_ports : []
        content {
          min = destination_ports.value.min
          max = destination_ports.value.max
        }
      }
      dynamic "source_port_range" {
        iterator = source_ports
        for_each = lookup(tcp_options.value, "source_ports", null) != null ? tcp_options.value.source_ports : []
        content {
          min = source_ports.value.min
          max = source_ports.value.max
        }
      }
    }
  }

  dynamic "udp_options" {
    iterator = udp_options
    for_each = each.value.udp_options != null ? each.value.udp_options : []
    content {
      dynamic "destination_port_range" {
        iterator = destination_ports
        for_each = lookup(udp_options.value, "destination_ports", null) != null ? udp_options.value.destination_ports : []
        content {
          min = destination_ports.value.min
          max = destination_ports.value.max
        }
      }

      dynamic "source_port_range" {
        iterator = source_ports
        for_each = lookup(udp_options.value, "source_ports", null) != null ? udp_options.value.source_ports : []
        content {
          min = source_ports.value.min
          max = source_ports.value.max
        }
      }
    }
  }
}


resource "oci_core_subnet" "this" {
  for_each                   = var.subnet_params
  cidr_block                 = each.value.cidr_block
  display_name               = each.value.display_name
  dns_label                  = each.value.dns_label
  prohibit_public_ip_on_vnic = each.value.is_subnet_private
  compartment_id             = oci_core_virtual_network.this[each.value.vcn_name].compartment_id
  vcn_id                     = oci_core_virtual_network.this[each.value.vcn_name].id
  route_table_id             = oci_core_route_table.this[each.value.rt_name].id
  security_list_ids          = [oci_core_security_list.sl[each.value.sl_name].id]
}


resource "oci_core_drg" "this" {
  for_each       = var.drg_params
  compartment_id = oci_core_virtual_network.this[each.value.vcn_name].compartment_id
  display_name   = each.value.name
}


resource "oci_core_drg_attachment" "this" {
  for_each = var.drg_attachment_params
  drg_id   = oci_core_drg.this[each.value.drg_name].id
  vcn_id   = oci_core_virtual_network.this[each.value.vcn_name].id
}


resource "oci_core_vlan" "this" {
  for_each       = var.vlan_params
  cidr_block     = each.value.vlan_cidr_block
  compartment_id = var.compartment_id
  vcn_id         = oci_core_virtual_network.this[each.value.vcn_name].id

  display_name   = each.value.vlan_display_name
  nsg_ids        = [for nsg_name in each.value.vlan_nsg_names: oci_core_network_security_group.nsg[nsg_name].id]
  route_table_id = oci_core_route_table.this[each.value.rt_name].id

  vlan_tag       = each.value.vlan_tag
}

resource "oci_core_private_ip" "this" {
  for_each       = var.private_ip_params
    
  display_name   = each.value.privIp_display_name
  ip_address     = each.value.ip_address
  vlan_id        = oci_core_vlan.this[each.value.vlan_name].id
}


resource "oci_core_public_ip" "this" {
  for_each       = var.public_ip_params
  compartment_id = var.compartment_id
  lifetime       = each.value.public_ip_lifetime

  display_name   = each.value.public_ip_display_name
  private_ip_id  = oci_core_private_ip.this[each.value.private_ip_name].id
}