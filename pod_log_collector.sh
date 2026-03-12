#!/bin/bash

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
file=${1:-"$script_dir/datadog_logs.txt"}

parse_line() {
	local line="$1"
	local cluster namespace steps
	cluster=$(echo "$line" | sed -n 's/.*Cluster:[[:space:]]*\([^|]*\)[[:space:]]*|.*/\1/p' | sed 's/[[:space:]]*$//')
	namespace=$(echo "$line" | sed -n 's/.*Namespace:[[:space:]]*\([^|]*\)[[:space:]]*|.*/\1/p' | sed 's/[[:space:]]*$//')
	steps=$(echo "$line" | sed -n 's/.*Steps:[[:space:]]*\([0-9][0-9]*\).*/\1/p')

	if [ -z "$cluster" ] || [ -z "$namespace" ] || [ -z "$steps" ]; then
		printf 'BAD_FORMAT:%s\n' "$line" >&2
		return 1
	fi

    echo "Cluster: $cluster, Namespace: $namespace, Steps: $steps"
}

# show_resources <kube> <namespace> <restype> <sizefile>
# Prints kubectl table for restype, with byte size printed after each resource row
# Appends each resource's byte size to sizefile for total calculation
show_resources() {
	local kube="$1" namespace="$2" restype="$3" sizefile="$4"
	local names
	names=$(KUBECONFIG="$kube" kubectl get "$restype" -n "$namespace" \
		--no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null) || return 0
	[ -z "$names" ] && return 0
	KUBECONFIG="$kube" kubectl get "$restype" -n "$namespace" 2>/dev/null | head -1
	printf '%s\n' "$names" | while IFS= read -r resname; do
		[ -z "$resname" ] && continue
		row=$(KUBECONFIG="$kube" kubectl get "$restype/$resname" -n "$namespace" --no-headers 2>/dev/null)
		[ -z "$row" ] && continue
		printf '%s\n' "$row" | awk -v rn="$restype/$resname" '{$1=rn; print}'
		size=$(KUBECONFIG="$kube" kubectl get "$restype/$resname" -n "$namespace" -o json 2>/dev/null | wc -c | tr -d ' ')
		printf 'Size: %s bytes\n\n' "$size"
		printf '%s\n' "$size" >> "$sizefile"
	done
	printf '\n'
}

if [ ! -f "$file" ]; then
	echo "file not found: $file" >&2
	exit 2
fi

line_no=0
seen=""
while IFS= read -r line || [ -n "$line" ]; do
	line_no=$((line_no+1))
	# skip empty lines
	if [ -z "${line//[[:space:]]/}" ]; then
		continue
	fi

	if ! parsed=$(parse_line "$line"); then
		echo "(line $line_no invalid)" >&2
		continue
	fi

	# print parsed output
	printf '%s\n' "$parsed"

	# collect unique clusters
	cluster=$(echo "$line" | sed -n 's/.*Cluster:[[:space:]]*\([^|]*\)[[:space:]]*|.*/\1/p' | sed 's/[[:space:]]*$//')
	if [ -n "$cluster" ]; then
		if ! printf '%s\n' "$seen" | grep -Fxq -- "$cluster"; then
			seen="$seen"$'\n'$cluster
		fi
	fi
done < "$file"

echo "LogIn to AWS SSO with profile saas-pp-dev to access EKS clusters..."
aws sso login --profile saas-pp-dev

SEP="============================================================"
SUBSEP="------------------------------------------------------------"
FINAL_HDR="------------------------------ Final Summary --------------------------------"
FINAL_FTR="------------------------------------------------------------------------------"

summary=""
summaryfile=$(mktemp)

printf '\nChecking namespaces in EKS clusters (per-line):\n'
while IFS= read -r l || [ -n "$l" ]; do
	[ -z "${l//[[:space:]]/}" ] && continue
	# Use cluster name from log directly as the EKS cluster name
	cluster=$(echo "$l" | sed -n 's/.*Cluster:[[:space:]]*\([^|]*\)[[:space:]]*|.*/\1/p' | sed 's/[[:space:]]*$//')
	namespace=$(echo "$l" | sed -n 's/.*Namespace:[[:space:]]*\([^|]*\)[[:space:]]*|.*/\1/p' | sed 's/[[:space:]]*$//')
	steps=$(echo "$l" | sed -n 's/.*Steps:[[:space:]]*\([0-9][0-9]*\).*/\1/p')
	region=$(echo "$cluster" | grep -oE 'us-[a-z]+-[0-9]' || true)
	if echo "$cluster" | grep -q "qa"; then
		profile=saas-qa-dev
	else
		profile=saas-pp-dev
	fi
	if [ "$region" = "us-east-1" ]; then
		kube="$HOME/.kube/pp-platform-east"
	else
		kube="$HOME/.kube/pp-platform-west"
	fi
	# cluster name from DataDog IS the EKS cluster name — use it directly
	name="$cluster"

	printf '\n%s\n' "$SEP"
	printf '  Cluster   : %s\n' "$cluster"
	printf '  Namespace : %s\n' "$namespace"
	printf '%s\n' "$SEP"

	# prepare and run update-kubeconfig so kubectl can query the cluster
	aws eks update-kubeconfig --name="$name" --region="$region" --kubeconfig="$kube" --profile="$profile" >/dev/null 2>&1 || true

	# check namespace presence (pass KUBECONFIG inline to avoid subshell export issues)
	if KUBECONFIG="$kube" kubectl get ns -A | grep -w -q -- "$namespace"; then
		printf '  Status    : ALIVE\n'
		printf '%s\n' "$SEP"
		sizefile=$(mktemp)
		printf '\n%s\n' "$SUBSEP"
		printf '  Core Resources\n'
		printf '%s\n' "$SUBSEP"
		show_resources "$kube" "$namespace" pods "$sizefile"
		# Dump run pod YAML to a file for structural analysis
		run_pod_name=$(KUBECONFIG="$kube" kubectl get pods -n "$namespace" \
			--no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null \
			| grep '^run-' | head -1)
		if [ -n "$run_pod_name" ]; then
			pod_yaml_file="$script_dir/pod_yaml_${steps}_steps.yaml"
			KUBECONFIG="$kube" kubectl get pod "$run_pod_name" -n "$namespace" -o yaml > "$pod_yaml_file" 2>/dev/null
			printf '  [Run Pod YAML saved => %s]\n\n' "$pod_yaml_file"
		fi
		show_resources "$kube" "$namespace" serviceaccounts "$sizefile"
		show_resources "$kube" "$namespace" configmaps "$sizefile"
		show_resources "$kube" "$namespace" secrets "$sizefile"
		show_resources "$kube" "$namespace" networkpolicies "$sizefile"
		printf '%s\n' "$SUBSEP"
		printf '  Tekton Resources\n'
		printf '%s\n' "$SUBSEP"
		show_resources "$kube" "$namespace" tasks "$sizefile"
		show_resources "$kube" "$namespace" taskruns "$sizefile"
		show_resources "$kube" "$namespace" pipelineruns "$sizefile"
		total_bytes=$(awk '{s+=$1} END{print s+0}' "$sizefile")
		total_mb=$(awk "BEGIN{printf \"%.4f\", $total_bytes/1048576}")
		printf '\n%s\n' "$SEP"
		printf '  namespace_k8s_resources_total_size : %s bytes  ( %s MB )  [Steps: %s]\n' "$total_bytes" "$total_mb" "$steps"
		printf '%s\n' "$SEP"
		summary="${summary}  namespace_k8s_resources_total_size : ${total_bytes} bytes  ( ${total_mb} MB )  [Steps: ${steps}]\n"
		printf '  namespace_k8s_resources_total_size : %s bytes  ( %s MB )  [Steps: %s]\n' "$total_bytes" "$total_mb" "$steps" >> "$summaryfile"
		rm -f "$sizefile"
	else
		printf '  Status    : NOT FOUND (already cleaned up)\n'
		printf '%s\n' "$SEP"
	fi
done < "$file"

#if [ -s "$summaryfile" ]; then
	#printf '\n%s\n' "$FINAL_HDR"
	#cat "$summaryfile"
	#printf '%s\n' "$FINAL_FTR"
#fi
#rm -f "$summaryfile"
