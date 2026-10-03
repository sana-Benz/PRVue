# which providers are needed
terraform {
  required_providers {
    kind = {
      source  = "tehcyx/kind" 
      version = "~> 0.11"       
    }
  }
}
