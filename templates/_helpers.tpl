{{/* Chart name, overridable. */}}
{{- define "superagent.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* Fully qualified app name. */}}
{{- define "superagent.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "superagent.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* Common labels stamped on host-app resources. */}}
{{- define "superagent.labels" -}}
helm.sh/chart: {{ include "superagent.chart" . }}
app.kubernetes.io/name: {{ include "superagent.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: host-app
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
{{- end -}}

{{/* Selector labels (stable across upgrades). */}}
{{- define "superagent.selectorLabels" -}}
app.kubernetes.io/name: {{ include "superagent.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: host-app
{{- end -}}

{{- define "superagent.serviceAccountName" -}}
{{- default (include "superagent.fullname" .) .Values.serviceAccount.name -}}
{{- end -}}

{{/* Workspaces PVC name: existing claim if given, else the chart-created PVC. */}}
{{- define "superagent.pvcName" -}}
{{- if .Values.storage.existingClaim -}}
{{- .Values.storage.existingClaim -}}
{{- else -}}
{{- printf "%s-data" (include "superagent.fullname" .) -}}
{{- end -}}
{{- end -}}

{{/* Name of the Secret consumed via envFrom. */}}
{{- define "superagent.secretName" -}}
{{- if .Values.secrets.existingSecret -}}
{{- .Values.secrets.existingSecret -}}
{{- else -}}
{{- printf "%s-env" (include "superagent.fullname" .) -}}
{{- end -}}
{{- end -}}

{{/* Host for the Ingress: explicit value, else the host parsed from hostPublicUrl. */}}
{{- define "superagent.ingressHost" -}}
{{- if .Values.ingress.host -}}
{{- .Values.ingress.host -}}
{{- else -}}
{{- .Values.hostPublicUrl | trimPrefix "https://" | trimPrefix "http://" | trimSuffix "/" -}}
{{- end -}}
{{- end -}}

{{/* Fail fast on required values. */}}
{{- define "superagent.validate" -}}
{{- if not .Values.hostPublicUrl -}}
{{- fail "hostPublicUrl is required (e.g. https://superagent.example.com)" -}}
{{- end -}}
{{- if gt (int .Values.hostApp.replicas) 1 -}}
{{- fail "hostApp.replicas must be 1: host-app is a single-writer (SQLite on a shared PVC)." -}}
{{- end -}}
{{- if and .Values.storage.subPathParent (not .Values.storage.subPath) -}}
{{- fail "storage.subPathParent requires storage.subPath" -}}
{{- end -}}
{{- if and .Values.storage.subPathParent .Values.storage.subPath (not (hasPrefix .Values.storage.subPathParent .Values.storage.subPath)) -}}
{{- fail "storage.subPathParent must be a prefix of storage.subPath" -}}
{{- end -}}
{{- end -}}
