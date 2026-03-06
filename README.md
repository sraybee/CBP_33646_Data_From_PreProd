## Collect Tekton Cluster Data Utility Tool

#### The pod_log_collector.sh based on datadog log I manually provide in datadog_logs.txt will dynamically log into correct tekton cluster, gather all K8S info, calculate byte size etc. and store in relevant txt file based on total steps for that particular DataDog log like 170_Steps_ETCD_Error.txt.

##### Sample Execution => sh pod_log_collector.sh > 140_Steps.txt
