from typing import Any, Dict, List, Optional, Tuple

import boto3


def _chunk(items: List[str], size: int) -> List[List[str]]:
    return [items[i : i + size] for i in range(0, len(items), size)]


def _parse_service_arn(service_arn: str) -> Tuple[Optional[str], str]:
    """Returns (cluster_name, service_name).

    Handles the common ARN shape:
      arn:aws:ecs:region:acct:service/clusterName/serviceName

    Falls back to (None, serviceName) if clusterName isn't present.
    """
    try:
        suffix = service_arn.split(":service/")[-1]
        parts = suffix.split("/")
        if len(parts) >= 2:
            return parts[0], parts[-1]
        return None, parts[-1]
    except Exception:
        return None, service_arn


def handler(event: Dict[str, Any], _context: Any) -> Dict[str, Any]:
    action = (event.get("action") or "").strip().lower()
    if action not in {"on", "off"}:
        raise ValueError("Input must include action: 'on' or 'off'")

    cluster_arn = event.get("cluster_arn")
    if not cluster_arn:
        raise ValueError("Input must include cluster_arn")

    user_input = event.get("input") or {}
    desired_count_on = int(user_input.get("desired_count", 1))
    autoscaling_min_on = int(user_input.get("autoscaling_min", 1))
    autoscaling_max_on = int(user_input.get("autoscaling_max", 2))

    if desired_count_on < 0:
        raise ValueError("desired_count must be >= 0")
    if autoscaling_min_on < 0 or autoscaling_max_on < 0:
        raise ValueError("autoscaling_min/autoscaling_max must be >= 0")
    if autoscaling_max_on < autoscaling_min_on:
        raise ValueError("autoscaling_max must be >= autoscaling_min")

    ecs = boto3.client("ecs")
    aas = boto3.client("application-autoscaling")

    cluster_desc = ecs.describe_clusters(clusters=[cluster_arn]).get("clusters", [])
    if not cluster_desc:
        raise ValueError(f"Cluster not found: {cluster_arn}")
    cluster_name = cluster_desc[0]["clusterName"]

    # List all services in cluster
    service_arns: List[str] = []
    paginator = ecs.get_paginator("list_services")
    for page in paginator.paginate(cluster=cluster_arn):
        service_arns.extend(page.get("serviceArns", []))

    updated: List[str] = []
    skipped: List[str] = []
    errors: List[Dict[str, str]] = []

    # Describe in batches (API limit)
    for batch in _chunk(service_arns, 10):
        services = ecs.describe_services(cluster=cluster_arn, services=batch).get("services", [])

        for svc in services:
            service_arn = svc["serviceArn"]
            desired_count = svc.get("desiredCount")
            scheduling_strategy = svc.get("schedulingStrategy")

            if scheduling_strategy == "DAEMON":
                skipped.append(service_arn)
                continue

            arn_cluster_name, service_name = _parse_service_arn(service_arn)
            effective_cluster_name = arn_cluster_name or cluster_name
            resource_id = f"service/{effective_cluster_name}/{service_name}"

            try:
                if action == "off":
                    scalable_targets = aas.describe_scalable_targets(
                        ServiceNamespace="ecs",
                        ScalableDimension="ecs:service:DesiredCount",
                        ResourceIds=[resource_id],
                    ).get("ScalableTargets", [])

                    has_autoscaling = len(scalable_targets) > 0

                    # Clamp autoscaling to keep service off.
                    if has_autoscaling:
                        aas.register_scalable_target(
                            ServiceNamespace="ecs",
                            ScalableDimension="ecs:service:DesiredCount",
                            ResourceId=resource_id,
                            MinCapacity=0,
                            MaxCapacity=0,
                        )

                    ecs.update_service(cluster=cluster_arn, service=service_arn, desiredCount=0)
                    updated.append(service_arn)

                else:  # on
                    scalable_targets = aas.describe_scalable_targets(
                        ServiceNamespace="ecs",
                        ScalableDimension="ecs:service:DesiredCount",
                        ResourceIds=[resource_id],
                    ).get("ScalableTargets", [])

                    has_autoscaling = len(scalable_targets) > 0

                    # Restore autoscaling bounds (if autoscaling exists), then desired count.
                    if has_autoscaling:
                        aas.register_scalable_target(
                            ServiceNamespace="ecs",
                            ScalableDimension="ecs:service:DesiredCount",
                            ResourceId=resource_id,
                            MinCapacity=autoscaling_min_on,
                            MaxCapacity=autoscaling_max_on,
                        )

                    ecs.update_service(
                        cluster=cluster_arn,
                        service=service_arn,
                        desiredCount=desired_count_on,
                    )

                    updated.append(service_arn)

            except Exception as exc:
                errors.append({"serviceArn": service_arn, "error": str(exc)})

    return {
        "action": action,
        "clusterArn": cluster_arn,
        "desiredCountOn": desired_count_on,
        "autoscalingMinOn": autoscaling_min_on,
        "autoscalingMaxOn": autoscaling_max_on,
        "serviceCount": len(service_arns),
        "updatedCount": len(updated),
        "skippedCount": len(skipped),
        "errorCount": len(errors),
        "errors": errors[:25],
    }
