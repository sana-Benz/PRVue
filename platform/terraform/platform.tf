# Traefik: the ingress controller (reads Ingress rules and routes traffic)
resource "helm_release" "traefik" {
  name             = "traefik"
  repository       = "https://traefik.github.io/charts"
  chart            = "traefik"
  version          = "41.6.1"
  namespace        = "traefik"
  create_namespace = true
  values           = [file("${path.module}/values/traefik.yaml")]
}

# ArgoCD: watches GitHub and deploys the previews
resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = "10.9.6"
  namespace        = "argocd"
  create_namespace = true
  timeout          = 600   # first install can be slow (image downloads)
  values           = [file("${path.module}/values/argocd.yaml")]
}
