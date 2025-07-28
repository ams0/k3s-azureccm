resource "azurerm_resource_group" "k3s" {
  name     = var.resource_group_name
  location = var.resource_group_location
}

resource "azurerm_user_assigned_identity" "k3sid" {
  location            = azurerm_resource_group.k3s.location
  name                = "${var.resource_group_name}id"
  resource_group_name = azurerm_resource_group.k3s.name
}

resource "azurerm_role_assignment" "k3sid" {
  scope                = azurerm_resource_group.k3s.id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_user_assigned_identity.k3sid.principal_id
}

resource "azurerm_role_assignment" "k3sid2" {
  scope                = azurerm_resource_group.k3s.id
  role_definition_name = "Contributor"
  principal_id         = azurerm_user_assigned_identity.k3sid.principal_id
}

resource "azurerm_virtual_network" "k3s" {
  name                = "k3s-vnet"
  address_space       = ["10.224.60.0/23"]
  location            = azurerm_resource_group.k3s.location
  resource_group_name = azurerm_resource_group.k3s.name
}

resource "azurerm_subnet" "k3s" {
  name                 = "k3s-subnet"
  resource_group_name  = azurerm_resource_group.k3s.name
  virtual_network_name = azurerm_virtual_network.k3s.name
  address_prefixes     = ["10.224.60.0/24"]
}
resource "azurerm_network_security_group" "k3s" {
  name                = "k3s-nsg"
  location            = azurerm_resource_group.k3s.location
  resource_group_name = azurerm_resource_group.k3s.name
}

resource "azurerm_subnet_network_security_group_association" "k3s" {
  subnet_id                 = azurerm_subnet.k3s.id
  network_security_group_id = azurerm_network_security_group.k3s.id
}

resource "azurerm_network_security_rule" "ssh" {
  name                        = "Allow-SSH"
  priority                    = 100
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_address_prefix       = "AzureLoadbalancer"
  source_port_range           = "*"
  destination_port_range      = 22
  destination_address_prefix  = "*"
  resource_group_name         = azurerm_resource_group.k3s.name
  network_security_group_name = azurerm_network_security_group.k3s.name
}

resource "azurerm_network_security_rule" "api" {
  name                        = "Allow-SSH"
  priority                    = 101
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_address_prefix       = "AzureLoadbalancer"
  source_port_range           = "*"
  destination_port_range      = 6443
  destination_address_prefix  = "*"
  resource_group_name         = azurerm_resource_group.k3s.name
  network_security_group_name = azurerm_network_security_group.k3s.name
}

resource "azurerm_route_table" "k3s" {
  name                = "k3s-route-table"
  location            = azurerm_resource_group.k3s.location
  resource_group_name = azurerm_resource_group.k3s.name
}

resource "azurerm_subnet_route_table_association" "k3s" {
  subnet_id      = azurerm_subnet.k3s.id
  route_table_id = azurerm_route_table.k3s.id
}

resource "azurerm_public_ip" "k3s" {
  name                = "k3s-public-ip"
  location            = azurerm_resource_group.k3s.location
  resource_group_name = azurerm_resource_group.k3s.name
  allocation_method   = "Static"
}

resource "azurerm_load_balancer" "k3s" {
  name                = "k3s-lb"
  location            = azurerm_resource_group.k3s.location
  resource_group_name = azurerm_resource_group.k3s.name

  frontend_ip_configuration {
    name                 = "frontend"
    public_ip_address_id = azurerm_public_ip.k3s.id
  }

  
}
resource "azurerm_network_interface" "k3s" {
  name                = "k3s-nic"
  location            = azurerm_resource_group.k3s.location
  resource_group_name = azurerm_resource_group.k3s.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.k3s.id
    private_ip_address_allocation = "Dynamic"
  }
}

