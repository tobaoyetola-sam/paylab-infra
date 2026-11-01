output "web_url" {
  description = "The payment web page."
  value       = local.web_origin
}

output "api_health_url" {
  description = "API check through the ALB (domain mode: /health on the API host; no domain: /api/wallets returns the wallet list)."
  value       = local.use_domain ? "https://${var.api_host}/health" : "${local.web_origin}/api/wallets"
}

output "alb_dns_name" {
  description = "Raw ALB name. In domain mode use the https URLs above; the certificate doesn't cover this name."
  value       = aws_lb.paylab.dns_name
}

output "pipelines" {
  description = "One pipeline per service."
  value       = [for p in aws_codepipeline.svc : p.name]
}

output "watch_pipelines_command" {
  description = "Shows the latest status of every stage of every pipeline."
  value       = "for p in ${join(" ", [for p in aws_codepipeline.svc : p.name])}; do echo \"== $p\"; aws codepipeline get-pipeline-state --name $p --query 'stageStates[].[stageName,latestExecution.status]' --output text; done"
}

output "watch_services_command" {
  description = "Running vs desired tasks per ECS service."
  value       = "aws ecs describe-services --cluster ${aws_ecs_cluster.paylab.name} --services ${join(" ", keys(local.services))} --query 'services[].[serviceName,runningCount,desiredCount]' --output table"
}

output "psql_run_task_command" {
  description = "Runs the one-off psql task (wallets + latest payments); read the result with the logs command."
  value       = "aws ecs run-task --cluster ${aws_ecs_cluster.paylab.name} --launch-type FARGATE --task-definition ${aws_ecs_task_definition.psql.family} --network-configuration 'awsvpcConfiguration={subnets=[${join(",", data.aws_subnets.default.ids)}],securityGroups=[${aws_security_group.app.id}],assignPublicIp=ENABLED}' && sleep 60 && aws logs tail ${aws_cloudwatch_log_group.ecs.name} --since 5m --log-stream-name-prefix psql"
}

output "db_endpoint" {
  value = aws_db_instance.paylab.address
}
