# 🚀 Tekton Cluster Data Collection Utility

## 📌 Overview
The **`pod_log_collector.sh`** utility is designed to automatically collect Kubernetes and Tekton cluster diagnostics based on logs exported from **DataDog**.

Using the log entries provided in **`datadog_logs.txt`**, the script will:

- 🔐 Dynamically **log in to the correct Tekton cluster**
- 📦 **Gather relevant Kubernetes information**
- 📊 **Calculate resource byte sizes**
- 📝 **Store the collected data in structured output files**

---

## ⚙️ How It Works
1. The script reads **DataDog logs** from `datadog_logs.txt`.
2. It determines the **appropriate Tekton cluster** to access.
3. It collects **Kubernetes diagnostic data** related to the issue.
4. The script analyzes the logs and determines the **total step count**.
5. Output is written to a **step-specific report file**.

---

## 📄 Output Format
Generated report files follow this naming pattern:

```
<STEP_COUNT>_Steps_ETCD_Error.txt or <STEP_COUNT>_Steps_No_ETCD_Error.txt 
```

### Example
```
170_Steps_ETCD_Error.txt
```

This helps quickly identify:
- The **number of pipeline steps**
- The **type of issue (e.g., ETCD errors)**

---

## ▶️ Sample Execution

```bash
sh pod_log_collector.sh > 140_Steps.txt
```

This command:
- Executes the **pod log collection script**
- Redirects the output to a **step-specific report file**

---

## 🧰 Requirements
- Access to the **Tekton clusters**
- Exported **DataDog logs**
- `datadog_logs.txt` placed in the same directory as the script
- Kubernetes CLI tools configured (`kubectl`, cluster authentication, etc.)
