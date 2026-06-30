output "argocd_admin_password_cmd" {
  description = "Command to fetch the initial Argo CD admin password."
  value       = "kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
}

output "argocd_port_forward_cmd" {
  description = "Port-forward the Argo CD UI to https://localhost:8080 (user: admin)."
  value       = "kubectl port-forward svc/argocd-server -n argocd 8080:443"
}

output "dagster_port_forward_cmd" {
  description = "Port-forward the Dagster UI to http://localhost:3000 once Argo has synced."
  value       = "kubectl port-forward svc/dagster-instance-dagster-webserver -n dagster 3000:80"
}
