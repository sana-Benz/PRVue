# describing the wanted cluster
resource "kind_cluster" "this" {
  name           = "previews"   # cluster name
  wait_for_ready = true         # wait till the cluster is ready

  kind_config {
    kind        = "Cluster"
    api_version = "kind.x-k8s.io/v1alpha4"

    node {
      role = "control-plane"    

      extra_port_mappings {
        container_port = 30080  
        host_port      = 80    
        listen_address = "127.0.0.1"   # only reachable from this laptop 
      }
    }
  }
}
