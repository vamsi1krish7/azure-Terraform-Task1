terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~>3.0"
    }
  }
}

provider "azurerm" {
  features {}
}

# -------------------------
# RESOURCE GROUP
# -------------------------
resource "azurerm_resource_group" "rg" {
  name     = "task5-rg"
  location = "East US"
}

# -------------------------
# VIRTUAL NETWORK
# -------------------------
resource "azurerm_virtual_network" "vnet" {
  name                = "task5-vnet"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  address_space       = ["10.0.0.0/16"]
}

# -------------------------
# SUBNET
# -------------------------
resource "azurerm_subnet" "subnet" {
  name                 = "task5-subnet"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.0.1.0/24"]
}

# -------------------------
# PUBLIC IP
# -------------------------
resource "azurerm_public_ip" "publicip" {
  name                = "task5-public-ip"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  allocation_method   = "Static"
}

# -------------------------
# NETWORK SECURITY GROUP
# -------------------------
resource "azurerm_network_security_group" "nsg" {
  name                = "task5-nsg"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  security_rule {
    name                       = "SSH"
    priority                   = 1001
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
}

# -------------------------
# NSG ASSOCIATION
# -------------------------
resource "azurerm_subnet_network_security_group_association" "assoc" {
  subnet_id                 = azurerm_subnet.subnet.id
  network_security_group_id = azurerm_network_security_group.nsg.id
}

# -------------------------
# NETWORK INTERFACE
# -------------------------
resource "azurerm_network_interface" "nic" {
  name                = "task5-nic"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.subnet.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.publicip.id
  }
}

# -------------------------
# LINUX VM
# -------------------------
resource "azurerm_linux_virtual_machine" "vm" {
  name                = "task5-vm"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  size                = "Standard_B1s"

  admin_username = "azureuser"
  admin_password = "Password1234!"

  disable_password_authentication = false

  network_interface_ids = [
    azurerm_network_interface.nic.id
  ]

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts"
    version   = "latest"
  }
}

# -------------------------
# LOG ANALYTICS WORKSPACE
# -------------------------
resource "azurerm_log_analytics_workspace" "law" {
  name                = "task5-law"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  sku                 = "PerGB2018"
  retention_in_days   = 30
}

# -------------------------
# AZURE MONITOR AGENT
# -------------------------
resource "azurerm_virtual_machine_extension" "ama" {
  name                       = "AzureMonitorLinuxAgent"
  virtual_machine_id         = azurerm_linux_virtual_machine.vm.id
  publisher                  = "Microsoft.Azure.Monitor"
  type                       = "AzureMonitorLinuxAgent"
  type_handler_version       = "1.0"
  auto_upgrade_minor_version = true
}

# -------------------------
# DATA COLLECTION RULE
# -------------------------
resource "azurerm_monitor_data_collection_rule" "dcr" {
  name                = "task5-dcr"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  destinations {
    log_analytics {
      workspace_resource_id = azurerm_log_analytics_workspace.law.id
      name                  = "logAnalyticsDest"
    }
  }

  data_flow {
    streams      = ["Microsoft-Perf"]
    destinations = ["logAnalyticsDest"]
  }

  data_sources {
    performance_counter {
      streams                       = ["Microsoft-Perf"]
      sampling_frequency_in_seconds = 60

      counter_specifiers = [
        "\\Processor(_Total)\\% Processor Time",
        "\\LogicalDisk(_Total)\\% Free Space"
      ]

      name = "perfCounter"
    }
  }
}

# -------------------------
# DCR ASSOCIATION
# -------------------------
resource "azurerm_monitor_data_collection_rule_association" "assoc_dcr" {
  name                    = "task5-dcr-association"
  target_resource_id      = azurerm_linux_virtual_machine.vm.id
  data_collection_rule_id = azurerm_monitor_data_collection_rule.dcr.id
}

# -------------------------
# ACTION GROUP FOR EMAIL ALERTS
# -------------------------
resource "azurerm_monitor_action_group" "email_alert" {
  name                = "task5-action-group"
  resource_group_name = azurerm_resource_group.rg.name
  short_name          = "emailalert"

  email_receiver {
    name                    = "admin-email"
    email_address           = "er.vamsi1997@gmail.com"
    use_common_alert_schema = true
  }
}

# -------------------------
# CPU ALERT (>90%)
# -------------------------
resource "azurerm_monitor_metric_alert" "cpu_alert" {
  name                = "HighCPUAlert"
  resource_group_name = azurerm_resource_group.rg.name
  scopes              = [azurerm_linux_virtual_machine.vm.id]

  description = "Critical alert when CPU exceeds 90%"
  severity    = 0
  frequency   = "PT1M"
  window_size = "PT5M"

  criteria {
    metric_namespace = "Microsoft.Compute/virtualMachines"
    metric_name      = "Percentage CPU"
    aggregation      = "Average"
    operator         = "GreaterThan"
    threshold        = 90
  }

  action {
    action_group_id = azurerm_monitor_action_group.email_alert.id
  }
}

# -------------------------
# DISK ALERT (>75%)
# -------------------------
resource "azurerm_monitor_scheduled_query_rules_alert_v2" "disk_alert" {
  name                = "HighDiskUsageAlert"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  evaluation_frequency = "PT5M"
  window_duration      = "PT5M"
  severity             = 2

  scopes = [
    azurerm_log_analytics_workspace.law.id
  ]

  criteria {
    query = <<-QUERY
    Perf
    | where ObjectName == "LogicalDisk"
    | where CounterName == "% Free Space"
    | summarize AvgFreeSpace = avg(CounterValue) by bin(TimeGenerated, 5m)
    | extend DiskUsed = 100 - AvgFreeSpace
    | where DiskUsed > 75
    QUERY

    time_aggregation_method = "Average"
    threshold               = 75
    operator                = "GreaterThan"
  }

  action {
    action_groups = [
      azurerm_monitor_action_group.email_alert.id
    ]
  }
}

# -------------------------
# OUTPUTS
# -------------------------
output "vm_public_ip" {
  value = azurerm_public_ip.publicip.ip_address
}