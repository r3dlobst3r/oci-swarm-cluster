# Copyright (c) 2019, 2020 Oracle and/or its affiliates. All rights reserved.
# Licensed under the Universal Permissive License v 1.0 as shown at http://oss.oracle.com/licenses/upl.
# 

# Gets a list of Availability Domains
data "oci_identity_availability_domains" "ADs" {
  compartment_id = var.tenancy_ocid
}

# Gets ObjectStorage namespace
data "oci_objectstorage_namespace" "user_namespace" {
  compartment_id = var.compartment_ocid
}

# Randoms
resource "random_string" "deploy_id" {
  length  = 4
  special = false
}

### Passwords using random_string instead of random_password to be compatible with ORM (Need to update random provider)
resource "random_string" "autonomous_database_wallet_password" {
  length           = 16
  special          = true
  min_upper        = 3
  min_lower        = 3
  min_numeric      = 3
  min_special      = 3
  override_special = "{}#^*<>[]%~"
}

resource "random_string" "autonomous_database_admin_password" {
  length           = 16
  special          = true
  min_upper        = 3
  min_lower        = 3
  min_numeric      = 3
  min_special      = 3
  override_special = "{}#^*<>[]%~"
}

resource "random_string" "catalogue_db_password" {
  length           = 16
  special          = true
  min_upper        = 3
  min_lower        = 3
  min_numeric      = 3
  min_special      = 3
  override_special = "{}#^*<>[]%~"
}

resource "oci_database_autonomous_database_wallet" "autonomous_database_wallet" {
  autonomous_database_id = oci_database_autonomous_database.oci_swarm_autonomous_database.id
  password               = random_string.autonomous_database_wallet_password.result
  base64_encode_content  = "true"
}

# Check for resource limits
## Check available compute shape
data "oci_limits_services" "compute_services" {
  compartment_id = var.tenancy_ocid

  filter {
    name   = "name"
    values = ["compute"]
  }
}
data "oci_limits_resource_availability" "compute_resource_availability" {
  compartment_id      = var.tenancy_ocid
  limit_name          = "standard-a1-core-count"
  service_name        = data.oci_limits_services.compute_services.services.0.name
  availability_domain = data.oci_identity_availability_domains.ADs.availability_domains[count.index].name

  count = length(data.oci_identity_availability_domains.ADs.availability_domains)
}
resource "random_shuffle" "compute_ad" {
  input        = local.compute_available_limit_ad_list
  result_count = length(local.compute_available_limit_ad_list)
}
locals {
  compute_available_limit_ad_list = [for limit in data.oci_limits_resource_availability.compute_resource_availability : limit.availability_domain if(limit.available - var.num_nodes) >= 0]
  compute_available_limit_error = length(local.compute_available_limit_ad_list) == 0 ? (
  file("ERROR: No limits available for the chosen compute shape and number of nodes")) : 0
}

# Gets a list of supported images based on the shape, operating_system and operating_system_version provided
data "oci_core_images" "compute_images" {
  compartment_id           = var.compartment_ocid
  operating_system         = var.image_operating_system
  operating_system_version = var.image_operating_system_version
  shape                    = var.instance_shape
  sort_by                  = "TIMECREATED"
  sort_order               = "DESC"
}

data "oci_identity_tenancy" "tenant_details" {
  tenancy_id = var.tenancy_ocid

  provider = oci.current_region
}

data "oci_identity_regions" "home_region" {
  filter {
    name   = "key"
    values = [data.oci_identity_tenancy.tenant_details.home_region_key]
  }

  provider = oci.current_region
}

# Cloud Init
data "template_cloudinit_config" "nodes" {
  gzip          = true
  base64_encode = true

  part {
    filename     = "cloud-config.yaml"
    content_type = "text/cloud-config"
    content      = data.template_file.cloud_init.rendered
  }
}
data "template_file" "cloud_init" {
  template = file("${path.module}/scripts/cloud-config.template.yaml")

  vars = {
    setup_preflight_sh_content     = base64gzip(data.template_file.setup_preflight.rendered)
    setup_template_sh_content      = base64gzip(data.template_file.setup_template.rendered)
    deploy_template_content        = base64gzip(data.template_file.deploy_template.rendered)
    catalogue_sql_template_content = base64gzip(data.template_file.catalogue_sql_template.rendered)
    docker_compose_yml_content     = base64gzip(data.local_file.docker_compose_yml.content)
    catalogue_password             = random_string.catalogue_db_password.result
    catalogue_port                 = local.catalogue_port
    mock_mode                      = var.services_in_mock_mode
    deploy_id                      = random_string.deploy_id.result
    region_id                      = var.region
    s3_secret                      = oci_identity_customer_secret_key.oci_user.key
    s3_key_id                      = oci_identity_customer_secret_key.oci_user.id
    object_namespace               = oci_objectstorage_bucket.registry.namespace
    db_name                        = oci_database_autonomous_database.oci_swarm_autonomous_database.db_name
    assets_url                     = var.object_storage_oci_swarm_media_visibility == "Private" ? "" : "https://objectstorage.${var.region}.oraclecloud.com/n/${oci_objectstorage_bucket.oci_swarm_media.namespace}/b/${oci_objectstorage_bucket.oci_swarm_media.name}/o/"
  }
}
data "template_file" "setup_preflight" {
  template = file("${path.module}/scripts/setup.preflight.sh")
}
data "template_file" "setup_template" {
  template = file("${path.module}/scripts/setup.template.sh")

  vars = {
    oracle_client_version = var.oracle_client_version
    public_key_openssh = tls_private_key.compute_ssh_key.public_key_openssh
    private_key_pem  = tls_private_key.compute_ssh_key.private_key_pem
  }
}
data "template_file" "deploy_template" {
  template = file("${path.module}/scripts/deploy.template.sh")

  vars = {
    oracle_client_version   = var.oracle_client_version
    db_name                 = oci_database_autonomous_database.oci_swarm_autonomous_database.db_name
    atp_pw                  = random_string.autonomous_database_admin_password.result
    oci_swarm_media_visibility = var.object_storage_oci_swarm_media_visibility
    wallet_par              = "https://objectstorage.${var.region}.oraclecloud.com${oci_objectstorage_preauthrequest.oci_swarm_wallet_preauth.access_uri}"
  }
}
data "template_file" "catalogue_sql_template" {
  template = file("${path.module}/scripts/catalogue.template.sql")

  vars = {
    catalogue_password = random_string.catalogue_db_password.result
  }
}
data "local_file" "docker_compose_yml" {
  filename = "${path.module}/scripts/docker-compose.yml"
}
locals {
  catalogue_port = 3005
}


# Available Services
data "oci_core_services" "all_services" {
  filter {
    name   = "name"
    values = ["All .* Services In Oracle Services Network"]
    regex  = true
  }
}

locals {
  common_tags = {
    Reference = "Created by OCI QuickStart for OciSwarm Basic demo"
  }
}
